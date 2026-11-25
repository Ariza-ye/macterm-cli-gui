import type {
    BeforeAgentStartEvent,
    BeforeAgentStartEventResult,
    ExtensionAPI,
    ExtensionContext,
    ToolCallEvent,
    ToolCallEventResult,
} from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmdirSync, statSync, unlinkSync } from "node:fs";
import { createConnection, createServer, type Socket } from "node:net";
import { dirname } from "node:path";
import { stripVTControlCharacters } from "node:util";

type Entry = ReturnType<ExtensionContext["sessionManager"]["getBranch"]>[number];
type Message = Extract<Entry, { type: "message" }>["message"];
type PiModel = NonNullable<ExtensionContext["model"]>;
type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;
type Attachment = {
    id: string;
    kind: "image" | "text";
    name: string;
    mimeType: string;
    data?: string;
    text?: string;
    byteCount?: number;
    path?: string;
};
type Row = {
    id: string;
    kind: "user" | "assistant" | "tool";
    text: string;
    name?: string;
    status?: "running" | "completed" | "failed";
    attachments?: Attachment[];
};
type PiMode = "edit" | "plan";
type ConfigChoice = {
    value: string;
    name: string;
    description?: string;
    group?: string;
};
type ConfigOption = {
    id: string;
    name: string;
    category: "model" | "thought_level" | "mode";
    currentValue: string;
    options: ConfigChoice[];
};

const READ_ONLY_BUILTIN_TOOLS = new Set(["read", "grep", "find", "ls"]);
const PLAN_MODE_SYSTEM_PROMPT = [
    "",
    "## Plan Mode (Read-Only)",
    "You are currently in Plan mode. Inspect the codebase with read-only tools, clarify requirements, and present a clear step-by-step plan.",
    "Do not edit files, create files, or run shell commands until the user switches back to Edit mode.",
].join("\n");

const THINKING_LEVELS: readonly ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const THINKING_LABELS: Record<string, string> = {
    off: "Off",
    minimal: "Minimal",
    low: "Low",
    medium: "Medium",
    high: "High",
    xhigh: "Extra",
    max: "Max",
};

function modelKey(model: PiModel): string {
    return JSON.stringify([model.provider, model.id]);
}

function supportedThinkingLevels(model: ExtensionContext["model"]): ThinkingLevel[] {
    if (!model?.reasoning) return [];
    return THINKING_LEVELS.filter((level) => {
        const mapped = model.thinkingLevelMap?.[level];
        if (mapped === null) return false;
        if (level === "xhigh" || level === "max") return mapped !== undefined;
        return true;
    });
}

const MAX_ATTACHMENTS = 10;
const MAX_TEXT_ATTACHMENT_BYTES = 128 * 1024;
const MAX_IMAGE_ATTACHMENT_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_ATTACHMENT_BYTES = 12 * 1024 * 1024;
const MAX_FRAME_BYTES = 24 * 1024 * 1024;

const TEXT_ATTACHMENT_BLOCK_RE = /(?:^|\n)--- Attached file: ([^\r\n]+) ---\n([\s\S]*?)\n--- End of ([^\r\n]+) ---(?=\n|$)/g;

function decodedBase64Bytes(base64: string): number {
    const compact = base64.replace(/\s+/g, "");
    if (!compact) return 0;
    const padding = compact.endsWith("==") ? 2 : compact.endsWith("=") ? 1 : 0;
    return Math.max(0, Math.floor((compact.length * 3) / 4) - padding);
}

function formatTextAttachment(attachment: Attachment): string {
    const name = stripVTControlCharacters(attachment.name || "attachment.txt").replace(/[\r\n]/g, " ");
    return `--- Attached file: ${name} ---\n${attachment.text ?? ""}\n--- End of ${name} ---`;
}

