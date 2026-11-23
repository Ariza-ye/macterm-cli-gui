# Macterm agent command interception loader for zsh.
# Sourced during deferred shell integration setup after user rc files load.

_macterm_sync_intercept() {
    builtin emulate -L zsh -o no_aliases
    [[ -n "${MACTERM_SOCKET:-}" ]] || builtin return 0
    builtin local _macterm_file="${MACTERM_SOCKET%/*}/agent-intercept.zsh"
    [[ -r "$_macterm_file" ]] || builtin return 0
    builtin local _macterm_rev=""
    IFS= builtin read -r _macterm_rev < "$_macterm_file" 2>/dev/null || builtin return 0
    if [[ "$_macterm_rev" != "${_macterm_intercept_rev:-}" ]]; then
        builtin source "$_macterm_file"
        builtin typeset -g _macterm_intercept_rev="$_macterm_rev"
    fi
}

_macterm_sync_intercept
builtin typeset -ag precmd_functions
if (( ${precmd_functions[(Ie)_macterm_sync_intercept]:-0} == 0 )); then
    precmd_functions+=(_macterm_sync_intercept)
fi
