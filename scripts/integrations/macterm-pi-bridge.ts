import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmdirSync, statSync, unlinkSync } from "node:fs";
import { createConnection, createServer, type Socket } from "node:net";
import { stripVTControlCharacters } from "node:util";

type Entry = ReturnType<ExtensionContext["sessionManager"]["getBranch"]>[number];
type Message = Extract<Entry, { type: "message" }>["message"];
type Row = {
    id: string;
    kind: "user" | "assistant" | "tool";
    text: string;
    name?: string;
    status?: "running" | "completed" | "failed";
};

function textContent(content: unknown): string {
    const text = typeof content === "string" ? content : Array.isArray(content)
        ? content.filter((block) => block?.type === "text" && typeof block.text === "string")
              .map((block) => block.text).join("\n")
        : "";
    const limit = 48 * 1024;
    return stripVTControlCharacters(text.length <= limit ? text : `${text.slice(0, limit)}\n…`);
}

function messageRow(id: string, message: Message): Row | undefined {
    switch (message.role) {
        case "user":
            return { id, kind: "user", text: textContent(message.content) };
        case "assistant": {
            const text = textContent(message.content) || textContent(message.errorMessage);
            return text ? { id, kind: "assistant", text } : undefined;
        }
        case "toolResult":
            return {
                id, kind: "tool", name: message.toolName,
                text: textContent(message.content), status: message.isError ? "failed" : "completed",
            };
    }
}

export default function (pi: ExtensionAPI) {
    let runtime: ReturnType<typeof startBridge>;
    pi.on("session_start", (_event, ctx) => {
        runtime?.close();
        const session = process.env.MACTERM_SESSION;
        const control = process.env.MACTERM_SOCKET;
        runtime = ctx.mode === "tui" && process.platform === "darwin" && session && control
            ? startBridge(pi, ctx, session, control) : undefined;
    });
    pi.on("session_shutdown", () => { runtime?.close(); runtime = undefined; });
    pi.on("session_tree", () => { runtime?.snapshot(); });
    pi.on("before_agent_start", () => { runtime?.status(); });
    pi.on("agent_start", () => { runtime?.acceptSend(); runtime?.status(); });
    pi.on("agent_settled", () => { runtime?.status(); });
    pi.on("ui_prompt_start", () => { runtime?.setWaiting(true); });
    pi.on("ui_prompt_end", () => { runtime?.setWaiting(false); });
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

function startBridge(pi: ExtensionAPI, ctx: ExtensionContext, session: string, control: string) {
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
    let waiting = false;
    let closed = false;
    let messageID = 0;
    const connected = new Set<Socket>();
    const activeMessages = new Map<string, string>();
    const toolArguments = new Map<string, string>();

    const state = () => ({ busy: !ctx.isIdle(), waiting });
    function emit(frame: object) {
        if (!peer) return;
        if (peer.writableLength > 32 * 1024 * 1024) { peer.destroy(); return; }
        peer.write(JSON.stringify(frame) + "\n");
    }
    const status = () => emit({ type: "status", ...state() });
    function sendReply(accepted: boolean) {
        if (!pending) return;
        const { id, timer, owner } = pending;
        clearTimeout(timer);
        pending = undefined;
        if (owner === peer) emit({ type: "reply", id, accepted, ...state() });
    }
    function snapshot() {
        if (!peer) return;
        emit({ type: "snapshot", conversation });
        for (const entry of ctx.sessionManager.getBranch()) {
            if (entry.type !== "message") continue;
            const row = messageRow(`entry:${entry.id}`, entry.message);
            if (row) emit({ type: "row", row });
        }
        emit({ type: "snapshotEnd", ...state() });
    }

    const server = createServer((socket) => {
        if (closed || connected.size >= 4) { socket.destroy(); return; }
        connected.add(socket);
        socket.unref().setTimeout(5000).setEncoding("utf8");
        socket.on("timeout", () => socket.destroy());
        socket.on("error", () => socket.destroy());
        socket.on("close", () => {
            connected.delete(socket);
            if (peer === socket) peer = undefined;
            if (pending?.owner === socket) sendReply(false);
        });
        let buffer = "";
        socket.on("data", (chunk: string) => {
            buffer += chunk;
            if (buffer.length > 1024 * 1024) { socket.destroy(); return; }
            let newline: number;
            while ((newline = buffer.indexOf("\n")) >= 0 && !socket.destroyed) {
                const line = buffer.slice(0, newline);
                buffer = buffer.slice(newline + 1);
                let command: { type?: string; id?: string; token?: string; text?: string };
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
                } else if (command.type === "send" && typeof command.id === "string") {
                    if (pending || waiting || !ctx.isIdle() || typeof command.text !== "string"
                        || !command.text.trim() || Buffer.byteLength(command.text) > 128 * 1024) {
                        emit({ type: "reply", id: command.id, accepted: false, ...state() });
                        continue;
                    }
                    pending = { id: command.id, owner: socket, timer: setTimeout(() => sendReply(false), 25000).unref() };
                    // Wait for Pi to start the run before clearing the draft in Macterm.
                    pi.sendUserMessage(command.text);
                }
            }
        });
    });

    function register() {
        if (closed || peer || registration) return;
        try {
            const info = statSync(control);
            if (!info.isSocket()) return;
            const identity = `${info.dev}:${info.ino}:${info.birthtimeMs}`;
            if (identity === registeredSocket) return;
            registeringSocket = identity;
        } catch { return; }
        token = randomUUID();
        const socket = createConnection(control);
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
        clearInterval(timer);
        registration?.destroy();
        for (const socket of connected) socket.destroy();
        server.close();
        try { unlinkSync(path); } catch {}
        try { rmdirSync(directory); } catch {}
    }
    server.on("error", close);
    server.listen(path, register).unref();

    return {
        close, snapshot, status,
        acceptSend: () => sendReply(true),
        setWaiting(value: boolean) { waiting = value; status(); },
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
