# Macterm agent command interception loader for fish.
# Sourced during Ghostty's first fish_prompt setup after config.fish loads.

function __macterm_sync_intercept --on-event fish_prompt
    if not set -q MACTERM_SOCKET; or test -z "$MACTERM_SOCKET"
        return
    end
    set -l __macterm_dir (string replace -r '/[^/]+$' '' -- "$MACTERM_SOCKET")
    set -l __macterm_file "$__macterm_dir/agent-intercept.fish"
    if not test -r "$__macterm_file"
        return
    end
    set -l __macterm_rev ""
    read -l __macterm_rev < "$__macterm_file"; or return
    if test "$__macterm_rev" != "$__macterm_intercept_rev"
        source "$__macterm_file"
        set -g __macterm_intercept_rev "$__macterm_rev"
    end
end

__macterm_sync_intercept
