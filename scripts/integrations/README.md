# Pi in Macterm

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
- Click **Stop** to stop the current turn. The Pi process stays open.
- Click **Show Terminal** for approval requests, passwords, slash commands, and other Pi controls.
- Click **Show Agent GUI** in the pane's top-right corner to show the same conversation again.

Pi stores the conversation. Macterm reads the current branch from Pi and receives updates through a local socket. If the connection closes, the pane shows the terminal. If you quit and open Macterm again, the extension registers again when it finds the app's control socket.
