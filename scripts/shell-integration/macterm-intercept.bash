# Macterm agent command interception loader for bash.
# Sourced by Ghostty's bash integration after user rc files load.

_macterm_sync_intercept() {
    builtin local _macterm_sock="${MACTERM_AGENT_SOCKET:-${MACTERM_SOCKET:-}}"
    [[ -n "$_macterm_sock" ]] || builtin return 0
    builtin local _macterm_file="${_macterm_sock%/*}/agent-intercept.bash"
    [[ -r "$_macterm_file" ]] || builtin return 0
    builtin local _macterm_rev=""
    IFS= builtin read -r _macterm_rev < "$_macterm_file" 2>/dev/null || builtin return 0
    if [[ "$_macterm_rev" != "${_macterm_intercept_rev:-}" ]]; then
        builtin source "$_macterm_file"
        _macterm_intercept_rev="$_macterm_rev"
    fi
}

_macterm_sync_intercept

if builtin declare -p precmd_functions >/dev/null 2>&1; then
    if [[ " ${precmd_functions[*]:-} " != *" _macterm_sync_intercept "* ]]; then
        precmd_functions+=(_macterm_sync_intercept)
    fi
elif [[ "${PROMPT_COMMAND[*]:-}" != *"_macterm_sync_intercept"* ]]; then
    if [[ -z "${PROMPT_COMMAND[*]:-}" ]]; then
        PROMPT_COMMAND="_macterm_sync_intercept"
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
        PROMPT_COMMAND+=("_macterm_sync_intercept")
    else
        [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
        PROMPT_COMMAND+="_macterm_sync_intercept"
    fi
fi
