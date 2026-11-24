#!/bin/sh
# Copies Macterm's ACP agent bridge scripts and shell-integration loaders into
# the built app bundle, and hooks the copied Ghostty shell-integration files so
# interactive shells load Macterm's command interception rules automatically.
set -eu

RESOURCES_DIR="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources"
INTEGRATIONS_DIR="$RESOURCES_DIR/integrations"
SHELL_DIR="$RESOURCES_DIR/shell-integration"
GHOSTTY_SHELL_DIR="$RESOURCES_DIR/ghostty/shell-integration"

mkdir -p "$INTEGRATIONS_DIR" "$SHELL_DIR"

cp "$SRCROOT/scripts/integrations/acp-bridge.mjs" "$INTEGRATIONS_DIR/"
cp "$SRCROOT/scripts/integrations/macterm-acp" "$INTEGRATIONS_DIR/"
cp "$SRCROOT/scripts/integrations/macterm-agy" "$INTEGRATIONS_DIR/"
cp "$SRCROOT/scripts/integrations/macterm-opencode" "$INTEGRATIONS_DIR/"
cp "$SRCROOT/scripts/integrations/macterm-pi-bridge.ts" "$INTEGRATIONS_DIR/"
chmod +x "$INTEGRATIONS_DIR/macterm-acp" "$INTEGRATIONS_DIR/macterm-agy" "$INTEGRATIONS_DIR/macterm-opencode"

cp "$SRCROOT/scripts/shell-integration/macterm-intercept.zsh" "$SHELL_DIR/"
cp "$SRCROOT/scripts/shell-integration/macterm-intercept.bash" "$SHELL_DIR/"
cp "$SRCROOT/scripts/shell-integration/macterm-intercept.fish" "$SHELL_DIR/"

MARKER="# macterm-agent-intercept-hook"

ZSH_FILE="$GHOSTTY_SHELL_DIR/zsh/ghostty-integration"
if [ -f "$ZSH_FILE" ] && ! grep -q "$MARKER" "$ZSH_FILE"; then
    python3 - "$ZSH_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
anchor = "    builtin unfunction _ghostty_deferred_init"
hook = """    # macterm-agent-intercept-hook
    if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
        builtin local _macterm_loader="${GHOSTTY_RESOURCES_DIR%/ghostty}/shell-integration/macterm-intercept.zsh"
        [[ -r "$_macterm_loader" ]] && builtin source "$_macterm_loader"
    fi
"""
if anchor not in text:
    sys.exit("error: anchor not found in ghostty-integration")
open(path, "w", encoding="utf-8").write(text.replace(anchor, hook + anchor, 1))
PY
fi

BASH_FILE="$GHOSTTY_SHELL_DIR/bash/ghostty.bash"
if [ -f "$BASH_FILE" ] && ! grep -q "$MARKER" "$BASH_FILE"; then
    cat >> "$BASH_FILE" <<'EOF'

# macterm-agent-intercept-hook
if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
  _macterm_loader="${GHOSTTY_RESOURCES_DIR%/ghostty}/shell-integration/macterm-intercept.bash"
  [[ -r "$_macterm_loader" ]] && builtin source "$_macterm_loader"
  builtin unset _macterm_loader
fi
EOF
fi

FISH_FILE="$GHOSTTY_SHELL_DIR/fish/vendor_conf.d/ghostty-shell-integration.fish"
if [ -f "$FISH_FILE" ] && ! grep -q "$MARKER" "$FISH_FILE"; then
    python3 - "$FISH_FILE" <<'PY'
import sys
path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
anchor = "end\n\nghostty_exit"
hook = """
    # macterm-agent-intercept-hook
    if set -q GHOSTTY_RESOURCES_DIR; and test -n "$GHOSTTY_RESOURCES_DIR"
        set -l __macterm_loader (string replace -r '/ghostty$' '' -- "$GHOSTTY_RESOURCES_DIR")/shell-integration/macterm-intercept.fish
        if test -r "$__macterm_loader"
            source "$__macterm_loader"
        end
    end
"""
if anchor not in text:
    sys.exit("error: anchor not found in ghostty-shell-integration.fish")
open(path, "w", encoding="utf-8").write(text.replace(anchor, hook + anchor, 1))
PY
fi
