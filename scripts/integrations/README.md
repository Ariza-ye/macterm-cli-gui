# Agents in Macterm

## Pi

Use the Pi extension to show an interactive Pi conversation in a local pane in a main window. You can send a multiline message, read replies as they arrive, and stop the current turn.

## Install the Pi extension

1. Install Pi 1.5.2 or later.
2. Run these commands from the Macterm source folder.

   ```sh
   mkdir -p ~/.pi/agent/extensions
   cp scripts/integrations/macterm-pi-bridge.ts ~/.pi/agent/extensions/
   ```

3. Run `pi` in a local pane in a Macterm main window. If Pi is already open, run `/reload` in its terminal.

For a test without installation, run `pi -e /path/to/macterm-pi-bridge.ts` in the pane.

## Use the agent GUI

- Press <kbd>Return</kbd> to send a message. You can also click **Send**.
- Press <kbd>Shift</kbd>+<kbd>Return</kbd> to add a new line.
- Use the model and speed controls below the input box to switch the active model or thinking level when the agent supports them.
- Click **Stop** to stop the current turn. The agent process stays open.
- Click **Show Terminal** for approval requests, passwords, slash commands, and other terminal controls.
- Click **Show Agent GUI** in the pane's top-right corner to show the same conversation again.

Pi stores the conversation. Macterm reads the current branch from Pi and receives updates through a local socket. If the connection closes, the pane shows the terminal. If you quit and open Macterm again, the extension registers again when it finds the app's control socket.

## ACP agents (OpenCode, Antigravity, and others)

Macterm bundles `macterm-acp` and enables automatic command interception by default for local zsh, bash, and fish panes. When you run bare `agy` or `opencode` (or with `--conversation ID`) in a local pane in a main window, Macterm opens the native Agent GUI automatically. Other arguments and non-interactive runs pass through to the original command.

Manage the toggle and custom ACP interception rules in **Settings → Agents**. To bypass interception for one command, run `MACTERM_NO_AGENT_GUI=1 agy` or `command agy`.

You can also run the bridge scripts directly from this repository (requires Node.js 22 or later):

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

The bridge shows the conversation, replies, and tool updates in Macterm. Click **Stop** to cancel the current turn. Click **Show Terminal** to answer permission requests or continue the conversation from the terminal. Enter `/exit` to close the conversation.

To resume a conversation, pass `--conversation ID` to `macterm-opencode`, `macterm-agy`, or `macterm-acp`. The bridge prints the ID when it opens the conversation.
