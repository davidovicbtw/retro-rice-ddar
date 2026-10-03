# shellcheck shell=bash
# DDAR runtime: start/reload components without spawning duplicates.

# PIDs of processes named $1 whose command line contains $2.
_pids_with_arg() {
    local name="$1" needle="$2" pid
    for pid in $(pgrep -x "$name" 2>/dev/null); do
        tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$needle" && echo "$pid"
    done
}

_foreign_pids() { # processes named $1 that do NOT contain $2
    local name="$1" needle="$2" pid
    for pid in $(pgrep -x "$name" 2>/dev/null); do
        tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$needle" || echo "$pid"
    done
}

ddar_waybar() {
    local conf="$DDAR_GEN_DIR/waybar/config.jsonc" style="$DDAR_GEN_DIR/waybar/style.css" pids foreign
    have waybar || { warn "waybar is not installed - skipping the bar"; return 0; }
    pids="$(_pids_with_arg waybar "$conf")"
    foreign="$(_foreign_pids waybar "$conf")"
    if [[ -n "$foreign" ]]; then
        if [[ "${DDAR_REPLACE:-0}" == 1 ]]; then
            info "Stopping the other Waybar instance(s): $(echo "$foreign" | tr '\n' ' ')"
            # shellcheck disable=SC2086
            kill $foreign 2>/dev/null
        else
            warn "Another Waybar (not started by DDAR) is running. Use 'ddar run --replace' to replace it,"
            warn "or remove its exec-once line from your Hyprland config."
        fi
    fi
    mkdir -p "$DDAR_GEN_DIR/logs"
    if [[ -n "$pids" ]]; then
        # SIGUSR2 = reload config and style in place.
        # shellcheck disable=SC2086
        kill -USR2 $pids && ok "Waybar reloaded"
    else
        setsid -f waybar -c "$conf" -s "$style" </dev/null >"$DDAR_GEN_DIR/logs/waybar.log" 2>&1 9>&-
        ok "Waybar started (log: $DDAR_GEN_DIR/logs/waybar.log)"
    fi
}

_notification_daemon_running() {
    if have busctl; then
        busctl --user --no-pager status org.freedesktop.Notifications >/dev/null 2>&1
    elif have dbus-send; then
        dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus.NameHasOwner string:org.freedesktop.Notifications 2>/dev/null | grep -q 'boolean true'
    else
        return 1
    fi
}

ddar_notifications() {
    local mode conf="$DDAR_GEN_DIR/mako/config"
    mode="$(cfg NOTIFICATIONS)"
    [[ "$mode" == off ]] && return 0
    if ! have mako; then
        [[ "$mode" == mako ]] && warn "NOTIFICATIONS=mako but mako is not installed"
        return 0
    fi
    if [[ -n "$(_pids_with_arg mako "$conf")" ]]; then
        makoctl reload >/dev/null 2>&1 && ok "mako reloaded"
    elif _notification_daemon_running; then
        [[ "$mode" == mako ]] && warn "Another notification daemon is running; not starting mako"
        return 0
    else
        spawn mako -c "$conf" && ok "mako started"
    fi
}

ddar_kitty_reload() {
    local kconf="$XDG_CONFIG_HOME/kitty/kitty.conf"
    [[ -r "$kconf" ]] && grep -qF "$DDAR_GEN_DIR/kitty/colors.conf" "$kconf" || return 0
    pgrep -x kitty >/dev/null && pkill -USR1 -x kitty && ok "kitty colours reloaded"
    return 0
}

# Reload everything that shows colours (used after theme/wallpaper changes).
ddar_apply_theme_change() {
    generate_all
    in_wayland || { msg "Generated configs updated (no Wayland session: nothing to reload)."; return 0; }
    ddar_waybar
    ddar_notifications
    ddar_kitty_reload
    in_hyprland && hyprctl reload >/dev/null && ok "Hyprland config reloaded"
    return 0
}

# ddar run [--boot] [--replace]
ddar_run() {
    local boot=0 arg lock
    for arg in "$@"; do
        case "$arg" in
            --boot) boot=1 ;;
            --replace) DDAR_REPLACE=1 ;;
            -h|--help) msg "Usage: ddar run [--replace] [--boot]"; return 0 ;;
            *) die "Unknown option for run: $arg" ;;
        esac
    done
    lock="${XDG_RUNTIME_DIR:-/tmp}/ddar-run-$(id -u).lock"
    exec 9>"$lock"
    flock -n 9 || { warn "ddar run is already in progress"; return 0; }

    ensure_user_config
    info "Generating configuration"
    generate_all
    ok "Configs generated in $DDAR_GEN_DIR"

    if ! in_wayland; then
        warn "No Wayland session detected - configs were generated but nothing was started."
        return 0
    fi
    ddar_waybar
    ddar_notifications
    wallpaper_apply
    ddar_kitty_reload
    if ((boot == 0)) && in_hyprland; then
        hyprctl reload >/dev/null && ok "Hyprland config reloaded"
    fi
    return 0
}