function splitTextAttachments(raw: string, idPrefix: string, remainingCapacity: number): { text: string; attachments: Attachment[] } {
    if (remainingCapacity <= 0 || !raw.includes("--- Attached file: ")) {
        return { text: raw, attachments: [] };
    }
    const attachments: Attachment[] = [];
    let cursor = 0;
    let remaining = "";
    TEXT_ATTACHMENT_BLOCK_RE.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = TEXT_ATTACHMENT_BLOCK_RE.exec(raw)) !== null && attachments.length < remainingCapacity) {
        if (match[1] !== match[3]) continue;
        remaining += raw.slice(cursor, match.index);
        cursor = match.index + match[0].length;
        const name = stripVTControlCharacters(match[1]).trim().slice(0, 128) || "attachment.txt";
        const text = stripVTControlCharacters(match[2]);
        attachments.push({
            id: `${idPrefix}:${attachments.length}`,
            kind: "text",
            name,
            mimeType: "text/plain",
            text,
            byteCount: Buffer.byteLength(text, "utf8"),
        });
    }
    if (attachments.length === 0) return { text: raw, attachments: [] };
    remaining += raw.slice(cursor);
    return { text: remaining.trim(), attachments };
}

function normalizeAttachments(raw: unknown): { valid: boolean; attachments: Attachment[] } {
    if (raw === undefined || raw === null) return { valid: true, attachments: [] };
    if (!Array.isArray(raw) || raw.length > MAX_ATTACHMENTS) return { valid: false, attachments: [] };
    const attachments: Attachment[] = [];
    let totalBytes = 0;
    for (const item of raw) {
        if (!item || typeof item !== "object") return { valid: false, attachments: [] };
        const candidate = item as Record<string, unknown>;
        const kind = candidate.kind;
        const id = typeof candidate.id === "string" && candidate.id.trim() ? candidate.id.slice(0, 128) : randomUUID();
        const rawName = typeof candidate.name === "string" ? stripVTControlCharacters(candidate.name).trim() : "";
        const name = (rawName || (kind === "image" ? "image.png" : "attachment.txt")).slice(0, 128);
        const path = typeof candidate.path === "string" && candidate.path.trim() ? candidate.path.slice(0, 1024) : undefined;
        if (kind === "image") {
            const mimeType = typeof candidate.mimeType === "string" ? candidate.mimeType.trim().toLowerCase() : "";
            const data = typeof candidate.data === "string" ? candidate.data.trim() : "";
            if (!mimeType.startsWith("image/") || !data) return { valid: false, attachments: [] };
            const byteCount = decodedBase64Bytes(data);
            if (byteCount <= 0 || byteCount > MAX_IMAGE_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            totalBytes += byteCount;
            if (totalBytes > MAX_TOTAL_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            attachments.push({ id, kind: "image", name, mimeType, data, byteCount, ...(path ? { path } : {}) });
        } else if (kind === "text") {
            if (typeof candidate.text !== "string") return { valid: false, attachments: [] };
            const text = candidate.text;
            const byteCount = Buffer.byteLength(text, "utf8");
            if (byteCount > MAX_TEXT_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            totalBytes += byteCount;
            if (totalBytes > MAX_TOTAL_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            const mimeType = typeof candidate.mimeType === "string" && candidate.mimeType.trim()
                ? candidate.mimeType.trim().slice(0, 128)
                : "text/plain";
            attachments.push({ id, kind: "text", name, mimeType, text, byteCount, ...(path ? { path } : {}) });
        } else {
            return { valid: false, attachments: [] };
        }
    }
    return { valid: true, attachments };
}

function textContent(content: unknown): string {
    const text = typeof content === "string" ? content : Array.isArray(content)
        ? content.filter((block) => block?.type === "text" && typeof block.text === "string")
              .map((block) => block.text).join("\n")
        : "";
    const limit = 48 * 1024;
    return stripVTControlCharacters(text.length <= limit ? text : `${text.slice(0, limit)}\n…`);
}

function extractMessageParts(id: string, content: unknown): { text: string; attachments: Attachment[] } {
    if (typeof content === "string") {
        const split = splitTextAttachments(content, `${id}:txt:0`, MAX_ATTACHMENTS);
        return { text: textContent(split.text), attachments: split.attachments };
    }
    if (!Array.isArray(content)) return { text: "", attachments: [] };
    const textParts: string[] = [];
    const attachments: Attachment[] = [];
    for (let index = 0; index < content.length; index++) {
        const block = content[index];
        if (!block || typeof block !== "object") continue;
        if (block.type === "text" && typeof block.text === "string") {
            const split = splitTextAttachments(block.text, `${id}:txt:${index}`, MAX_ATTACHMENTS - attachments.length);
            attachments.push(...split.attachments);
            if (split.text) textParts.push(split.text);
        } else if (
            block.type === "image"
            && typeof block.data === "string"
            && typeof block.mimeType === "string"
            && attachments.length < MAX_ATTACHMENTS
        ) {
            const byteCount = decodedBase64Bytes(block.data);
            if (byteCount > 0 && byteCount <= MAX_IMAGE_ATTACHMENT_BYTES) {
                const ext = block.mimeType.split("/")[1]?.split(";")[0] || "png";
                attachments.push({
                    id: `${id}:img:${index}`,
                    kind: "image",
                    name: `image-${attachments.length + 1}.${ext}`,
                    mimeType: block.mimeType,
                    data: block.data,
                    byteCount,
                });
            }
        }
    }
    const joined = textParts.join("\n");
    const limit = 48 * 1024;
    const text = stripVTControlCharacters(joined.length <= limit ? joined : `${joined.slice(0, limit)}\n…`);
    return { text, attachments };
}

function messageRow(id: string, message: Message): Row | undefined {
    switch (message.role) {
        case "user": {
            const { text, attachments } = extractMessageParts(id, message.content);
            return { id, kind: "user", text, ...(attachments.length ? { attachments } : {}) };
        }
        case "assistant": {
            const { text: bodyText, attachments } = extractMessageParts(id, message.content);
            const text = bodyText || textContent(message.errorMessage);
            return text || attachments.length
                ? { id, kind: "assistant", text, ...(attachments.length ? { attachments } : {}) }
                : undefined;
        }
        case "toolResult":
            return {
                id, kind: "tool", name: message.toolName,
                text: textContent(message.content), status: message.isError ? "failed" : "completed",
            };
    }
}

function resolveRegistrationSocket(agentSocket: string | undefined, controlSocket: string | undefined): string | undefined {
    if (agentSocket) return agentSocket;
    if (!controlSocket) return undefined;
    const sibling = `${dirname(controlSocket)}/agent.sock`;
    try {
        if (statSync(sibling).isSocket()) return sibling;
    } catch {}
    return controlSocket;
}

export default function (pi: ExtensionAPI) {
    let runtime: ReturnType<typeof startBridge>;
    pi.registerCommand("macterm-new", {
        description: "Start a new conversation from Macterm",
        handler: async (_args, cmdCtx) => {
            const result = await cmdCtx.newSession();
            if (result.cancelled) {
                runtime?.rejectNewConversation();
            }
        },
    });
    pi.on("session_start", (_event, ctx) => {
        runtime?.close();
        const session = process.env.MACTERM_SESSION;
        const agentSocket = process.env.MACTERM_AGENT_SOCKET;
        const controlSocket = process.env.MACTERM_SOCKET;
        runtime = ctx.mode === "tui" && process.platform === "darwin" && session && (agentSocket || controlSocket)
            ? startBridge(pi, ctx, session, agentSocket, controlSocket) : undefined;
    });
    pi.on("session_shutdown", () => { runtime?.close(); runtime = undefined; });
    pi.on("session_tree", () => { runtime?.snapshot(); });
    pi.on("before_agent_start", (event) => {
        runtime?.status();
        return runtime?.beforeAgentStart(event);
    });
    pi.on("tool_call", (event) => runtime?.onToolCall(event));
    pi.on("agent_start", () => { runtime?.acceptSend(); runtime?.status(); });
    pi.on("agent_settled", () => { runtime?.status(); });
    pi.on("ui_prompt_start", () => { runtime?.setWaiting(true); });
    pi.on("ui_prompt_end", () => { runtime?.setWaiting(false); });
    pi.on("model_select", () => { runtime?.config(); });
    pi.on("thinking_level_select", () => { runtime?.config(); });
    pi.on("message_start", (event) => { runtime?.message(event.message, "start"); });
    pi.on("message_update", (event) => { runtime?.message(event.message, "update"); });
    pi.on("message_end", (event) => { runtime?.message(event.message, "end"); });
    pi.on("tool_execution_start", (event) => {
        runtime?.tool(event.toolCallId, event.toolName, "running", undefined, event.args);
    });
    pi.on("tool_execution_update", (event) => {
        runtime?.tool(event.toolCallId, event.toolName, "running", event.partialResult);
    });
    pi.on("tool_execution_end", (event) => {
        runtime?.tool(event.toolCallId, event.toolName, event.isError ? "failed" : "completed", event.result);
    });
}

function startBridge(
    pi: ExtensionAPI,
    ctx: ExtensionContext,
    session: string,
    agentSocket: string | undefined,
    controlSocket: string | undefined,
) {
    let directory: string;
    try { directory = mkdtempSync("/tmp/macterm-pi-"); } catch { return; }
    const path = `${directory}/bridge.sock`;
    const conversation = ctx.sessionManager.getSessionId();
    let peer: Socket | undefined;
    let registration: Socket | undefined;
    let token = "";
    let registeredSocket: string | undefined;
    let registeringSocket: string | undefined;
    let pending: { id: string; timer: NodeJS.Timeout; owner: Socket } | undefined;
    let pendingNewConversation: { id: string; timer: NodeJS.Timeout; owner: Socket } | undefined;
    let configPending = false;
    let waiting = false;
    let closed = false;
    let messageID = 0;
    let currentMode: PiMode = "edit";
    let savedActiveTools: string[] | undefined;
    const connected = new Set<Socket>();
    const activeMessages = new Map<string, string>();
    const toolArguments = new Map<string, string>();
    const modelsByKey = new Map<string, PiModel>();
    const activeCompletions = new Map<string, { controller: AbortController; owner: Socket }>();

    const state = () => ({ busy: !ctx.isIdle(), waiting });

    function isReadOnlyTool(toolName: string): boolean {
        if (READ_ONLY_BUILTIN_TOOLS.has(toolName)) return true;
        if (typeof pi.getAllTools === "function") {
            const info = pi.getAllTools().find((tool) => tool.name === toolName);
            if (info?.annotations?.readOnlyHint === true) return true;
        }
        return false;
    }

    function applyMode(nextMode: PiMode) {
        if (nextMode === currentMode) return;
        if (nextMode === "plan") {
            if (typeof pi.getActiveTools === "function" && typeof pi.setActiveTools === "function") {
                if (savedActiveTools === undefined) {
                    savedActiveTools = pi.getActiveTools();
                }
                pi.setActiveTools(savedActiveTools.filter(isReadOnlyTool));
            }
            currentMode = "plan";
            ctx.ui?.setStatus?.("macterm-mode", "Plan");
        } else {
            if (savedActiveTools !== undefined && typeof pi.setActiveTools === "function") {
                pi.setActiveTools(savedActiveTools);
                savedActiveTools = undefined;
            }
            currentMode = "edit";
            ctx.ui?.setStatus?.("macterm-mode", undefined);
        }
    }

    function buildConfigOptions(): ConfigOption[] {
        const result: ConfigOption[] = [
            {
                id: "mode",
                name: "Mode",
                category: "mode",
                currentValue: currentMode,
                options: [
                    {
                        value: "edit",
                        name: "Edit",
                        description: "Full tool access for editing files and running commands.",
                    },
                    {
                        value: "plan",
                        name: "Plan",
                        description: "Read-only exploration and planning before making changes.",
                    },
                ],
            },
        ];
        modelsByKey.clear();
        const sourceModels = ctx.scopedModels.length > 0
            ? ctx.scopedModels.map((entry) => entry.model)
            : ctx.modelRegistry.getAvailable();
        const models: PiModel[] = [];
        const addModel = (model: PiModel | undefined) => {
            if (!model) return;
            const key = modelKey(model);
            if (modelsByKey.has(key)) return;
            modelsByKey.set(key, model);
            models.push(model);
        };
        for (const model of sourceModels) addModel(model);
        addModel(ctx.model);

        if (models.length > 0) {
            const currentValue = ctx.model ? modelKey(ctx.model) : modelKey(models[0]);
            const options: ConfigChoice[] = models.map((model) => {
                const providerName = ctx.modelRegistry.getProviderDisplayName?.(model.provider) || model.provider;
                return {
                    value: modelKey(model),
                    name: stripVTControlCharacters(model.name || model.id),
                    group: stripVTControlCharacters(providerName),
                };
            });
            result.push({
                id: "model",
                name: "Model",
                category: "model",
                currentValue,
                options,
            });
        }

        const levels = supportedThinkingLevels(ctx.model);
        if (levels.length > 1) {
            const currentLevel = pi.getThinkingLevel();
            const allLevels = levels.includes(currentLevel) ? levels : [currentLevel, ...levels];
            result.push({
                id: "thought_level",
                name: "Thinking Level",
                category: "thought_level",
                currentValue: currentLevel,
                options: allLevels.map((level) => ({
                    value: level,
                    name: THINKING_LABELS[level] ?? level,
                })),
            });
        }

        return result;
    }
    function emit(frame: object) {
        if (!peer) return;
        if (peer.writableLength > 32 * 1024 * 1024) { peer.destroy(); return; }
        peer.write(JSON.stringify(frame) + "\n");
    }
    const status = () => emit({ type: "status", ...state() });
    const config = () => emit({ type: "config", configOptions: buildConfigOptions() });
    function sendReply(accepted: boolean) {
        if (!pending) return;
        const { id, timer, owner } = pending;
        clearTimeout(timer);
        pending = undefined;
        if (owner === peer) emit({ type: "reply", id, accepted, ...state() });
    }
    function sendNewConversationReply(accepted: boolean) {
        if (!pendingNewConversation) return;
        const { id, timer, owner } = pendingNewConversation;
        clearTimeout(timer);
        pendingNewConversation = undefined;
        if (owner === peer) emit({ type: "newConversationReply", id, accepted, ...state() });
    }
    function snapshot() {
        if (!peer) return;
        emit({ type: "snapshot", conversation });
        for (const entry of ctx.sessionManager.getBranch()) {
            if (entry.type !== "message") continue;
            const row = messageRow(`entry:${entry.id}`, entry.message);
            if (row) emit({ type: "row", row });
        }
        emit({ type: "snapshotEnd", ...state(), configOptions: buildConfigOptions() });
    }

    function cancelCompletion(id: string) {
        const entry = activeCompletions.get(id);
        if (!entry) return;
        activeCompletions.delete(id);
        entry.controller.abort();
    }

    function cancelCompletionsForSocket(socket?: Socket) {
        for (const [id, entry] of activeCompletions) {
            if (!socket || entry.owner === socket) {
                activeCompletions.delete(id);
                entry.controller.abort();
            }
        }
    }

    async function runCompletion(
        command: { id?: string; instructions?: unknown; prompt?: unknown; maxTokens?: unknown },
        owner: Socket,
    ) {
        const id = command.id;
        if (typeof id !== "string" || !id) return;
        const reply = (accepted: boolean, extra: Record<string, unknown> = {}) => {
            if (owner === peer) emit({ type: "completeReply", id, accepted, ...extra });
        };
        const instructions = typeof command.instructions === "string" ? command.instructions.trim() : "";
        const promptText = typeof command.prompt === "string" ? command.prompt.trim() : "";
        const maxTokens = typeof command.maxTokens === "number" && Number.isFinite(command.maxTokens) && command.maxTokens > 0
            ? Math.min(Math.floor(command.maxTokens), 4096)
            : undefined;
        if (closed || !promptText || activeCompletions.size >= 2 || activeCompletions.has(id)
            || Buffer.byteLength(instructions) + Buffer.byteLength(promptText) > 128 * 1024) {
            reply(false, { error: "unavailable" });
            return;
        }
        const model = ctx.model ?? ctx.modelRegistry.getAvailable()[0];
        if (!model || typeof ctx.modelRegistry?.streamSimple !== "function") {
            reply(false, { error: "no_model" });
            return;
        }

        const controller = new AbortController();
        activeCompletions.set(id, { controller, owner });
        if (owner === peer) emit({ type: "completeUpdate", id, text: "" });

        let text = "";
        let failed = false;
        let errorMessage = "";
        try {
            const stream = ctx.modelRegistry.streamSimple(
                model,
                {
                    ...(instructions ? { systemPrompt: instructions } : {}),
                    messages: [{ role: "user", content: promptText, timestamp: Date.now() }],
                },
                {
                    ...(maxTokens !== undefined ? { maxTokens } : {}),
                    temperature: 0.3,
                    signal: controller.signal,
                },
            );
            for await (const event of stream) {
                if (controller.signal.aborted || closed) break;
                if (event.type === "text_delta" && typeof event.delta === "string") {
                    text = (text + stripVTControlCharacters(event.delta)).slice(0, 16 * 1024);
                    if (owner === peer) emit({ type: "completeUpdate", id, text });
                } else if (event.type === "done" && !text.trim()) {
                    const finalText = textContent(event.message.content);
                    if (finalText) {
                        text = finalText.slice(0, 16 * 1024);
                    }
                } else if (event.type === "error") {
                    failed = true;
                    errorMessage = event.error?.errorMessage || "model_error";
                }
            }
            if (controller.signal.aborted || closed) return;
            if (!failed && text.trim()) {
                reply(true, { text });
            } else {
                reply(false, { error: errorMessage || "empty" });
            }
        } catch (error) {
            if (!controller.signal.aborted && !closed) {
                const message = error instanceof Error ? error.message : "completion_failed";
                reply(false, { error: stripVTControlCharacters(message) });
            }
        } finally {
            activeCompletions.delete(id);
        }
    }

    const server = createServer((socket) => {
        if (closed || connected.size >= 4) { socket.destroy(); return; }
        connected.add(socket);
        socket.unref().setTimeout(5000).setEncoding("utf8");
        socket.on("timeout", () => socket.destroy());
        socket.on("error", () => socket.destroy());
        socket.on("close", () => {
            connected.delete(socket);
            cancelCompletionsForSocket(socket);
            if (peer === socket) peer = undefined;
            if (pending?.owner === socket) sendReply(false);
            if (pendingNewConversation?.owner === socket) sendNewConversationReply(false);
        });
        let buffer = "";
        socket.on("data", (chunk: string) => {
            buffer += chunk;
            if (buffer.length > MAX_FRAME_BYTES) { socket.destroy(); return; }
            let newline: number;
            while ((newline = buffer.indexOf("\n")) >= 0 && !socket.destroyed) {
                const line = buffer.slice(0, newline);
                buffer = buffer.slice(newline + 1);
                let command: {
                    type?: string;
                    id?: string;
                    token?: string;
                    text?: string;
                    attachments?: unknown;
                    configId?: string;
                    value?: string;
                    instructions?: unknown;
                    prompt?: unknown;
                    maxTokens?: unknown;
                };
                try { command = JSON.parse(line); } catch { socket.destroy(); return; }
                if (!command || typeof command !== "object") { socket.destroy(); return; }
                if (peer !== socket) {
                    if (command.type !== "hello" || !token || command.token?.toLowerCase() !== token) {
                        socket.destroy();
                        return;
                    }
                    token = "";
                    peer?.destroy();
                    peer = socket;
                    registeredSocket = registeringSocket;
                    socket.setTimeout(0);
                    snapshot();
                } else if (command.type === "stop") {
                    if (!ctx.isIdle()) ctx.abort();
                } else if (command.type === "exit") {
                    close();
                    if (!ctx.isIdle()) ctx.abort();
                    ctx.shutdown();
                } else if (command.type === "setConfig" && typeof command.id === "string") {
                    const replyConfig = (accepted: boolean) => {
                        if (peer === socket) {
                            emit({
                                type: "configReply",
                                id: command.id,
                                accepted,
                                configOptions: buildConfigOptions(),
                                ...state(),
                            });
                        }
                    };
                    if (pending || configPending || pendingNewConversation || waiting || !ctx.isIdle()
                        || typeof command.configId !== "string" || typeof command.value !== "string") {
                        replyConfig(false);
                        continue;
                    }
                    if (command.configId === "model") {
                        buildConfigOptions();
                        const target = modelsByKey.get(command.value);
                        if (!target) {
                            replyConfig(false);
                            continue;
                        }
                        configPending = true;
                        void pi.setModel(target).then(
                            (ok) => {
                                configPending = false;
                                replyConfig(Boolean(ok));
                            },
                            () => {
                                configPending = false;
                                replyConfig(false);
                            },
                        );
                    } else if (command.configId === "thought_level") {
                        const levels = supportedThinkingLevels(ctx.model);
                        if (!levels.includes(command.value as ThinkingLevel)) {
                            replyConfig(false);
                            continue;
                        }
                        pi.setThinkingLevel(command.value as ThinkingLevel);
                        replyConfig(true);
                    } else if (command.configId === "mode") {
                        if (command.value !== "edit" && command.value !== "plan") {
                            replyConfig(false);
                            continue;
                        }
                        applyMode(command.value);
                        replyConfig(true);
                    } else {
                        replyConfig(false);
                    }
                } else if (command.type === "newConversation" && typeof command.id === "string") {
                    if (pending || configPending || pendingNewConversation || waiting || !ctx.isIdle()) {
                        emit({ type: "newConversationReply", id: command.id, accepted: false, ...state() });
                        continue;
                    }
                    pendingNewConversation = {
                        id: command.id,
                        owner: socket,
                        timer: setTimeout(() => sendNewConversationReply(false), 15000).unref(),
                    };
                    try {
                        void Promise.resolve(
                            pi.sendUserMessage("/macterm-new", { expandPromptTemplates: true }),
                        ).catch(() => sendNewConversationReply(false));
                    } catch {
                        sendNewConversationReply(false);
                    }
                } else if (command.type === "complete" && typeof command.id === "string") {
                    void runCompletion(command, socket);
                } else if (command.type === "cancelComplete" && typeof command.id === "string") {
                    cancelCompletion(command.id);
                } else if (command.type === "send" && typeof command.id === "string") {
                    const text = typeof command.text === "string" ? command.text : "";
                    const normalized = normalizeAttachments(command.attachments);
                    const hasContent = Boolean(text.trim()) || normalized.attachments.length > 0;
                    if (pending || configPending || pendingNewConversation || waiting || !ctx.isIdle()
                        || !normalized.valid || !hasContent
                        || Buffer.byteLength(text) > 128 * 1024) {
                        emit({ type: "reply", id: command.id, accepted: false, ...state() });
                        continue;
                    }
                    pending = { id: command.id, owner: socket, timer: setTimeout(() => sendReply(false), 25000).unref() };
                    // Wait for Pi to start the run before clearing the draft in Macterm.
                    if (normalized.attachments.length === 0) {
                        pi.sendUserMessage(text);
                    } else {
                        const blocks: Array<
                            | { type: "text"; text: string }
                            | { type: "image"; data: string; mimeType: string }
                        > = [];
                        if (text.length > 0) {
                            blocks.push({ type: "text", text });
                        }
                        for (const attachment of normalized.attachments) {
                            if (attachment.kind === "image" && attachment.data) {
                                blocks.push({
                                    type: "image",
                                    data: attachment.data,
                                    mimeType: attachment.mimeType,
                                });
                            } else if (attachment.kind === "text") {
                                blocks.push({
                                    type: "text",
                                    text: formatTextAttachment(attachment),
                                });
                            }
                        }
                        pi.sendUserMessage(blocks);
                    }
                }
            }
        });
    });

    function register() {
        if (closed || peer || registration) return;
        const target = resolveRegistrationSocket(agentSocket, controlSocket);
        if (!target) return;
        try {
            const info = statSync(target);
            if (!info.isSocket()) return;
            const identity = `${target}:${info.dev}:${info.ino}:${info.birthtimeMs}`;
            if (identity === registeredSocket) return;
            registeringSocket = identity;
        } catch { return; }
        token = randomUUID();
        const socket = createConnection(target);
        registration = socket;
        socket.unref().setTimeout(3000);
        socket.once("connect", () => socket.end(JSON.stringify({
            v: 1, id: token, command: "pi.register",
            args: { session, piBridge: { conversation, socket: path, token } },
        }) + "\n"));
        socket.on("timeout", () => socket.destroy());
        socket.on("error", () => socket.destroy());
        socket.on("close", () => { registration = undefined; });
        socket.resume();
    }

    const timer = setInterval(register, 2000).unref();
    function close() {
        if (closed) return;
        closed = true;
        cancelCompletionsForSocket();
        if (currentMode === "plan") {
            applyMode("edit");
        }
        clearInterval(timer);
        if (pending) {
            clearTimeout(pending.timer);
            pending = undefined;
        }
        if (pendingNewConversation) {
            clearTimeout(pendingNewConversation.timer);
            pendingNewConversation = undefined;
        }
        registration?.destroy();
        for (const socket of connected) socket.destroy();
        server.close();
        try { unlinkSync(path); } catch {}
        try { rmdirSync(directory); } catch {}
    }
    server.on("error", close);
    server.listen(path, register).unref();

    return {
        close, snapshot, status, config,
        acceptSend: () => sendReply(true),
        rejectNewConversation: () => sendNewConversationReply(false),
        setWaiting(value: boolean) { waiting = value; status(); },
        beforeAgentStart(event: BeforeAgentStartEvent): BeforeAgentStartEventResult | undefined {
            if (currentMode !== "plan") return undefined;
            return { systemPrompt: `${event.systemPrompt}${PLAN_MODE_SYSTEM_PROMPT}` };
        },
        onToolCall(event: ToolCallEvent): ToolCallEventResult | undefined {
            if (currentMode !== "plan" || isReadOnlyTool(event.toolName)) return undefined;
            return {
                block: true,
                reason: "Blocked in Plan mode. Switch to Edit mode before editing files or running commands.",
            };
        },
        message(message: Message, phase: "start" | "update" | "end") {
            if (message.role !== "user" && message.role !== "assistant") return;
            let id = activeMessages.get(message.role);
            if (!id || phase === "start") {
                id = `live:${++messageID}`;
                activeMessages.set(message.role, id);
            }
            const row = messageRow(id, message);
            if (row) emit({ type: "row", row });
            if (phase === "end") activeMessages.delete(message.role);
        },
        tool(id: string, name: string, status: NonNullable<Row["status"]>, result: unknown, args?: unknown) {
            if (args !== undefined) {
                toolArguments.set(id, textContent(JSON.stringify(args, null, 2)));
            }
            const output = textContent((result as { content?: unknown } | undefined)?.content);
            const text = [toolArguments.get(id), output].filter(Boolean).join("\n\n");
            emit({ type: "row", row: { id: `tool:${id}`, kind: "tool", name, status, text } });
            if (status !== "running") toolArguments.delete(id);
        },
    };
}
