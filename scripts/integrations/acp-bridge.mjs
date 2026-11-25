import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmdirSync, statSync, unlinkSync } from "node:fs";
import { createConnection, createServer } from "node:net";
import { basename, dirname } from "node:path";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { stripVTControlCharacters } from "node:util";

const MAX_ATTACHMENTS = 10;
const MAX_TEXT_ATTACHMENT_BYTES = 128 * 1024;
const MAX_IMAGE_ATTACHMENT_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_ATTACHMENT_BYTES = 12 * 1024 * 1024;

export const PRESETS = {
    agy: {
        provider: "antigravity",
        name: "Antigravity",
        command: "agy",
        args: ["acp", "--stdio"],
        prompt: "agy> ",
        clientName: "Ghostty",
    },
    opencode: {
        provider: "opencode",
        name: "OpenCode",
        command: "opencode",
        args: ["acp"],
        prompt: "opencode> ",
        clientName: "Macterm",
    },
};

export function clean(text) {
    return stripVTControlCharacters(String(text ?? "")).replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "");
}

function decodedBase64Bytes(base64) {
    const compact = String(base64 ?? "").replace(/\s+/g, "");
    if (!compact) return 0;
    const padding = compact.endsWith("==") ? 2 : compact.endsWith("=") ? 1 : 0;
    return Math.max(0, Math.floor((compact.length * 3) / 4) - padding);
}

function attachmentNameFromUri(uri, fallback) {
    if (typeof uri === "string" && uri.trim()) {
        try {
            const parsed = new URL(uri);
            const candidate = decodeURIComponent(basename(parsed.pathname || ""));
            if (candidate) return clean(candidate).slice(0, 128);
        } catch {
            const candidate = basename(uri);
            if (candidate) return clean(candidate).slice(0, 128);
        }
    }
    return fallback;
}

export function formatTextAttachment(attachment) {
    const name = clean(attachment.name || "attachment.txt").replace(/[\r\n]/g, " ");
    return `--- Attached file: ${name} ---\n${attachment.text ?? ""}\n--- End of ${name} ---`;
}

