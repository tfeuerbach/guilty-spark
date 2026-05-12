# Guilty Spark — Shell command logger
# Installed to /etc/profile.d/ to capture every interactive command.
# Supports bash (PROMPT_COMMAND) and zsh (precmd).
# Logs to syslog facility local6, picked up by rsyslog → Promtail → Loki.
#
# Do NOT edit in /etc/profile.d/ — managed by Guilty Spark setup.

_gs_log_cmd() {
    logger -p local6.info -t "guilty-spark-shell[$$]" "user=$(whoami) tty=$(tty 2>/dev/null || echo none) cmd=$1"
}

if [ -n "$BASH_VERSION" ]; then
    _gs_last_hist=""
    _gs_prompt_hook() {
        local _cmd
        _cmd=$(history 1 | sed 's/^[ ]*[0-9]\+[ ]*//')
        [ -z "$_cmd" ] && return
        [ "$_cmd" = "$_gs_last_hist" ] && return
        _gs_last_hist="$_cmd"
        _gs_log_cmd "$_cmd"
    }
    if [[ "$PROMPT_COMMAND" != *"_gs_prompt_hook"* ]]; then
        PROMPT_COMMAND="_gs_prompt_hook;${PROMPT_COMMAND:+$PROMPT_COMMAND}"
    fi
elif [ -n "$ZSH_VERSION" ]; then
    _gs_last_hist=""
    _gs_precmd_hook() {
        local _cmd
        _cmd=$(fc -ln -1 2>/dev/null | sed 's/^[ ]*//')
        [ -z "$_cmd" ] && return
        [ "$_cmd" = "$_gs_last_hist" ] && return
        _gs_last_hist="$_cmd"
        _gs_log_cmd "$_cmd"
    }
    autoload -Uz add-zsh-hook 2>/dev/null
    if typeset -f add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook precmd _gs_precmd_hook
    else
        precmd_functions+=(_gs_precmd_hook)
    fi
fi
