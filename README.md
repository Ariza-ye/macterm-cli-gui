<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm (CLI + Agent GUI)
</h1>

<p align="center">
  A feature-rich macOS terminal built to be pleasant, native, and lightweight.
  <br />
  A fork of <a href="https://github.com/macterm/macterm">Macterm</a> with a native Agent GUI for coding agents.
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases/latest">
    <img src="https://img.shields.io/github/v/release/Ariza-ye/macterm-cli-gui?include_prereleases&label=version&color=blue" alt="Latest version" />
  </a>
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/actions/workflows/release-dmg.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Ariza-ye/macterm-cli-gui/release-dmg.yml?branch=gui&label=release-dmg" alt="Release DMG workflow" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+" />
</p>

<p align="center">
  <b>English</b> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases"><b>Releases</b></a> ·
  <a href="scripts/integrations/README.md"><b>Agent GUI Guide</b></a> ·
  <a href="https://github.com/macterm/macterm"><b>Upstream Macterm</b></a> ·
  <a href="https://macterm.thdxg.dev/docs"><b>Upstream Docs</b></a>
</p>

![Macterm's vertical project sidebar beside an editor pane and a shell pane](./assets/hero.png)

> [!NOTE]
> This repository is a fork of [macterm/macterm](https://github.com/macterm/macterm) that adds a native Agent GUI on top of the terminal. It has no relation to [MacTerm](https://github.com/kmgrant/macterm), an earlier macOS terminal emulator with the same name.

## Native Agent GUI

Run your coding agents in a local pane inside a main window and work in a native SwiftUI interface while the underlying terminal session stays mounted and active. Switch back to the terminal view at any time without ending the agent process.

### Supported agents

- **Antigravity (`agy`) and OpenCode (`opencode`)**: bundled with the `macterm-acp` bridge and automatic shell command interception for local `zsh`, `bash`, and `fish` panes. Run bare `agy` or `opencode` (or with `--conversation ID`) to open the Agent GUI automatically.
- **Any ACP v1 agent**: add custom command interception rules in **Settings → Agents**, or run `macterm-acp --name "My Agent" -- <command>` directly.
- **Pi**: install the bundled `macterm-pi-bridge.ts` extension into `~/.pi/agent/extensions/` and run `pi`. Macterm automatically keeps an already-installed Pi bridge extension in sync with the bundled version.

### Capabilities

- **Streaming conversation view**: Markdown rendering, collapsible tool-call groups with bounded height, paginated loading for older history, and instant display of sent messages.
- **Multiline input and attachments**: press <kbd>Return</kbd> to send and <kbd>Shift</kbd>+<kbd>Return</kbd> for a new line, with full IME composition support. Attach images and UTF-8 text files (up to 10 files per message) from the picker, the clipboard, or drag and drop, with inline preview.
- **Mode, model, and speed controls**: switch agent mode (click or press <kbd>Shift</kbd>+<kbd>Tab</kbd>), active model, and thinking level directly below the input box when the agent supports them.
- **In-GUI ACP permission approvals**: review tool arguments and approve or reject ACP permission requests directly in the Agent GUI.
- **Built-in Git Diff sheet**: click **Git Diff** in the pane header to inspect changed files and unified diffs, select specific files to commit, generate commit messages (using Apple's on-device model, the active agent CLI bridge, or a local summary fallback), and push or pull.
- **Pane lifecycle controls**: start a **New Conversation**, **Stop** the current turn, toggle between **Show Terminal** and **Show Agent GUI**, or click **Close Agent** to exit the agent CLI.
- **Settings → Agents**: toggle **Enable Agent GUI**, bind **New Conversation** and **Show Terminal** keybinds, customize body font, code font, text size, line spacing, and content width (`Compact`, `Standard`, `Wide`, or `Full width`), and manage built-in or custom command interception rules.

To bypass command interception for one run, run `MACTERM_NO_AGENT_GUI=1 agy` or `command agy`. See [`scripts/integrations/README.md`](scripts/integrations/README.md) for setup details and Pi installation steps.

## Terminal Features

All core features from upstream Macterm stay available:

- **Session persistence**: your shells keep running when you quit, and every pane returns when you start Macterm again.
- **Vertical project sidebar**: projects, project groups, and their tabs in a native macOS sidebar.
- **Splits and multiplexing**: split panes, drag a pane onto another, and move a pane to its own tab.
- **Remote projects**: open a folder on another machine over SSH. Its shells keep running on that machine.
- **Pinned tabs**: keep a tab above your projects. It starts with Macterm.
- **Command palette**: press <kbd>⌘P</kbd> for every command, with its keybind on the row.
- **Extensions**: add palettes for Git, Docker, Kubernetes, SSH, and Claude Code, or write your own in YAML.
- **Save and restore layouts**: the tabs, splits, and commands of a project in one YAML file.
- **Control CLI**: scripts and coding agents control Macterm with the `macterm` command.
- **Tab switcher**: hold the recent-tab keybind to select a tab from live previews.
- **Copy mode**: move through the scrollback and select text with the keys of Vim or Helix.
- **Animations**: scrolling, splits, and the cursor glide into place.
- **Quick terminal**: a drop-down terminal over any app, with a global keybind.
- **Desktop widgets**: a terminal on your desktop, in the grid and shape of the macOS widgets.
- **Password autofill**: Macterm saves the passwords that you type at a password prompt and fills them in again.
- **Adaptive background**: the window takes the background color of the running program.
- **Ghostty compatibility**: your Ghostty config, theme, font, and keybinds carry over.

## Install

### From Releases (Recommended)

Download the `.dmg` for your Mac architecture from [Releases](https://github.com/Ariza-ye/macterm-cli-gui/releases):

- **Apple Silicon**: `Macterm-<version>-arm64.dmg`
- **Intel**: `Macterm-<version>-x86_64.dmg`

Open the `.dmg` and drag `Macterm.app` to `/Applications`. The release build has no Apple Developer certificate signature, so clear the quarantine attribute one time:

```bash
xattr -cr /Applications/Macterm.app
```

Each release includes `SHA256SUMS.txt` for checksum verification.

> [!NOTE]
> ACP agents (`agy`, `opencode`, and custom ACP v1 rules) require **Node.js 22 or later** in your `PATH`.

### Build from Source

Install the build tools and prebuilt dependencies with `mise`, then build or start the debug app:

```bash
mise install
mise run setup
mise run run        # Build and start debug app
mise run build      # Build release app and DMG
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) for full setup and development instructions.

> [!TIP]
> The upstream Homebrew cask (`brew install --cask macterm/tap/macterm`) installs upstream Macterm without the Agent GUI additions in this fork.

## Configuration

Macterm reads your Ghostty config from the same places as Ghostty: `~/.config/ghostty/config` or `~/Library/Application Support/com.mitchellh.ghostty/config`. An existing setup carries over with no change. The [Ghostty option reference](https://ghostty.org/docs/config/reference) documents every key. A minimal config looks like this:

```ini
theme = Rose Pine
font-family = JetBrains Mono
font-size = 16
```

A few Macterm defaults are different from the Ghostty defaults: theme, font size, padding, and `macos-option-as-alt`. Macterm also sets `tab-inherit-working-directory = false`, so new tabs open at the project root. Macterm loads these defaults before your config. A key that you set always wins. `defaultsBody` in [`MactermConfig.swift`](Macterm/Config/MactermConfig.swift) has the full list.

Macterm has its own settings for Agent GUI, window opacity, sidebar behavior, quick terminal size, and keymaps. Open them with **Macterm → Settings**. The [configuration docs](https://macterm.thdxg.dev/docs/configuration) give the full order of precedence and the few window keys that Macterm overrides.

## Extensions

An extension streamlines your workflows for Git, Docker, Kubernetes, SSH, coding agents, and more. It adds screens to the command palette ([example](extensions/git/README.md)).

**To install:** open **Settings → Extensions**, find the extension, and click **Install**. Its palettes appear at once in the **Palettes** section of the command palette (<kbd>⌘P</kbd>).

**To create your own:** make a folder in `~/.config/macterm/extensions/` with an `extension.yaml` file and a `palettes/` folder of YAML files. See the [extension docs](https://macterm.thdxg.dev/docs/extensions) for more detail.

**To contribute:** open a PR to add your extension folder to [`extensions/`](extensions/).

## Cookbook

The Macterm community shares workflows and recipes: layouts, keybinds, and scripts that people run with Macterm. For example:
- [Use one set of <kbd>⌃hjkl</kbd> keybinds to move between Neovim splits and Macterm panes](https://github.com/macterm/macterm/discussions/217)
- [Drive an interactive program from a script](https://github.com/macterm/macterm/discussions/218)
- [Give a coding agent control of Macterm](https://github.com/macterm/macterm/discussions/219)
- [A Neovim plugin that moves focus between Neovim splits and Macterm panes with the same directional keybinds](https://github.com/macterm/macterm/discussions/459)

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and pull request rules.

## License

MIT
