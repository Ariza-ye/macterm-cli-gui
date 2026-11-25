# Agents in Macterm

## Pi

Use the Pi extension to show an interactive Pi conversation in a local pane in a main window. You can send multiline messages with attachments, read replies as they arrive, switch models and thinking levels, and stop the current turn.

## Install the Pi extension

1. Install Pi 1.5.2 or later.
2. Run these commands from the Macterm source folder:

   ```sh
   mkdir -p ~/.pi/agent/extensions
   cp scripts/integrations/macterm-pi-bridge.ts ~/.pi/agent/extensions/
   ```

3. Run `pi` in a local pane in a Macterm main window. If Pi is already open, run `/reload` in its terminal.

Once installed at `~/.pi/agent/extensions/macterm-pi-bridge.ts`, Macterm automatically syncs the file with the bundled version on startup.

For a test without installation, run `pi -e /path/to/macterm-pi-bridge.ts` in the pane.

## Use the Agent GUI

- Press <kbd>Return</kbd> to send a message, or click **Send**.
- Press <kbd>Shift</kbd>+<kbd>Return</kbd> to add a new line.
- Attach images or UTF-8 text files (up to 10 per message) with the **+** button, clipboard paste, or drag and drop.
- Use the mode, model, and speed controls below the input box to switch modes (or press <kbd>Shift</kbd>+<kbd>Tab</kbd>), models, or thinking levels when the agent supports them.
- Approve or reject ACP permission requests directly in the permission card when they appear.
- Click **Git Diff** to review changed files, select files to commit, generate a commit message, and push or pull.
- Click **History** (or enter `/resume` in the input box) to browse and resume previous conversations when the agent supports session history.
- Click **New Conversation** to start a new conversation in the same pane.
- Click **Stop** to stop the current turn. The agent process stays open.
- Click **Show Terminal** for password prompts, slash commands, and other terminal controls. Click **Show Agent GUI** in the pane's top-right corner to show the same conversation again.
- Click **Close Agent** (`×`) to close the Agent GUI and exit the agent CLI.

Configure the **Enable Agent GUI** toggle, **New Conversation** and **Show Terminal** keybinds, typography and content width, and command interception rules in **Settings → Agents**.

Pi stores the conversation. Macterm reads the current branch from Pi and receives updates over a local socket. If the connection closes, the pane shows the terminal. If you quit and start Macterm again, the extension registers again when it finds the app's agent registration socket.

## ACP agents (OpenCode, Antigravity, and others)

Macterm bundles `macterm-acp` and enables automatic command interception by default for local `zsh`, `bash`, and `fish` panes (requires Node.js 22 or later). When you run bare `agy` or `opencode` (or with `--conversation ID`) in a local pane in a main window, Macterm opens the native Agent GUI automatically. Other arguments and non-interactive runs pass through to the original command.

Manage the toggle and custom ACP interception rules in **Settings → Agents**. To bypass interception for one command, run `MACTERM_NO_AGENT_GUI=1 agy` or `command agy`.

You can also run the bridge scripts directly from this repository:

### OpenCode

1. Install `opencode` with ACP support (`opencode acp`) and sign in with `opencode auth login` if required.
2. Run `scripts/integrations/macterm-opencode` (or `scripts/integrations/macterm-acp opencode`) from a local pane in a Macterm main window.

### Antigravity

1. Install `agy` with ACP support and run `agy acp --login` if Antigravity requires sign-in.
2. Run `scripts/integrations/macterm-agy` (or `scripts/integrations/macterm-acp agy`) from a local pane in a Macterm main window.

### Other ACP v1 agents

Run any ACP v1 command after `--`:

```sh
scripts/integrations/macterm-acp --name "My Agent" -- my-agent acp
```

The bridge shows the conversation, replies, tool updates, and permission requests in Macterm. Click **Stop** to cancel the current turn. Click **Show Terminal** to continue the conversation from the terminal. Enter `/exit` to close the conversation.

To resume a conversation, pass `--conversation ID` to `macterm-opencode`, `macterm-agy`, or `macterm-acp`. The bridge prints the ID when it opens the conversation.
