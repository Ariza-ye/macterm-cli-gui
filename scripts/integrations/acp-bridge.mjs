import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmdirSync, statSync, unlinkSync } from "node:fs";
import { createConnection, createServer } from "node:net";
import { basename } from "node:path";
import { createInterface } from "node:readline";
import { stripVTControlCharacters } from "node:util";

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

export function normalizeConfigOptions(rawConfigOptions, rawModels) {
    const booleanIds = new Set();
    const normalized = [];

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
        return { configOptions: normalized, usesLegacyModels: false, booleanIds };
    }

    if (rawModels && Array.isArray(rawModels.availableModels) && rawModels.availableModels.length > 0) {
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
            return { configOptions: normalized, usesLegacyModels: true, booleanIds };
        }
    }

    return { configOptions: [], usesLegacyModels: false, booleanIds };
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
    const { MACTERM_SESSION: pane, MACTERM_SOCKET: control } = env;

    if (!pane || !control || (requireTTY && !inputStream.isTTY)) {
        errorStream.write(`Run this bridge in a local pane in a Macterm main window.\n`);
        process.exitCode = 1;
        return;
    }

    const directory = mkdtempSync("/tmp/macterm-agent-");
    const path = `${directory}/bridge.sock`;
    const agent = spawn(config.command, config.args, {
        cwd,
        env,
        stdio: ["pipe", "pipe", "inherit"],
    });
    const terminal = createInterface({ input: inputStream, output: outputStream, prompt: config.prompt });
    const inflight = new Map();
    const rows = new Map();
    const sockets = new Set();
    const permissions = new Map();
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
    let booleanConfigIds = new Set();
    let configPending = false;

    const writeOut = text => outputStream.write(text);
    const writeErr = text => errorStream.write(text);

    function applySessionConfig(rawConfigOptions, rawModels) {
        const next = normalizeConfigOptions(rawConfigOptions, rawModels);
        configOptions = next.configOptions;
        usesLegacyModels = next.usesLegacyModels;
        booleanConfigIds = next.booleanIds;
    }

    function updateConfigOptions(rawConfigOptions) {
        const next = normalizeConfigOptions(rawConfigOptions, undefined);
        configOptions = next.configOptions;
        usesLegacyModels = false;
        booleanConfigIds = next.booleanIds;
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

    function state() {
        return { busy: Boolean(turn), waiting: permissions.size > 0 };
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

    function confirmPrompt() {
        if (!turn || turn.accepted) return;
        turn.accepted = true;
        upsert({ id: randomUUID(), kind: "user", text: clean(turn.text) });
        if (turn.owner && turn.owner === peer) emit({ type: "reply", id: turn.id, accepted: true, ...state() });
    }

    function update({ update }) {
        if (!update) return;
        const { sessionUpdate: type, content } = update;
        if (type === "user_message_chunk" && turn) {
            confirmPrompt();
            return;
        }
        if (["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].includes(type)) {
            confirmPrompt();
        }
        if (type === "agent_message_chunk" || type === "user_message_chunk") {
            const kind = type === "agent_message_chunk" ? "assistant" : "user";
            if (content?.type !== "text") return;
            if (message?.kind !== kind) message = { id: randomUUID(), kind, text: "" };
            const text = clean(content.text);
            if (kind === "assistant") writeOut(text);
            message = { ...message, text: (message.text + text).slice(0, 64 * 1024) };
            upsert(message);
        } else if (type === "tool_call" || type === "tool_call_update") {
            message = undefined;
            const id = `tool:${update.toolCallId}`;
            const previous = rows.get(id);
            const name = clean(update.title) || previous?.name || update.kind || "Tool";
            const toolStatus = update.status === "failed" ? "failed"
                : update.status === "completed" ? "completed"
                : update.status ? "running" : previous?.status ?? "running";
            const text = formatToolText(update, previous);
            if (!previous) writeOut(`\n${name}\n`);
            upsert({ id, kind: "tool", text, name, status: toolStatus });
        } else if ((type === "config_option_update" || type === "config_options_update")
            && Array.isArray(update.configOptions)) {
            updateConfigOptions(update.configOptions);
        } else if (type === "current_model_update" && usesLegacyModels && typeof update.modelId === "string") {
            configOptions = configOptions.map(option =>
                option.id === "model" ? { ...option, currentValue: update.modelId } : option,
            );
            emit({ type: "config", configOptions });
        }
    }

    function showPermission() {
        const req = permissions.values().next().value;
        if (!req) return;
        const { params } = req;
        const title = clean(params.toolCall?.title) || "Tool";
        writeOut(`\nPermission required for ${title}.\n`);
        if (params.toolCall?.rawInput !== undefined) {
            writeOut(`${clean(JSON.stringify(params.toolCall.rawInput, null, 2))}\n`);
        }
        for (const [index, option] of params.options.entries()) {
            writeOut(`${index + 1}. ${clean(option.name)}\n`);
        }
        writeOut("0. Cancel\n");
        terminal.setPrompt("Select an option> ");
        terminal.prompt();
    }

    function cancelPermissions() {
        for (const id of permissions.keys()) rpc({ id, result: { outcome: { outcome: "cancelled" } } });
        permissions.clear();
        terminal.setPrompt(config.prompt);
        status();
    }

    const agentOutput = createInterface({ input: agent.stdout, crlfDelay: Infinity });
    agentOutput.on("line", line => {
        let frame;
        try { frame = JSON.parse(line); } catch { return; }
        const { id, method, params, result, error } = frame;
        if (method === "session/update" && (!sessionID || params?.sessionId === sessionID)) {
            update(params);
        } else if (method === "session/request_permission" && params?.sessionId === sessionID) {
            confirmPrompt();
            permissions.set(id, frame);
            if (permissions.size === 1) showPermission();
            status();
        } else if (method && id !== undefined) {
            rpc({ id, error: { code: -32601, message: "This client does not support the request." } });
        } else if (!method && inflight.has(id)) {
            const { resolve, reject } = inflight.get(id);
            inflight.delete(id);
            if (error) reject(new Error(error.message));
            else resolve(result);
        }
    });

    async function prompt(text, owner, id) {
        if (!sessionID || turn || permissions.size || typeof text !== "string" || !text.trim()
            || Buffer.byteLength(text) > 128 * 1024) {
            if (owner === peer && owner) emit({ type: "reply", id, accepted: false, ...state() });
            return;
        }
        turn = { id, owner, text, accepted: false };
        message = undefined;
        status();
        try {
            await request("session/prompt", { sessionId: sessionID, prompt: [{ type: "text", text }] });
            confirmPrompt();
        } catch (error) {
            upsert({ id: randomUUID(), kind: "assistant", text: clean(error.message) });
            if (!turn.accepted && owner && peer === owner) emit({ type: "reply", id, accepted: false, ...state() });
            writeErr(`\n${clean(error.message)}\n`);
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
        if (!sessionID || turn || permissions.size || configPending || typeof configId !== "string"
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
            } else {
                const wireValue = booleanConfigIds.has(configId) ? value === "true" : value;
                const result = await request("session/set_config_option", {
                    sessionId: sessionID,
                    configId,
                    value: wireValue,
                });
                if (Array.isArray(result?.configOptions)) {
                    const next = normalizeConfigOptions(result.configOptions, undefined);
                    configOptions = next.configOptions;
                    booleanConfigIds = next.booleanIds;
                } else {
                    configOptions = configOptions.map(item =>
                        item.id === configId ? { ...item, currentValue: value } : item,
                    );
                }
            }
            reply(true);
        } catch (error) {
            writeErr(`\n${clean(error.message)}\n`);
            reply(false);
        } finally {
            configPending = false;
        }
    }

    terminal.on("line", line => {
        if (permissions.size) {
            const req = permissions.values().next().value;
            const value = line.trim();
            const option = /^\d+$/.test(value) ? req.params.options[Number(value) - 1] : undefined;
            if (value !== "0" && !option) return showPermission();
            const outcome = option ? { outcome: "selected", optionId: option.optionId } : { outcome: "cancelled" };
            rpc({ id: req.id, result: { outcome } });
            permissions.delete(req.id);
            terminal.setPrompt(config.prompt);
            status();
            showPermission();
        } else if (line === "/exit") {
            close();
        } else if (line.trim()) {
            if (turn) writeOut("Wait for the current turn to end.\n");
            else void prompt(line);
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
                emit({ type: "snapshotEnd", ...state(), configOptions });
            } else if (command?.type === "send" && typeof command.id === "string") {
                void prompt(command.text, socket, command.id);
            } else if (command?.type === "setConfig" && typeof command.id === "string") {
                void setConfig(command.configId, command.value, socket, command.id);
            } else if (command?.type === "stop") {
                stop();
            }
        });
    });

    function register() {
        if (!sessionID || peer || registration || closed) return;
        let identity;
        try {
            const info = statSync(control);
            if (!info.isSocket()) return;
            identity = `${info.dev}:${info.ino}:${info.birthtimeMs}`;
        } catch { return; }
        if (identity === boundSocket) return;
        const token = randomUUID();
        challenge = { token, identity };
        const socket = createConnection(control);
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

    function close() {
        if (closed) return;
        closed = true;
        clearTimeout(startup);
        clearInterval(retry);
        registration?.destroy();
        for (const socket of sockets) socket.destroy();
        server.close();
        terminal.close();
        agentOutput.close();
        agent.stdin.destroy();
        agent.kill();
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
        applySessionConfig(sessionResult?.configOptions, sessionResult?.models);
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
