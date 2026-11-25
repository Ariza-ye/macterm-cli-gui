<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm (CLI + Agent GUI)
</h1>

<p align="center">
  一款功能丰富、原生、轻量的 macOS 终端。
  <br />
  基于 <a href="https://github.com/macterm/macterm">Macterm</a> 分支开发，为编程智能体新增原生 Agent GUI。
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases/latest">
    <img src="https://img.shields.io/github/v/release/Ariza-ye/macterm-cli-gui?include_prereleases&label=version&color=blue" alt="最新版本" />
  </a>
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/actions/workflows/release-dmg.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Ariza-ye/macterm-cli-gui/release-dmg.yml?branch=gui&label=release-dmg" alt="Release DMG 工作流" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+" />
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <b>简体中文</b> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases"><b>发布版本</b></a> ·
  <a href="scripts/integrations/README.md"><b>Agent GUI 指南</b></a> ·
  <a href="https://github.com/macterm/macterm"><b>上游 Macterm</b></a> ·
  <a href="https://macterm.thdxg.dev/docs"><b>上游文档</b></a>
</p>

![Macterm 垂直项目边栏与编辑器窗格、shell 窗格](./assets/hero.png)

> [!NOTE]
> 本仓库是 [macterm/macterm](https://github.com/macterm/macterm) 的分支，在原终端之上新增了原生 Agent GUI。本项目与早期同名的 macOS 终端模拟器 [MacTerm](https://github.com/kmgrant/macterm) 无任何关联。

## 原生 Agent GUI

在主窗口的本地窗格中运行编程智能体时，可以直接在原生 SwiftUI 界面中对话，同时保持底层终端会话挂载和运行。你可以随时切回终端视图，无需结束智能体进程。

### 支持的智能体

- **Antigravity (`agy`) 与 OpenCode (`opencode`)**：内置 `macterm-acp` 桥接，并为本地 `zsh`、`bash` 和 `fish` 窗格默认开启命令自动拦截。直接运行 `agy` 或 `opencode`（或携带 `--conversation ID`），即可自动打开原生 Agent GUI。
- **任意 ACP v1 智能体**：在 **设置 → 智能体** 中添加自定义命令拦截规则，或直接运行 `macterm-acp --name "My Agent" -- <command>`。
- **Pi**：将内置的 `macterm-pi-bridge.ts` 扩展安装到 `~/.pi/agent/extensions/` 后运行 `pi`。只要已安装该扩展，Macterm 每次启动时都会自动将其与内置版本保持同步。

### 核心能力

- **流式对话视图**：支持 Markdown 渲染、限高可折叠的工具调用分组、更早历史记录分页加载，以及发送后消息即时上屏。
- **多行输入与附件上传**：按 <kbd>Return</kbd> 发送消息，按 <kbd>Shift</kbd>+<kbd>Return</kbd> 换行，完整兼容中文等输入法组合态。支持通过选择器、剪贴板粘贴或拖拽上传图片和 UTF-8 文本文件（每条消息最多 10 个），并提供内联预览。
- **模式、模型与速度切换**：当智能体支持时，可直接在输入框下方切换运行模式（点击或按 <kbd>Shift</kbd>+<kbd>Tab</kbd> 循环切换）、当前模型以及思考等级。
- **GUI 内 ACP 权限审批**：直接在 Agent GUI 卡片中查看工具调用参数，并批准或拒绝 ACP 权限请求。
- **内置 Git Diff 面板**：点击窗格标题栏的 **Git Diff**，即可浏览变更文件与 unified diff、勾选部分文件提交、自动生成提交信息（优先使用 Apple 端侧模型，不可用时回退至当前智能体 CLI 桥接或本地摘要），并支持推送与拉取。
- **窗格生命周期控制**：支持点击 **新对话** 开启新会话、**停止** 中断当前回合、在 **显示终端** 与 **显示 Agent 界面** 之间自由切换，以及点击 **关闭智能体** 退出智能体 CLI。
- **设置 → 智能体**：提供 **启用 Agent GUI** 总开关、**新对话** 与 **显示终端** 快捷键绑定、字体 / 代码字体 / 文字大小 / 行距 / 内容宽度（**紧凑**、**标准**、**宽**、**铺满宽度**）自定义与实时预览，以及内置和自定义命令拦截规则管理。

如需单次跳过命令拦截，可运行 `MACTERM_NO_AGENT_GUI=1 agy` 或 `command agy`。详细配置与 Pi 安装步骤见 [`scripts/integrations/README.md`](scripts/integrations/README.md)。

## 终端特性

完整保留上游 Macterm 的全部核心特性：

- **会话持久运行**：退出 Macterm 后，shell 会话仍在后台保持运行；重新启动后所有窗格自动恢复。
- **垂直项目边栏**：在原生 macOS 边栏中管理项目、项目分组及其标签页。
- **拆分与多路复用**：自由拆分窗格、将一个窗格拖拽到另一个窗格，或将窗格移出为独立标签页。
- **远程项目**：通过 SSH 打开远程主机上的文件夹，其 shell 会话在远端保持运行。
- **固定的标签页**：将常用标签页固定在所有项目上方，随 Macterm 启动自动打开。
- **命令面板**：按 <kbd>⌘P</kbd> 访问所有命令，并在行内查看对应快捷键。
- **扩展**：为 Git、Docker、Kubernetes、SSH 和 Claude Code 添加操作面板，或使用 YAML 编写自定义扩展。
- **存储与恢复布局**：在单个 YAML 文件中定义项目的标签页、拆分结构与启动命令。
- **控制 CLI**：脚本和编程智能体可通过 `macterm` 命令控制 Macterm。
- **标签页切换器**：按住最近标签页快捷键，通过实时预览选择标签页。
- **拷贝模式**：使用 Vim 或 Helix 键位在回滚缓冲区中移动并选择文本。
- **平滑动画**：滚动、拆分窗格与光标移动均支持丝滑动画。
- **快速终端**：通过全局快捷键在任意 App 上方呼出下拉终端。
- **桌面小组件**：在桌面上放置符合 macOS 小组件网格与形态的终端。
- **密码自动填充**：自动记住在密码提示符下输入的密码，并在下次出现时自动填充。
- **自适应背景**：窗口自动匹配当前运行程序的背景色。
- **Ghostty 兼容**：无缝继承你现有的 Ghostty 配置、主题、字体与快捷键。

## 安装

### 从 Releases 下载（推荐）

前往 [发布版本](https://github.com/Ariza-ye/macterm-cli-gui/releases) 下载对应架构的 `.dmg` 安装包：

- **Apple Silicon**：`Macterm-<version>-arm64.dmg`
- **Intel**：`Macterm-<version>-x86_64.dmg`

打开 `.dmg` 并将 `Macterm.app` 拖入 `/Applications`。由于构建产物未包含 Apple Developer 证书签名，首次运行前请执行一次命令以移除隔离属性：

```bash
xattr -cr /Applications/Macterm.app
```

每个发布版本均附带 `SHA256SUMS.txt` 用于校验文件完整性。

> [!NOTE]
> 使用 ACP 智能体（`agy`、`opencode` 及自定义 ACP v1 规则）时，`PATH` 中需安装 **Node.js 22 或更高版本**。

### 从源码构建

使用 `mise` 安装构建工具与预构建依赖，随后运行调试版或构建发布包：

```bash
mise install
mise run setup
mise run run        # 构建并启动调试版 App
mise run build      # 构建发布版 App 与 DMG
```

完整开发环境搭建与开发规范请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

> [!TIP]
> 上游 Homebrew cask（`brew install --cask macterm/tap/macterm`）安装的是上游 Macterm，不包含本分支新增的 Agent GUI 功能。

## 配置

Macterm 与 Ghostty 读取相同的配置文件位置：`~/.config/ghostty/config` 或 `~/Library/Application Support/com.mitchellh.ghostty/config`。现有配置无需修改即可直接生效。所有可用配置项详见 [Ghostty 配置参考](https://ghostty.org/docs/config/reference)。最小配置示例如下：

```ini
theme = Rose Pine
font-family = JetBrains Mono
font-size = 16
```

Macterm 对少量默认值做了调整，包括主题、字号、内边距以及 `macos-option-as-alt`，并将 `tab-inherit-working-directory = false` 作为默认值，以便新建标签页始终在项目根目录打开。Macterm 会在加载你的配置之前应用这些默认值，你手动设置的键始终优先。完整默认值列表见 [`MactermConfig.swift`](Macterm/Config/MactermConfig.swift) 中的 `defaultsBody`。

Agent GUI、窗口透明度、边栏行为、快速终端尺寸与键位映射等设置可通过 **Macterm → 设置** 调整。配置优先级与 Macterm 覆盖的少量窗口配置项详见 [配置文档](https://macterm.thdxg.dev/docs/configuration)。

## 扩展

扩展可以简化 Git、Docker、Kubernetes、SSH、编程智能体等工作流，为命令面板添加自定义屏幕（[示例](extensions/git/README.md)）。

**安装扩展**：打开 **设置 → 扩展**，找到目标扩展并点击 **安装**，其面板会立即出现在命令面板（<kbd>⌘P</kbd>）的 **面板** 分组中。

**创建自定义扩展**：在 `~/.config/macterm/extensions/` 下新建文件夹，并包含 `extension.yaml` 与存放 YAML 文件的 `palettes/` 目录。详情参阅 [扩展文档](https://macterm.thdxg.dev/docs/extensions)。

**贡献扩展**：提交 PR，将你的扩展文件夹添加至 [`extensions/`](extensions/)。

## 实践案例（Cookbook）

Macterm 社区分享了许多实用工作流、布局、快捷键与自动化脚本，例如：

- [使用同一套 <kbd>⌃hjkl</kbd> 快捷键在 Neovim 分屏与 Macterm 窗格间无缝移动](https://github.com/macterm/macterm/discussions/217)
- [通过脚本驱动交互式程序](https://github.com/macterm/macterm/discussions/218)
- [让编程智能体控制 Macterm](https://github.com/macterm/macterm/discussions/219)
- [使用相同方向快捷键在 Neovim 分屏与 Macterm 窗格间切换焦点的 Neovim 插件](https://github.com/macterm/macterm/discussions/459)

## 参与贡献

环境搭建、构建方式与 PR 规范请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT
