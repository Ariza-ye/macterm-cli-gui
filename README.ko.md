<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm (CLI + Agent GUI)
</h1>

<p align="center">
  쾌적하고 네이티브하며 가벼운, 풍부한 기능의 macOS 터미널입니다.
  <br />
  <a href="https://github.com/macterm/macterm">Macterm</a>을 기반으로 코딩 에이전트용 네이티브 Agent GUI를 추가한 포크입니다.
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases/latest">
    <img src="https://img.shields.io/github/v/release/Ariza-ye/macterm-cli-gui?include_prereleases&label=version&color=blue" alt="최신 버전" />
  </a>
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/actions/workflows/release-dmg.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/Ariza-ye/macterm-cli-gui/release-dmg.yml?branch=gui&label=release-dmg" alt="Release DMG 워크플로우" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+" />
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <b>한국어</b>
</p>

<p align="center">
  <a href="https://github.com/Ariza-ye/macterm-cli-gui/releases"><b>릴리스</b></a> ·
  <a href="scripts/integrations/README.md"><b>Agent GUI 가이드</b></a> ·
  <a href="https://github.com/macterm/macterm"><b>업스트림 Macterm</b></a> ·
  <a href="https://macterm.thdxg.dev/docs"><b>업스트림 문서</b></a>
</p>

![편집기 페인과 셸 페인 옆에 표시된 Macterm의 세로 프로젝트 사이드바](./assets/hero.png)

> [!NOTE]
> 이 저장소는 터미널 위에 네이티브 Agent GUI를 추가한 [macterm/macterm](https://github.com/macterm/macterm)의 포크입니다. 같은 이름을 가진 이전 macOS 터미널 에뮬레이터인 [MacTerm](https://github.com/kmgrant/macterm)과는 무관합니다.

## 네이티브 Agent GUI

메인 윈도우의 로컬 페인에서 코딩 에이전트를 실행하면, 아래 터미널 세션을 그대로 유지한 채 네이티브 SwiftUI 인터페이스에서 대화할 수 있습니다. 에이전트 프로세스를 종료하지 않고 언제든 터미널 보기로 전환할 수 있습니다.

### 지원하는 에이전트

- **Antigravity (`agy`) 및 OpenCode (`opencode`)**: `macterm-acp` 브리지가 내장되어 있으며 로컬 `zsh`, `bash`, `fish` 페인에서 자동 명령 가로채기가 기본으로 활성화됩니다. 인자 없이 `agy` 또는 `opencode`(또는 `--conversation ID` 포함)를 실행하면 네이티브 Agent GUI가 자동으로 열립니다.
- **모든 ACP v1 에이전트**: **설정 → 에이전트**에서 사용자 지정 명령 가로채기 규칙을 추가하거나 `macterm-acp --name "My Agent" -- <command>`를 직접 실행할 수 있습니다.
- **Pi**: 내장된 `macterm-pi-bridge.ts` 확장 프로그램을 `~/.pi/agent/extensions/`에 설치한 뒤 `pi`를 실행합니다. 이미 설치되어 있는 경우, Macterm을 시작할 때 내장 버전과 자동으로 동기화됩니다.

### 주요 기능

- **스트리밍 대화 화면**: Markdown 렌더링, 최대 높이가 제한된 접이식 도구 호출 그룹, 이전 대화 기록 페이지네이션 로드, 전송 시 메시지 즉시 표시를 지원합니다.
- **여러 줄 입력 및 첨부 파일**: <kbd>Return</kbd>으로 전송하고 <kbd>Shift</kbd>+<kbd>Return</kbd>으로 줄을 바꾸며, 한글·중국어 등 IME 조합 입력을 완벽히 지원합니다. 파일 선택기, 클립보드 붙여넣기, 드래그 앤 드롭으로 이미지 및 UTF-8 텍스트 파일(메시지당 최대 10개)을 첨부하고 인라인으로 미리 볼 수 있습니다.
- **모드·모델·속도 전환**: 에이전트가 지원하는 경우 입력 상자 아래에서 실행 모드(클릭 또는 <kbd>Shift</kbd>+<kbd>Tab</kbd> 순환), 활성 모델, 사고 수준을 바로 전환할 수 있습니다.
- **GUI 내 ACP 권한 승인**: Agent GUI 내 권한 카드에서 도구 인자를 확인하고 ACP 권한 요청을 직접 승인하거나 거부할 수 있습니다.
- **내장 Git Diff 시트**: 페인 상단의 **Git Diff**를 클릭해 변경된 파일과 unified diff를 검토하고, 원하는 파일만 선택해 커밋하며, 커밋 메시지를 자동 생성(Apple 온디바이스 모델 우선, 불가 시 현재 에이전트 CLI 브리지 또는 로컬 요약으로 대체)하고 Push/Pull을 수행할 수 있습니다.
- **페인 수명 주기 제어**: **새로운 대화** 시작, 현재 턴 **중지**, **터미널 보기**와 **에이전트 GUI 보기** 간 전환, **에이전트 닫기**로 에이전트 CLI 종료를 지원합니다.
- **설정 → 에이전트**: **Agent GUI 사용** 전환, **새로운 대화** 및 **터미널 보기** 단축키 설정, 서체·코드 서체·텍스트 크기·줄 간격·콘텐츠 너비(**좁게**, **표준**, **넓게**, **전체 너비**) 사용자 지정 및 실시간 미리 보기, 기본 및 사용자 지정 명령 가로채기 규칙 관리를 제공합니다.

한 번만 명령 가로채기를 건너뛰려면 `MACTERM_NO_AGENT_GUI=1 agy` 또는 `command agy`를 실행합니다. 자세한 설정과 Pi 설치 방법은 [`scripts/integrations/README.md`](scripts/integrations/README.md)를 참고하십시오.

## 터미널 기능

업스트림 Macterm의 모든 핵심 기능을 그대로 제공합니다.

- **세션 유지**: Macterm을 종료해도 셸이 백그라운드에서 계속 실행되며, 다시 시작하면 모든 페인이 복원됩니다.
- **세로 프로젝트 사이드바**: 네이티브 macOS 사이드바에서 프로젝트, 프로젝트 그룹 및 탭을 관리합니다.
- **분할 및 멀티플렉싱**: 페인을 분할하고, 다른 페인 위로 드래그하거나 별도의 탭으로 이동합니다.
- **원격 프로젝트**: SSH를 통해 원격 머신의 폴더를 열며, 해당 머신에서 셸이 계속 실행됩니다.
- **고정된 탭**: 프로젝트 위에 탭을 고정해 Macterm 시작 시 함께 엽니다.
- **명령 팔레트**: <kbd>⌘P</kbd>를 눌러 모든 명령과 각 항목의 단축키를 확인하고 실행합니다.
- **확장 프로그램**: Git, Docker, Kubernetes, SSH, Claude Code용 팔레트를 추가하거나 YAML로 직접 작성합니다.
- **레이아웃 저장 및 복원**: 프로젝트의 탭, 분할, 실행 명령을 하나의 YAML 파일로 관리합니다.
- **제어 CLI**: 스크립트와 코딩 에이전트가 `macterm` 명령으로 Macterm을 제어합니다.
- **탭 전환기**: 최근 탭 단축키를 길게 눌러 실시간 미리 보기에서 탭을 선택합니다.
- **복사 모드**: Vim 또는 Helix 키로 스크롤백을 탐색하고 텍스트를 선택합니다.
- **애니메이션**: 스크롤, 분할, 커서 이동이 부드럽게 움직입니다.
- **빠른 터미널**: 전역 단축키로 어떤 앱 위에서든 드롭다운 터미널을 엽니다.
- **데스크탑 위젯**: macOS 위젯의 그리드와 형태에 맞춘 터미널을 데스크탑에 배치합니다.
- **암호 자동 완성**: 암호 프롬프트에 입력한 암호를 저장하고 다음 프롬프트에서 자동으로 입력합니다.
- **적응형 배경**: 실행 중인 프로그램의 배경색에 맞춰 윈도우 배경색이 조정됩니다.
- **Ghostty 호환성**: 기존 Ghostty 설정, 테마, 서체 및 단축키가 그대로 이어집니다.

## 설치

### 릴리스에서 다운로드 (권장)

[릴리스](https://github.com/Ariza-ye/macterm-cli-gui/releases) 페이지에서 Mac 아키텍처에 맞는 `.dmg` 파일을 다운로드합니다.

- **Apple Silicon**: `Macterm-<version>-arm64.dmg`
- **Intel**: `Macterm-<version>-x86_64.dmg`

`.dmg`를 열고 `Macterm.app`을 `/Applications`로 드래그합니다. 릴리스 빌드는 Apple Developer 인증서로 서명되지 않았으므로, 처음 한 번 격리 속성을 제거해야 합니다.

```bash
xattr -cr /Applications/Macterm.app
```

각 릴리스에는 무결성 검증용 `SHA256SUMS.txt`가 포함되어 있습니다.

> [!NOTE]
> ACP 에이전트(`agy`, `opencode` 및 사용자 지정 ACP v1 규칙)를 사용하려면 `PATH`에 **Node.js 22 이상**이 설치되어 있어야 합니다.

### 소스에서 빌드

`mise`로 빌드 도구와 사전 빌드된 종속성을 설치한 뒤 디버그 앱을 실행하거나 릴리스 DMG를 빌드합니다.

```bash
mise install
mise run setup
mise run run        # 디버그 앱 빌드 및 시작
mise run build      # 릴리스 앱 및 DMG 빌드
```

자세한 설정 및 개발 가이드는 [CONTRIBUTING.md](CONTRIBUTING.md)를 참고하십시오.

> [!TIP]
> 업스트림 Homebrew cask(`brew install --cask macterm/tap/macterm`)는 이 포크의 Agent GUI가 포함되지 않은 업스트림 Macterm을 설치합니다.

## 설정

Macterm은 Ghostty와 동일한 위치의 설정 파일을 읽습니다: `~/.config/ghostty/config` 또는 `~/Library/Application Support/com.mitchellh.ghostty/config`. 기존 설정을 수정 없이 그대로 사용할 수 있습니다. 모든 설정 키는 [Ghostty 설정 참조](https://ghostty.org/docs/config/reference)에 문서화되어 있습니다. 최소 설정 예시는 다음과 같습니다.

```ini
theme = Rose Pine
font-family = JetBrains Mono
font-size = 16
```

테마, 서체 크기, 패딩, `macos-option-as-alt` 등 일부 기본값은 Ghostty 기본값과 다릅니다. 또한 새 탭이 항상 프로젝트 루트에서 열리도록 `tab-inherit-working-directory = false`를 기본 설정합니다. Macterm은 사용자 설정을 불러오기 전에 이 기본값을 적용하므로 사용자가 지정한 값이 항상 우선합니다. 전체 기본값 목록은 [`MactermConfig.swift`](Macterm/Config/MactermConfig.swift)의 `defaultsBody`에서 확인할 수 있습니다.

Agent GUI, 윈도우 투명도, 사이드바 동작, 빠른 터미널 크기, 키맵 등은 **Macterm → 설정**에서 구성합니다. 전체 우선순위와 Macterm이 재정의하는 일부 윈도우 키는 [설정 문서](https://macterm.thdxg.dev/docs/configuration)를 참고하십시오.

## 확장 프로그램

확장 프로그램은 Git, Docker, Kubernetes, SSH, 코딩 에이전트 등의 워크플로우를 간소화하며 명령 팔레트에 화면을 추가합니다 ([예시](extensions/git/README.md)).

**설치 방법:** **설정 → 확장 프로그램**을 열고 원하는 확장 프로그램을 찾아 **설치**를 클릭합니다. 해당 팔레트는 명령 팔레트(<kbd>⌘P</kbd>)의 **팔레트** 섹션에 즉시 표시됩니다.

**직접 만들기:** `~/.config/macterm/extensions/` 아래에 폴더를 만들고 `extension.yaml` 파일과 YAML 파일이 들어 있는 `palettes/` 폴더를 추가합니다. 자세한 내용은 [확장 프로그램 문서](https://macterm.thdxg.dev/docs/extensions)를 참고하십시오.

**기여하기:** PR을 열어 확장 프로그램 폴더를 [`extensions/`](extensions/)에 추가하십시오.

## 쿡북

Macterm 커뮤니티에서는 레이아웃, 단축키, 자동화 스크립트 등 다양한 워크플로우와 레시피를 공유합니다. 예시:

- [동일한 <kbd>⌃hjkl</kbd> 단축키 세트로 Neovim 분할과 Macterm 페인 간 이동하기](https://github.com/macterm/macterm/discussions/217)
- [스크립트에서 대화형 프로그램 제어하기](https://github.com/macterm/macterm/discussions/218)
- [코딩 에이전트에 Macterm 제어 권한 부여하기](https://github.com/macterm/macterm/discussions/219)
- [동일한 방향 단축키로 Neovim 분할과 Macterm 페인 간 포커스를 이동하는 Neovim 플러그인](https://github.com/macterm/macterm/discussions/459)

## 기여

설정, 빌드 및 풀 리퀘스트 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)를 참고하십시오.

## 라이선스

MIT