export function normalizeAttachments(rawAttachments) {
    if (rawAttachments === undefined || rawAttachments === null) {
        return { valid: true, attachments: [] };
    }
    if (!Array.isArray(rawAttachments) || rawAttachments.length > MAX_ATTACHMENTS) {
        return { valid: false, attachments: [] };
    }
    const attachments = [];
    let totalBytes = 0;
    for (const item of rawAttachments) {
        if (!item || typeof item !== "object") return { valid: false, attachments: [] };
        const kind = item.kind;
        const id = typeof item.id === "string" && item.id.trim() ? item.id.slice(0, 128) : randomUUID();
        const name = clean(item.name || (kind === "image" ? "image.png" : "attachment.txt")).trim().slice(0, 128)
            || (kind === "image" ? "image.png" : "attachment.txt");
        const path = typeof item.path === "string" && item.path.trim() ? item.path.slice(0, 1024) : undefined;

        if (kind === "image") {
            const mimeType = typeof item.mimeType === "string" ? item.mimeType.trim().toLowerCase() : "";
            const data = typeof item.data === "string" ? item.data.trim() : "";
            if (!mimeType.startsWith("image/") || !data) return { valid: false, attachments: [] };
            const byteCount = decodedBase64Bytes(data);
            if (byteCount <= 0 || byteCount > MAX_IMAGE_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            totalBytes += byteCount;
            if (totalBytes > MAX_TOTAL_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            attachments.push({
                id,
                kind: "image",
                name,
                mimeType,
                data,
                byteCount,
                ...(path ? { path } : {}),
            });
        } else if (kind === "text") {
            if (typeof item.text !== "string") return { valid: false, attachments: [] };
            const text = item.text;
            const byteCount = Buffer.byteLength(text, "utf8");
            if (byteCount > MAX_TEXT_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            totalBytes += byteCount;
            if (totalBytes > MAX_TOTAL_ATTACHMENT_BYTES) return { valid: false, attachments: [] };
            const mimeType = typeof item.mimeType === "string" && item.mimeType.trim()
                ? item.mimeType.trim().slice(0, 128)
                : "text/plain";
            attachments.push({
                id,
                kind: "text",
                name,
                mimeType,
                text,
                byteCount,
                ...(path ? { path } : {}),
            });
        } else {
            return { valid: false, attachments: [] };
        }
    }
    return { valid: true, attachments };
}

export function buildAcpPromptBlocks(text, attachments, promptCapabilities = {}) {
    const blocks = [];
    if (typeof text === "string" && text.length > 0) {
        blocks.push({ type: "text", text });
    }
    for (const attachment of attachments) {
        if (attachment.kind === "image") {
            const block = {
                type: "image",
                mimeType: attachment.mimeType,
                data: attachment.data,
            };
            if (attachment.path) {
                try {
                    block.uri = pathToFileURL(attachment.path).href;
                } catch {}
            }
            blocks.push(block);
        } else if (attachment.kind === "text") {
            if (promptCapabilities?.embeddedContext === true) {
                let uri = `file:///${encodeURIComponent(attachment.name)}`;
                if (attachment.path) {
                    try {
                        uri = pathToFileURL(attachment.path).href;
                    } catch {}
                }
                blocks.push({
                    type: "resource",
                    resource: {
                        uri,
                        mimeType: attachment.mimeType || "text/plain",
                        text: attachment.text ?? "",
                    },
                });
            } else {
                blocks.push({
                    type: "text",
                    text: formatTextAttachment(attachment),
                });
            }
        }
    }
    return blocks;
}

function inferConfigCategory(id, category) {
    if (typeof category === "string" && category.trim()) return category.trim();
    switch (String(id ?? "").toLowerCase()) {
        case "model":
            return "model";
        case "thought_level":
        case "thinking_level":
        case "effort":
        case "reasoning_effort":
            return "thought_level";
        case "speed":
        case "fast":
        case "service_tier":
        case "model_speed":
            return "speed";
        case "mode":
        case "session_mode":
        case "agent_mode":
            return "mode";
        default:
            return undefined;
    }
}

function flattenSelectOptions(rawOptions) {
    if (!Array.isArray(rawOptions)) return [];
    const seen = new Set();
    const choices = [];
    const pushChoice = (entry, group) => {
        if (!entry || typeof entry.value !== "string" || seen.has(entry.value)) return;
        seen.add(entry.value);
        const choice = {
            value: entry.value,
            name: clean(entry.name || entry.value),
        };
        if (typeof entry.description === "string" && entry.description.trim()) {
            choice.description = clean(entry.description).slice(0, 256);
        }
        if (group) choice.group = group;
        choices.push(choice);
    };
    for (const entry of rawOptions) {
        if (entry && Array.isArray(entry.options)) {
            const group = clean(entry.name || entry.group || "") || undefined;
            for (const nested of entry.options) pushChoice(nested, group);
        } else {
            pushChoice(entry, undefined);
        }
    }
    return choices;
}

function normalizeLegacyModes(rawModes) {
    if (!rawModes || !Array.isArray(rawModes.availableModes) || rawModes.availableModes.length === 0) {
        return undefined;
    }
    const seen = new Set();
    const options = [];
    for (const mode of rawModes.availableModes) {
        const value = mode?.id ?? mode?.modeId;
        if (typeof value !== "string" || !value || seen.has(value)) continue;
        seen.add(value);
        const choice = { value, name: clean(mode.name || value) };
        if (typeof mode.description === "string" && mode.description.trim()) {
            choice.description = clean(mode.description).slice(0, 256);
        }
        options.push(choice);
    }
    if (options.length === 0) return undefined;
    const currentValue = typeof rawModes.currentModeId === "string"
        && options.some(choice => choice.value === rawModes.currentModeId)
        ? rawModes.currentModeId
        : options[0].value;
    return {
        id: "mode",
        name: "Mode",
        category: "mode",
        currentValue,
        options,
    };
}

export function normalizeConfigOptions(rawConfigOptions, rawModels, rawModes) {
    const booleanIds = new Set();
    const normalized = [];
    let usesLegacyModels = false;
    let usesLegacyModes = false;

    if (Array.isArray(rawConfigOptions) && rawConfigOptions.length > 0) {
        for (const item of rawConfigOptions) {
            if (!item || typeof item.id !== "string" || !item.id.trim()) continue;
            const id = item.id;
            const name = clean(item.name || id);
            const category = inferConfigCategory(id, item.category);
            if (item.type === "boolean") {
                booleanIds.add(id);
                normalized.push({
                    id,
                    name,
                    ...(category ? { category } : {}),
                    currentValue: item.currentValue ? "true" : "false",
                    options: [
                        { value: "false", name: "Off" },
                        { value: "true", name: "On" },
                    ],
                });
                continue;
            }
            const options = flattenSelectOptions(item.options);
            if (options.length === 0) continue;
            const currentValue = typeof item.currentValue === "string" ? item.currentValue : options[0].value;
            normalized.push({
                id,
                name,
                ...(category ? { category } : {}),
                currentValue,
                options,
            });
        }
    } else if (rawModels && Array.isArray(rawModels.availableModels) && rawModels.availableModels.length > 0) {
        const seen = new Set();
        const options = [];
        for (const model of rawModels.availableModels) {
            const value = model?.modelId ?? model?.id;
            if (typeof value !== "string" || !value || seen.has(value)) continue;
            seen.add(value);
            const choice = { value, name: clean(model.name || value) };
            if (typeof model.description === "string" && model.description.trim()) {
                choice.description = clean(model.description).slice(0, 256);
            }
            options.push(choice);
        }
        if (options.length > 0) {
            const currentValue = typeof rawModels.currentModelId === "string"
                ? rawModels.currentModelId
                : options[0].value;
            normalized.push({
                id: "model",
                name: "Model",
                category: "model",
                currentValue,
                options,
            });
            usesLegacyModels = true;
        }
    }

    if (!normalized.some(item => item.category === "mode")) {
        const legacyMode = normalizeLegacyModes(rawModes);
        if (legacyMode) {
            normalized.push(legacyMode);
            usesLegacyModes = true;
        }
    }

    return { configOptions: normalized, usesLegacyModels, usesLegacyModes, booleanIds };
}

export function detectCanResume(agentCapabilities) {
    if (!agentCapabilities || typeof agentCapabilities !== "object") return false;
    const sessionCaps = agentCapabilities.sessionCapabilities ?? agentCapabilities.session_capabilities;
    const canList = Boolean(
        sessionCaps && typeof sessionCaps === "object" && sessionCaps.list !== undefined && sessionCaps.list !== false,
    );
    const canLoad = Boolean(
        agentCapabilities.loadSession === true
        || agentCapabilities.load_session === true
        || (sessionCaps && typeof sessionCaps === "object"
            && sessionCaps.load !== undefined && sessionCaps.load !== false),
    );
    return canList && canLoad;
}

export function normalizeSessionList(result) {
    const rawSessions = Array.isArray(result?.sessions) ? result.sessions : [];
    const seen = new Set();
    const sessions = [];
    for (const item of rawSessions) {
        const id = typeof item?.sessionId === "string" ? item.sessionId.trim() : "";
        if (!id || id.length > 256 || seen.has(id)) continue;
        seen.add(id);
        const rawTitle = typeof item?.title === "string" ? clean(item.title).replace(/\s+/g, " ").trim() : "";
        const entry = {
            id,
            title: (rawTitle || id).slice(0, 256),
        };
        if (typeof item?.updatedAt === "string" && item.updatedAt.trim()) {
            entry.updatedAt = clean(item.updatedAt).trim().slice(0, 64);
        }
        if (typeof item?.cwd === "string" && item.cwd.trim()) {
            entry.cwd = clean(item.cwd).trim().slice(0, 1024);
        }
        sessions.push(entry);
    }
    const nextCursor = typeof result?.nextCursor === "string" && result.nextCursor.trim()
        ? result.nextCursor
        : undefined;
    return { sessions, nextCursor };
}

export function formatToolText(update, previous) {
    const details = Array.isArray(update.content)
        ? update.content.flatMap(item => {
            if (item?.type === "content" && item.content?.type === "text") return [item.content.text];
            if (item?.type === "diff") return [item.path, item.newText];
            return [];
        }).filter(Boolean).join("\n")
        : "";
    if (details) return clean(details).slice(0, 64 * 1024);

    if (update.rawOutput !== undefined && update.rawOutput !== null) {
        const output = typeof update.rawOutput === "string"
            ? update.rawOutput
            : JSON.stringify(update.rawOutput, null, 2);
        if (output) return clean(output).slice(0, 64 * 1024);
    }

    if (previous?.text) return previous.text;

    if (update.rawInput !== undefined && update.rawInput !== null) {
        const input = typeof update.rawInput === "string"
            ? update.rawInput
            : JSON.stringify(update.rawInput, null, 2);
        return clean(input).slice(0, 64 * 1024);
    }

    return "";
}

export function formatPermissionDetails(toolCall) {
    if (!toolCall || typeof toolCall !== "object") return "";
    if (toolCall.rawInput !== undefined && toolCall.rawInput !== null) {
        const input = typeof toolCall.rawInput === "string"
            ? toolCall.rawInput
            : JSON.stringify(toolCall.rawInput, null, 2);
        const cleaned = clean(input).trim();
        if (cleaned) return cleaned.slice(0, 16 * 1024);
    }
    const details = Array.isArray(toolCall.content)
        ? toolCall.content.flatMap(item => {
            if (item?.type === "content" && item.content?.type === "text") return [item.content.text];
            if (item?.type === "diff") return [item.path, item.newText];
            return [];
        }).filter(Boolean).join("\n")
        : "";
    return clean(details).trim().slice(0, 16 * 1024);
}

export function normalizePermissionOptions(rawOptions) {
    if (!Array.isArray(rawOptions)) return [];
    const seen = new Set();
    const options = [];
    for (const item of rawOptions) {
        if (!item || typeof item.optionId !== "string" || !item.optionId || seen.has(item.optionId)) continue;
        seen.add(item.optionId);
        const option = {
            optionId: item.optionId,
            name: clean(item.name || item.optionId).slice(0, 256),
        };
        if (typeof item.kind === "string" && item.kind.trim()) {
            option.kind = clean(item.kind).trim().slice(0, 64);
        }
        options.push(option);
    }
    return options;
}

export function parseBridgeArgs(argv, presetName) {
    if (presetName) {
        const preset = PRESETS[presetName];
        if (!preset) throw new Error(`Unknown ACP preset: ${presetName}`);
        const usage = `Usage: macterm-${presetName} [--conversation ID]`;
        if (argv.length === 1 && ["--help", "-h"].includes(argv[0])) return { help: usage };
        if (argv.length === 0) return { ...preset, conversation: undefined };
        if (argv.length === 2 && argv[0] === "--conversation" && argv[1]) {
            return { ...preset, conversation: argv[1] };
        }
        throw new Error(usage);
    }

    const presetList = Object.keys(PRESETS).join("|");
    const usage = [
        `Usage: macterm-acp <${presetList}> [--conversation ID]`,
        "       macterm-acp [--name NAME] [--prompt PROMPT] [--conversation ID] -- <command> [args...]",
    ].join("\n");

    if (argv.length === 0 || (argv.length === 1 && ["--help", "-h"].includes(argv[0]))) {
        return { help: usage };
    }

    const separator = argv.indexOf("--");
    const optionArgs = separator === -1 ? argv : argv.slice(0, separator);
    const commandArgs = separator === -1 ? [] : argv.slice(separator + 1);

    let chosenPreset;
    let conversation;
    let customName;
    let customPrompt;

    for (let i = 0; i < optionArgs.length; i++) {
        const arg = optionArgs[i];
        if (arg === "--help" || arg === "-h") {
            return { help: usage };
        } else if (arg === "--conversation") {
            conversation = optionArgs[++i];
            if (!conversation) throw new Error(usage);
        } else if (arg === "--name") {
            customName = optionArgs[++i];
            if (!customName) throw new Error(usage);
        } else if (arg === "--prompt") {
            customPrompt = optionArgs[++i];
            if (!customPrompt) throw new Error(usage);
        } else if (!arg.startsWith("-") && !chosenPreset && commandArgs.length === 0) {
            if (!PRESETS[arg]) throw new Error(`Unknown ACP preset: ${arg}\n${usage}`);
            chosenPreset = PRESETS[arg];
        } else {
            throw new Error(usage);
        }
    }

    if (chosenPreset) {
        if (commandArgs.length > 0) throw new Error(usage);
        return {
            ...chosenPreset,
            name: customName || chosenPreset.name,
            provider: customName || chosenPreset.provider,
            prompt: customPrompt || chosenPreset.prompt,
            conversation,
        };
    }

    if (commandArgs.length === 0) throw new Error(usage);
    const [command, ...args] = commandArgs;
    const base = basename(command);
    const name = customName || base;
    return {
        provider: customName || base,
        name,
        command,
        args,
        prompt: customPrompt || `${base}> `,
        clientName: "Macterm",
        conversation,
    };
}

export async function runAcpBridge(config, runtime = {}) {
    const env = runtime.env ?? process.env;
    const inputStream = runtime.input ?? process.stdin;
    const outputStream = runtime.output ?? process.stdout;
    const errorStream = runtime.error ?? process.stderr;
    const requireTTY = runtime.requireTTY ?? true;
    const startupTimeoutMs = runtime.startupTimeoutMs ?? 30000;
    const cwd = runtime.cwd ?? process.cwd();
    const pane = env.MACTERM_SESSION;
    const agentSocket = env.MACTERM_AGENT_SOCKET;
    const controlSocket = env.MACTERM_SOCKET;

    if (!pane || (!agentSocket && !controlSocket) || (requireTTY && !inputStream.isTTY)) {
        errorStream.write(`Run this bridge in a local pane in a Macterm main window.\n`);
        process.exitCode = 1;
        return;
    }

    const directory = mkdtempSync("/tmp/macterm-agent-");
    const path = `${directory}/bridge.sock`;
    const agent = spawn(config.command, config.args, {
        cwd,
        env: { ...env, MACTERM_NO_AGENT_GUI: "1" },
        stdio: ["pipe", "pipe", "inherit"],
    });
    const terminal = createInterface({ input: inputStream, output: outputStream, prompt: config.prompt });
    const inflight = new Map();
    const rows = new Map();
    const sockets = new Set();
    const permissions = new Map();
    const completions = new Map();
    const completionBySession = new Map();
    let nextID = 0;
    let sessionID;
    let turn;
    let message;
    let peer;
    let registration;
    let challenge;
    let boundSocket;
    let closed = false;
    let configOptions = [];
    let usesLegacyModels = false;
    let usesLegacyModes = false;
    let booleanConfigIds = new Set();
    let promptCapabilities = {};
    let canResume = false;
    let configPending = false;
    let newConversationPending = false;
    let resumePending = false;
    let loadingSession;

    const writeOut = text => outputStream.write(text);
    const writeErr = text => errorStream.write(text);

    function applySessionConfig(rawConfigOptions, rawModels, rawModes) {
        const next = normalizeConfigOptions(rawConfigOptions, rawModels, rawModes);
        configOptions = next.configOptions;
        usesLegacyModels = next.usesLegacyModels;
        usesLegacyModes = next.usesLegacyModes;
        booleanConfigIds = next.booleanIds;
    }

    function mergeUpdatedConfigOptions(rawConfigOptions) {
        const next = normalizeConfigOptions(rawConfigOptions, undefined, undefined);
        const hasNativeMode = next.configOptions.some(item => item.category === "mode");
        let merged = next.configOptions;
        if (hasNativeMode) {
            usesLegacyModes = false;
        } else if (usesLegacyModes) {
            const existingMode = configOptions.find(item => item.category === "mode");
            if (existingMode) merged = [...merged, existingMode];
        }
        configOptions = merged;
        usesLegacyModels = false;
        booleanConfigIds = next.booleanIds;
    }

    function updateConfigOptions(rawConfigOptions) {
        mergeUpdatedConfigOptions(rawConfigOptions);
        emit({ type: "config", configOptions });
    }

    function rpc(frame) {
        if (!closed && agent.stdin.writable) {
            agent.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...frame }) + "\n");
        }
    }

    function request(method, params) {
        return new Promise((resolve, reject) => {
            const id = ++nextID;
            inflight.set(id, { resolve, reject });
            rpc({ id, method, params });
        });
    }

    function serializedPermissions() {
        return Array.from(permissions.values(), entry => entry.payload);
    }

    function state() {
        return {
            busy: Boolean(turn),
            waiting: permissions.size > 0,
            permissions: serializedPermissions(),
        };
    }

    function emit(frame) {
        if (peer?.writableLength > 32 * 1024 * 1024) peer.destroy();
        if (peer?.writable) peer.write(JSON.stringify(frame) + "\n");
    }

    function status() {
        emit({ type: "status", ...state() });
    }

    function upsert(row) {
        rows.set(row.id, row);
        emit({ type: "row", row });
    }

    function applyRowUpdate(targetRows, currentMessage, update, { silent = false, skipUserDuringTurn = false } = {}) {
        const { sessionUpdate: type, content } = update;
        if (type === "user_message_chunk" && skipUserDuringTurn && turn) return currentMessage;
        let nextMessage = currentMessage;
        const writeRow = row => {
            targetRows.set(row.id, row);
            if (!silent) emit({ type: "row", row });
        };

        if (type === "agent_message_chunk" || type === "user_message_chunk") {
            const kind = type === "agent_message_chunk" ? "assistant" : "user";
            if (content?.type === "text") {
                if (nextMessage?.kind !== kind) nextMessage = { id: randomUUID(), kind, text: "" };
                const text = clean(content.text);
                if (kind === "assistant" && !silent) writeOut(text);
                nextMessage = { ...nextMessage, text: (nextMessage.text + text).slice(0, 64 * 1024) };
                writeRow(nextMessage);
            } else if (content?.type === "image" && typeof content.data === "string" && typeof content.mimeType === "string") {
                const byteCount = decodedBase64Bytes(content.data);
                if (byteCount <= 0 || byteCount > MAX_IMAGE_ATTACHMENT_BYTES) return nextMessage;
                if (nextMessage?.kind !== kind) nextMessage = { id: randomUUID(), kind, text: "" };
                const ext = content.mimeType.split("/")[1]?.split(";")[0] || "png";
                const attachment = {
                    id: randomUUID(),
                    kind: "image",
                    name: attachmentNameFromUri(content.uri, `image.${ext}`),
                    mimeType: content.mimeType,
                    data: content.data,
                    byteCount,
                };
                const existing = Array.isArray(nextMessage.attachments) ? nextMessage.attachments : [];
                if (existing.length < MAX_ATTACHMENTS) {
                    nextMessage = { ...nextMessage, attachments: [...existing, attachment] };
                    writeRow(nextMessage);
                }
            } else if (content?.type === "resource" && typeof content.resource?.text === "string") {
                const text = clean(content.resource.text);
                const byteCount = Buffer.byteLength(text, "utf8");
                if (byteCount > MAX_TEXT_ATTACHMENT_BYTES) return nextMessage;
                if (nextMessage?.kind !== kind) nextMessage = { id: randomUUID(), kind, text: "" };
                const attachment = {
                    id: randomUUID(),
                    kind: "text",
                    name: attachmentNameFromUri(content.resource.uri, "attachment.txt"),
                    mimeType: typeof content.resource.mimeType === "string" ? content.resource.mimeType : "text/plain",
                    text,
                    byteCount,
                };
                const existing = Array.isArray(nextMessage.attachments) ? nextMessage.attachments : [];
                if (existing.length < MAX_ATTACHMENTS) {
                    nextMessage = { ...nextMessage, attachments: [...existing, attachment] };
                    writeRow(nextMessage);
                }
            }
            return nextMessage;
        }

        if (type === "tool_call" || type === "tool_call_update") {
            nextMessage = undefined;
            const id = `tool:${update.toolCallId}`;
            const previous = targetRows.get(id);
            const name = clean(update.title) || previous?.name || update.kind || "Tool";
            const toolStatus = update.status === "failed" ? "failed"
                : update.status === "completed" ? "completed"
                : update.status ? "running" : previous?.status ?? "running";
            const text = formatToolText(update, previous);
            if (!previous && !silent) writeOut(`\n${name}\n`);
            writeRow({ id, kind: "tool", text, name, status: toolStatus });
            return nextMessage;
        }

        return nextMessage;
    }

    function update({ update }) {
        if (!update) return;
        const { sessionUpdate: type } = update;
        if (type === "agent_message_chunk" || type === "user_message_chunk"
            || type === "tool_call" || type === "tool_call_update") {
            message = applyRowUpdate(rows, message, update, { silent: false, skipUserDuringTurn: true });
        } else if ((type === "config_option_update" || type === "config_options_update")
            && Array.isArray(update.configOptions)) {
            updateConfigOptions(update.configOptions);
        } else if (type === "current_model_update" && usesLegacyModels && typeof update.modelId === "string") {
            configOptions = configOptions.map(option =>
                option.id === "model" ? { ...option, currentValue: update.modelId } : option,
            );
            emit({ type: "config", configOptions });
        } else if (type === "current_mode_update" && typeof update.currentModeId === "string") {
            const nextMode = update.currentModeId;
            let changed = false;
            configOptions = configOptions.map(option => {
                if (option.category === "mode"
                    && option.currentValue !== nextMode
                    && option.options.some(choice => choice.value === nextMode)) {
                    changed = true;
                    return { ...option, currentValue: nextMode };
                }
                return option;
            });
            if (changed) emit({ type: "config", configOptions });
        }
    }

    function showPermission() {
        const req = permissions.values().next().value;
        if (!req) return;
        writeOut(`\nPermission required for ${req.payload.title}.\n`);
        if (req.payload.details) {
            writeOut(`${req.payload.details}\n`);
        }
        for (const [index, option] of req.payload.options.entries()) {
            writeOut(`${index + 1}. ${option.name}\n`);
        }
        writeOut("0. Cancel\n");
        terminal.setPrompt("Select an option> ");
        terminal.prompt();
    }

    function enqueuePermission(rpcId, params) {
        const permissionId = randomUUID();
        const title = (clean(params.toolCall?.title) || clean(params.toolCall?.kind) || "Tool").slice(0, 512);
        const details = formatPermissionDetails(params.toolCall);
        const options = normalizePermissionOptions(params.options);
        const payload = {
            id: permissionId,
            title,
            ...(details ? { details } : {}),
            options,
        };
        permissions.set(permissionId, { id: permissionId, rpcId, payload });
        if (permissions.size === 1) showPermission();
        status();
    }

    function resolvePermission(permissionId, optionId, owner, commandId) {
        const reply = accepted => {
            if (owner && owner === peer) {
                emit({ type: "permissionReply", id: commandId, accepted, ...state() });
            }
        };
        const req = permissions.get(permissionId);
        if (!req) {
            reply(false);
            return;
        }
        let outcome;
        let choiceLabel = "Cancelled";
        if (optionId !== undefined && optionId !== null) {
            if (typeof optionId !== "string") {
                reply(false);
                return;
            }
            const option = req.payload.options.find(item => item.optionId === optionId);
            if (!option) {
                reply(false);
                return;
            }
            outcome = { outcome: "selected", optionId: option.optionId };
            choiceLabel = option.name;
        } else {
            outcome = { outcome: "cancelled" };
        }

        const wasCurrent = permissions.keys().next().value === permissionId;
        rpc({ id: req.rpcId, result: { outcome } });
        permissions.delete(permissionId);
        if (owner && !closed) {
            writeOut(`\n${choiceLabel}\n`);
        }
        if (permissions.size > 0) {
            if (wasCurrent) showPermission();
        } else {
            terminal.setPrompt(config.prompt);
            if (!closed && !turn) terminal.prompt();
        }
        if (owner) reply(true);
        else status();
    }

    function cancelPermissions() {
        for (const req of permissions.values()) {
            rpc({ id: req.rpcId, result: { outcome: { outcome: "cancelled" } } });
        }
        permissions.clear();
        terminal.setPrompt(config.prompt);
        status();
    }

    const agentOutput = createInterface({ input: agent.stdout, crlfDelay: Infinity });
    agentOutput.on("line", line => {
        let frame;
        try { frame = JSON.parse(line); } catch { return; }
        const { id, method, params, result, error } = frame;
        const completion = typeof params?.sessionId === "string"
            ? completionBySession.get(params.sessionId)
            : undefined;
        if (completion) {
            if (method === "session/update") {
                const chunk = params?.update;
                if (chunk?.sessionUpdate === "agent_message_chunk"
                    && chunk?.content?.type === "text"
                    && typeof chunk.content.text === "string") {
                    completion.text = (completion.text + clean(chunk.content.text)).slice(0, 16 * 1024);
                    if (!completion.cancelled && completion.owner === peer) {
                        emit({ type: "completeUpdate", id: completion.id, text: completion.text });
                    }
                }
            } else if (method === "session/request_permission" && id !== undefined) {
                rpc({ id, result: { outcome: { outcome: "cancelled" } } });
            } else if (method && id !== undefined) {
                rpc({ id, error: { code: -32601, message: "This client does not support the request." } });
            }
            return;
        }
        if (loadingSession && params?.sessionId === loadingSession.sessionId) {
            if (method === "session/update" && params?.update) {
                loadingSession.message = applyRowUpdate(
                    loadingSession.rows,
                    loadingSession.message,
                    params.update,
                    { silent: true },
                );
            } else if (method === "session/request_permission" && id !== undefined) {
                rpc({ id, result: { outcome: { outcome: "cancelled" } } });
            } else if (method && id !== undefined) {
                rpc({ id, error: { code: -32601, message: "This client does not support the request." } });
            }
            return;
        }
        if (method === "session/update" && (!sessionID || params?.sessionId === sessionID)) {
            update(params);
        } else if (method === "session/request_permission" && id !== undefined && params?.sessionId === sessionID) {
            enqueuePermission(id, params);
        } else if (method && id !== undefined) {
            rpc({ id, error: { code: -32601, message: "This client does not support the request." } });
        } else if (!method && inflight.has(id)) {
            const { resolve, reject } = inflight.get(id);
            inflight.delete(id);
            if (error) reject(new Error(error.message));
            else resolve(result);
        }
    });

    async function prompt(text, attachments, owner, id) {
        const normalizedText = typeof text === "string" ? text : "";
        const normalized = normalizeAttachments(attachments);
        const hasContent = Boolean(normalizedText.trim()) || normalized.attachments.length > 0;
        if (!sessionID || turn || permissions.size || configPending || newConversationPending || resumePending
            || !normalized.valid || !hasContent
            || Buffer.byteLength(normalizedText) > 128 * 1024) {
            if (owner === peer && owner) emit({ type: "reply", id, accepted: false, ...state() });
            return;
        }
        const promptBlocks = buildAcpPromptBlocks(normalizedText, normalized.attachments, promptCapabilities);
        turn = { id, owner, text: normalizedText };
        message = undefined;
        upsert({
            id: randomUUID(),
            kind: "user",
            text: clean(normalizedText),
            ...(normalized.attachments.length ? { attachments: normalized.attachments } : {}),
        });
        if (owner && owner === peer) emit({ type: "reply", id, accepted: true, ...state() });
        else status();
        try {
            await request("session/prompt", { sessionId: sessionID, prompt: promptBlocks });
        } catch (error) {
            if (!closed) {
                upsert({ id: randomUUID(), kind: "assistant", text: clean(error.message) });
                writeErr(`\n${clean(error.message)}\n`);
            }
        } finally {
            turn = undefined;
            status();
            if (!closed && !permissions.size) {
                writeOut("\n");
                terminal.prompt();
            }
        }
    }

    function stop() {
        if (!turn && !permissions.size) return;
        rpc({ method: "session/cancel", params: { sessionId: sessionID } });
        cancelPermissions();
    }

    async function setConfig(configId, value, owner, id) {
        const reply = accepted => {
            if (owner && owner === peer) emit({ type: "configReply", id, accepted, configOptions, ...state() });
        };
        const option = configOptions.find(item => item.id === configId);
        if (!sessionID || turn || permissions.size || configPending || newConversationPending || resumePending
            || typeof configId !== "string"
            || typeof value !== "string" || !option || !option.options.some(choice => choice.value === value)) {
            reply(false);
            return;
        }
        configPending = true;
        try {
            if (usesLegacyModels && configId === "model") {
                await request("session/set_model", { sessionId: sessionID, modelId: value });
                configOptions = configOptions.map(item =>
                    item.id === configId ? { ...item, currentValue: value } : item,
                );
            } else if (usesLegacyModes && configId === "mode") {
                await request("session/set_mode", { sessionId: sessionID, modeId: value });
                configOptions = configOptions.map(item =>
                    item.id === configId ? { ...item, currentValue: value } : item,
                );
            } else {
                const wireValue = booleanConfigIds.has(configId) ? value === "true" : value;
                const result = await request("session/set_config_option", {
                    sessionId: sessionID,
                    configId,
                    value: wireValue,
                });
                if (Array.isArray(result?.configOptions)) {
                    mergeUpdatedConfigOptions(result.configOptions);
                } else {
                    configOptions = configOptions.map(item =>
                        item.id === configId ? { ...item, currentValue: value } : item,
                    );
                }
            }
            reply(true);
        } catch (error) {
            if (!closed) writeErr(`\n${clean(error.message)}\n`);
            reply(false);
        } finally {
            configPending = false;
        }
    }

    async function newConversation(owner, id) {
        const reply = accepted => {
            if (owner && owner === peer) {
                emit({
                    type: "newConversationReply",
                    id,
                    accepted,
                    ...(accepted ? { conversation: sessionID, configOptions } : {}),
                    ...state(),
                });
            }
        };
        if (!sessionID || turn || permissions.size || configPending || newConversationPending || resumePending) {
            reply(false);
            return;
        }
        newConversationPending = true;
        try {
            const sessionResult = await request("session/new", { cwd, mcpServers: [] });
            const nextSessionID = sessionResult?.sessionId;
            if (typeof nextSessionID !== "string" || !nextSessionID) {
                throw new Error(`${config.name} did not provide a conversation ID.`);
            }
            sessionID = nextSessionID;
            rows.clear();
            message = undefined;
            applySessionConfig(sessionResult?.configOptions, sessionResult?.models, sessionResult?.modes);
            if (!closed) {
                writeOut(`\n${config.name} conversation: ${clean(sessionID)}\n`);
                if (!permissions.size) terminal.prompt();
            }
            if (owner) {
                reply(true);
            } else {
                emit({ type: "snapshot", conversation: sessionID });
                emit({ type: "snapshotEnd", ...state(), configOptions, canResume });
            }
        } catch (error) {
            if (!closed) writeErr(`\n${clean(error.message)}\n`);
            reply(false);
        } finally {
            newConversationPending = false;
        }
    }

    async function listSessions(cursor, owner, id) {
        const reply = (accepted, extra = {}) => {
            if (owner && owner === peer) {
                emit({ type: "sessionsReply", id, accepted, ...extra });
            }
        };
        if (!sessionID || !canResume || closed) {
            reply(false, { error: "unsupported" });
            return undefined;
        }
        try {
            const params = { cwd };
            if (typeof cursor === "string" && cursor.trim()) {
                params.cursor = cursor.trim();
            }
            const result = await request("session/list", params);
            const normalized = normalizeSessionList(result);
            reply(true, {
                sessions: normalized.sessions,
                ...(normalized.nextCursor ? { nextCursor: normalized.nextCursor } : {}),
            });
            return normalized;
        } catch (error) {
            if (!closed && !owner) writeErr(`\n${clean(error.message)}\n`);
            reply(false, { error: clean(error?.message ?? "list_failed") });
            return undefined;
        }
    }

    async function resumeSession(targetSessionId, owner, id) {
        const reply = accepted => {
            if (owner && owner === peer) {
                emit({
                    type: "resumeSessionReply",
                    id,
                    accepted,
                    ...(accepted ? { conversation: sessionID, configOptions } : {}),
                    ...state(),
                });
            }
        };
        const target = typeof targetSessionId === "string" ? targetSessionId.trim() : "";
        if (!sessionID || !canResume || turn || permissions.size || configPending || newConversationPending
            || resumePending || !target || target.length > 256) {
            reply(false);
            return;
        }
        if (target === sessionID) {
            reply(true);
            return;
        }
        resumePending = true;
        const buffered = { sessionId: target, rows: new Map(), message: undefined };
        loadingSession = buffered;
        try {
            const sessionResult = await request("session/load", {
                cwd,
                mcpServers: [],
                sessionId: target,
            });
            const nextSessionID = typeof sessionResult?.sessionId === "string" && sessionResult.sessionId
                ? sessionResult.sessionId
                : target;
            sessionID = nextSessionID;
            rows.clear();
            for (const [rowId, row] of buffered.rows) {
                rows.set(rowId, row);
            }
            message = undefined;
            if (sessionResult?.configOptions !== undefined
                || sessionResult?.models !== undefined
                || sessionResult?.modes !== undefined) {
                applySessionConfig(sessionResult?.configOptions, sessionResult?.models, sessionResult?.modes);
            }
            loadingSession = undefined;
            if (!closed) {
                writeOut(`\n${config.name} conversation: ${clean(sessionID)}\n`);
                if (!permissions.size) terminal.prompt();
            }
            emit({ type: "snapshot", conversation: sessionID });
            for (const row of rows.values()) emit({ type: "row", row });
            emit({ type: "snapshotEnd", ...state(), configOptions, canResume });
            if (owner) reply(true);
        } catch (error) {
            loadingSession = undefined;
            if (!closed) writeErr(`\n${clean(error.message)}\n`);
            reply(false);
        } finally {
            loadingSession = undefined;
            resumePending = false;
        }
    }

    async function runCompletion(command, owner) {
        const id = command.id;
        const instructions = typeof command.instructions === "string" ? command.instructions.trim() : "";
        const promptText = typeof command.prompt === "string" ? command.prompt.trim() : "";
        const reply = (accepted, extra = {}) => {
            if (owner && owner === peer) emit({ type: "completeReply", id, accepted, ...extra });
        };
        if (closed || !sessionID || !promptText || completions.size >= 2 || completions.has(id)
            || Buffer.byteLength(instructions) + Buffer.byteLength(promptText) > 128 * 1024) {
            reply(false, { error: "unavailable" });
            return;
        }
        const entry = { id, owner, sessionId: undefined, text: "", cancelled: false };
        completions.set(id, entry);
        if (owner === peer) emit({ type: "completeUpdate", id, text: "" });
        try {
            const sessionResult = await request("session/new", { cwd, mcpServers: [] });
            const tempSessionId = sessionResult?.sessionId;
            if (typeof tempSessionId !== "string" || !tempSessionId) {
                throw new Error(`${config.name} did not provide a completion session ID.`);
            }
            entry.sessionId = tempSessionId;
            completionBySession.set(tempSessionId, entry);
            if (entry.cancelled || closed) return;

            const currentModelOption = configOptions.find(item => item.category === "model" || item.id === "model");
            if (currentModelOption?.currentValue) {
                const tempConfig = normalizeConfigOptions(
                    sessionResult?.configOptions,
                    sessionResult?.models,
                    sessionResult?.modes,
                );
                const tempModelOption = tempConfig.configOptions.find(
                    item => item.category === "model" || item.id === "model",
                );
                if (tempModelOption
                    && tempModelOption.currentValue !== currentModelOption.currentValue
                    && tempModelOption.options.some(choice => choice.value === currentModelOption.currentValue)) {
                    try {
                        if (tempConfig.usesLegacyModels && tempModelOption.id === "model") {
                            await request("session/set_model", {
                                sessionId: tempSessionId,
                                modelId: currentModelOption.currentValue,
                            });
                        } else {
                            await request("session/set_config_option", {
                                sessionId: tempSessionId,
                                configId: tempModelOption.id,
                                value: currentModelOption.currentValue,
                            });
                        }
                    } catch {}
                }
            }
            if (entry.cancelled || closed) return;

            const combinedPrompt = instructions ? `${instructions}\n\n${promptText}` : promptText;
            await request("session/prompt", {
                sessionId: tempSessionId,
                prompt: [{ type: "text", text: combinedPrompt }],
            });
            if (entry.cancelled || closed) return;
            const trimmed = entry.text.trim();
            if (trimmed) {
                reply(true, { text: entry.text });
            } else {
                reply(false, { error: "empty" });
            }
        } catch (error) {
            if (!entry.cancelled && !closed) {
                reply(false, { error: clean(error?.message ?? "completion_failed") });
            }
        } finally {
            completions.delete(id);
            if (entry.sessionId) completionBySession.delete(entry.sessionId);
        }
    }

    function cancelCompletion(id) {
        const entry = completions.get(id);
        if (!entry) return;
        entry.cancelled = true;
        if (entry.sessionId && !closed) {
            rpc({ method: "session/cancel", params: { sessionId: entry.sessionId } });
        }
    }

    function cancelCompletionsForSocket(socket) {
        for (const entry of completions.values()) {
            if (!socket || entry.owner === socket) {
                cancelCompletion(entry.id);
            }
        }
    }

    terminal.on("line", line => {
        if (permissions.size) {
            const req = permissions.values().next().value;
            const value = line.trim();
            const option = /^\d+$/.test(value) ? req.payload.options[Number(value) - 1] : undefined;
            if (value !== "0" && !option) return showPermission();
            resolvePermission(req.id, option ? option.optionId : undefined);
        } else if (line === "/exit") {
            close();
        } else if (line === "/new") {
            if (turn || configPending || newConversationPending || resumePending) {
                writeOut("Wait for the current turn to end.\n");
            } else {
                void newConversation();
            }
        } else if (line === "/resume" || line.startsWith("/resume ")) {
            if (!canResume) {
                writeOut(`${config.name} does not support resuming conversations.\n`);
                terminal.prompt();
                return;
            }
            if (turn || configPending || newConversationPending || resumePending) {
                writeOut("Wait for the current turn to end.\n");
                return;
            }
            const target = line.slice("/resume".length).trim();
            if (target) {
                void resumeSession(target);
            } else {
                void listSessions(undefined, undefined, undefined).then(result => {
                    if (closed) return;
                    const list = result?.sessions ?? [];
                    if (list.length === 0) {
                        writeOut("No previous conversations.\n");
                    } else {
                        for (const item of list.slice(0, 20)) {
                            const marker = item.id === sessionID ? "*" : " ";
                            writeOut(`${marker} ${item.id}  ${item.title}\n`);
                        }
                        writeOut("Run /resume <id> to load a conversation.\n");
                    }
                    if (!turn && !permissions.size) terminal.prompt();
                });
            }
        } else if (line.trim()) {
            if (turn || configPending || newConversationPending || resumePending) {
                writeOut("Wait for the current turn to end.\n");
            } else {
                void prompt(line, []);
            }
        } else if (!turn) {
            terminal.prompt();
        }
    });
    terminal.on("SIGINT", () => (turn || permissions.size ? stop() : close()));
    terminal.on("close", close);

    const server = createServer(socket => {
        if (sockets.size >= 4) return socket.destroy();
        sockets.add(socket);
        socket.setTimeout(5000);
        socket.on("timeout", () => socket.destroy());
        socket.on("error", () => socket.destroy());
        socket.on("close", () => {
            sockets.delete(socket);
            cancelCompletionsForSocket(socket);
            if (peer === socket) peer = undefined;
        });
        const input = createInterface({ input: socket, crlfDelay: Infinity });
        input.on("line", line => {
            let command;
            try { command = JSON.parse(line); } catch { return socket.destroy(); }
            if (peer !== socket) {
                if (command?.type !== "hello" || !challenge || String(command.token).toLowerCase() !== challenge.token) {
                    return socket.destroy();
                }
                boundSocket = challenge.identity;
                challenge = undefined;
                peer?.destroy();
                peer = socket;
                socket.setTimeout(0);
                emit({ type: "snapshot", conversation: sessionID });
                for (const row of rows.values()) emit({ type: "row", row });
                emit({ type: "snapshotEnd", ...state(), configOptions, canResume });
            } else if (command?.type === "send" && typeof command.id === "string") {
                void prompt(command.text ?? "", command.attachments, socket, command.id);
            } else if (command?.type === "setConfig" && typeof command.id === "string") {
                void setConfig(command.configId, command.value, socket, command.id);
            } else if (command?.type === "newConversation" && typeof command.id === "string") {
                void newConversation(socket, command.id);
            } else if (command?.type === "listSessions" && typeof command.id === "string") {
                void listSessions(command.cursor, socket, command.id);
            } else if (command?.type === "resumeSession" && typeof command.id === "string") {
                void resumeSession(command.sessionId, socket, command.id);
            } else if (command?.type === "permissionReply" && typeof command.id === "string") {
                resolvePermission(command.permissionId, command.optionId, socket, command.id);
            } else if (command?.type === "complete" && typeof command.id === "string") {
                void runCompletion(command, socket);
            } else if (command?.type === "cancelComplete" && typeof command.id === "string") {
                cancelCompletion(command.id);
            } else if (command?.type === "stop") {
                stop();
            } else if (command?.type === "exit") {
                exitFromGUI();
            }
        });
    });

    function resolveRegistrationSocket() {
        if (agentSocket) return agentSocket;
        if (!controlSocket) return undefined;
        const sibling = `${dirname(controlSocket)}/agent.sock`;
        try {
            if (statSync(sibling).isSocket()) return sibling;
        } catch {}
        return controlSocket;
    }

    function register() {
        if (!sessionID || peer || registration || closed) return;
        const target = resolveRegistrationSocket();
        if (!target) return;
        let identity;
        try {
            const info = statSync(target);
            if (!info.isSocket()) return;
            identity = `${target}:${info.dev}:${info.ino}:${info.birthtimeMs}`;
        } catch { return; }
        if (identity === boundSocket) return;
        const token = randomUUID();
        challenge = { token, identity };
        const socket = createConnection(target);
        registration = socket;
        socket.setTimeout(3000);
        socket.once("connect", () => socket.end(JSON.stringify({
            v: 1,
            id: token,
            command: "agent.register",
            args: {
                session: pane,
                agentBridge: {
                    provider: config.provider,
                    conversation: sessionID,
                    socket: path,
                    token,
                },
            },
        }) + "\n"));
        socket.on("timeout", () => socket.destroy());
        socket.on("error", () => socket.destroy());
        socket.on("close", () => { registration = undefined; });
        socket.resume();
    }

    const retry = setInterval(register, 2000).unref();
    const startup = setTimeout(() => fail(new Error(`${config.name} did not start in time.`)), startupTimeoutMs).unref();

    function exitFromGUI() {
        if (closed) return;
        if (turn || permissions.size) stop();
        writeOut("\n");
        close();
    }

    function close() {
        if (closed) return;
        closed = true;
        cancelCompletionsForSocket();
        completions.clear();
        completionBySession.clear();
        clearTimeout(startup);
        clearInterval(retry);
        registration?.destroy();
        for (const socket of sockets) socket.destroy();
        server.close();
        terminal.close();
        agentOutput.close();
        agent.stdin.destroy();
        agent.kill();
        if (agent.exitCode === null && agent.signalCode === null) {
            setTimeout(() => {
                if (agent.exitCode === null && agent.signalCode === null) {
                    try { agent.kill("SIGKILL"); } catch {}
                }
            }, 2000).unref();
        }
        for (const { reject } of inflight.values()) reject(new Error(`The ${config.name} connection closed.`));
        inflight.clear();
        try { unlinkSync(path); } catch {}
        try { rmdirSync(directory); } catch {}
    }

    function fail(error) {
        if (closed) return;
        writeErr(`${clean(error.message)}\n`);
        process.exitCode = 1;
        close();
    }

    agent.on("error", fail);
    agent.stdin.on("error", fail);
    agent.on("exit", (code, signal) => {
        if (!closed) fail(new Error(`${config.name} closed (${code ?? signal}).`));
    });
    server.on("error", fail);
    for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) process.once(signal, close);

    try {
        const initialized = await request("initialize", {
            protocolVersion: 1,
            clientCapabilities: {},
            clientInfo: { name: config.clientName, version: env.TERM_PROGRAM_VERSION || "unknown" },
        });
        if (initialized?.protocolVersion !== 1) throw new Error("Macterm requires ACP version 1.");
        promptCapabilities = initialized?.agentCapabilities?.promptCapabilities ?? {};
        canResume = detectCanResume(initialized?.agentCapabilities);
        const params = { cwd, mcpServers: [] };
        let sessionResult;
        if (config.conversation) {
            sessionID = config.conversation;
            sessionResult = await request("session/load", { ...params, sessionId: sessionID });
        } else {
            sessionResult = await request("session/new", params);
            sessionID = sessionResult?.sessionId;
        }
        if (!sessionID) throw new Error(`${config.name} did not provide a conversation ID.`);
        applySessionConfig(sessionResult?.configOptions, sessionResult?.models, sessionResult?.modes);
        clearTimeout(startup);
        message = undefined;
        writeOut(`\n${config.name} conversation: ${clean(sessionID)}\n`);
        terminal.prompt();
        server.listen(path, register);
    } catch (error) {
        fail(error);
    }
}

export async function runCli(argv, presetName) {
    let parsed;
    try {
        parsed = parseBridgeArgs(argv, presetName);
    } catch (error) {
        console.error(error.message);
        process.exit(1);
    }
    if (parsed.help) {
        console.log(parsed.help);
        process.exit(0);
    }
    await runAcpBridge(parsed);
}
