# shellcheck shell=bash
# DDAR terminal interface. Pure bash + ANSI, works on a bare TTY.

TUI_W=46   # inner width of the boxes

_tui_line() { # left text, padded to the box width
    local text="$1" plain="$2"
    local pad=$(( TUI_W - ${#plain} ))
    ((pad < 0)) && pad=0
    printf '%s│%s %s%*s%s│%s\n' "$C_DIM" "$C_RESET" "$text" "$((pad - 1))" "" "$C_DIM" "$C_RESET"
}

_tui_rule() { local l="$1" r="$2" s; printf -v s '%*s' "$TUI_W" ""; printf '%s%s%s%s%s\n' "$C_DIM" "$l" "${s// /─}" "$r" "$C_RESET"; }

# Title bar: inverse-video strip, like an old setup program.
_tui_title() {
    local t=" $1" pad
    pad=$(( TUI_W - ${#t} ))
    _tui_rule "┌" "┐"
    printf '%s│%s%s%s%*s%s%s│%s\n' "$C_DIM" "$C_RESET" "$C_INV$C_BOLD" "$t" "$pad" "" "$C_RESET" "$C_DIM" "$C_RESET"
    _tui_rule "├" "┤"
}

# tui_screen TITLE STATUS "key|label" ...
tui_screen() {
    local title="$1" status="$2" item key label; shift 2
    [[ -t 1 ]] && printf '\e[H\e[2J'
    _tui_title "$title"
    for item in "$@"; do
        if [[ "$item" == "-" ]]; then _tui_rule "├" "┤"; continue; fi
        if [[ "$item" == "#"* ]]; then _tui_line "${C_DIM}${item#\#}${C_RESET}" "${item#\#}"; continue; fi
        key="${item%%|*}"; label="${item#*|}"
        _tui_line "${C_BOLD}${key}${C_RESET}. $label" "$key. $label"
    done
    _tui_rule "├" "┤"
    _tui_line "${C_DIM}${status}${C_RESET}" "$status"
    _tui_rule "└" "┘"
}

tui_key() { local k; IFS= read -rsn1 k || k=q; printf '%s' "${k,,}"; }
tui_pause() { printf '\n%sPress any key...%s' "$C_DIM" "$C_RESET"; read -rsn1 _ || true; }
tui_prompt() { local p="$1" def="$2" v; read -r -e -p "$p" -i "$def" v || v="$def"; printf '%s' "$v"; }

_status() { printf 'theme %s | %s | DDAR %s' "$(cfg THEME)" "$(in_wayland && echo session || echo no-session)" "$DDAR_VERSION"; }

# Apply pending changes after leaving a settings screen.
_tui_apply() {
    printf '\n'
    ddar_apply_theme_change
    tui_pause
}

# Edit any schema key with type-aware input.
tui_edit_setting() {
    local key="$1" type cur val reason opt i
    type="$(_schema_field "$key" 1)"; cur="$(cfg "$key")"
    printf '\n%s%s%s - %s\n' "$C_BOLD" "$key" "$C_RESET" "$(_schema_field "$key" 2)"
    if [[ "$type" == enum:* ]]; then
        IFS=',' read -r -a _opts <<<"${type#enum:}"
        for i in "${!_opts[@]}"; do
            opt="${_opts[i]}"; printf '  %d) %s%s\n' "$((i + 1))" "$opt" "$([[ "$opt" == "$cur" ]] && echo '  <- current')"
        done
        read -r -p "Choice (Enter = keep): " val || return 1
        [[ "$val" =~ ^[0-9]+$ ]] && ((val >= 1 && val <= ${#_opts[@]})) || return 1
        val="${_opts[val-1]}"
    else
        [[ "$type" == modules ]] && printf '%sModules: %s%s\n' "$C_DIM" "${DDAR_MODULES[*]}" "$C_RESET"
        val="$(tui_prompt "New value: " "$cur")"
    fi
    [[ "$val" == "$cur" ]] && return 1
    if ! reason="$(config_validate "$key" "$val")"; then err "$reason"; tui_pause; return 1; fi
    config_set "$key" "$val"
    ok "$key = $val"
    return 0
}

tui_theme() {
    local -a names; local i k changed=0 items cur
    while true; do
        mapfile -t names < <(theme_names)
        cur="$(cfg THEME)"; items=()
        for i in "${!names[@]}"; do
            items+=("$((i + 1))|$(printf '%-12s %s' "${names[i]}" "$([[ "${names[i]}" == "$cur" ]] && echo '[active]')")")
        done
        items+=("-" "m|Matugen mode: $(cfg MATUGEN)" "a|Accent colour: $(cfg ACCENT)" "b|Back")
        tui_screen "Change Theme" "$(_status)" "${items[@]}"
        k="$(tui_key)"
        case "$k" in
            [1-9]) ((k <= ${#names[@]})) && { config_set THEME "${names[k-1]}"; changed=1; } ;;
            m) tui_edit_setting MATUGEN && changed=1 ;;
            a) tui_edit_setting ACCENT && changed=1 ;;
            b|q|$'\e') break ;;
        esac
    done
    ((changed)) && _tui_apply
}

tui_widgets() {
    local k changed=0 i m items
    while true; do
        items=()
        for i in "${!DDAR_MODULES[@]}"; do
            m="${DDAR_MODULES[i]}"
            items+=("$(printf '%x' "$((i + 1))")|[$([[ " $(cfg WIDGETS) " == *" $m "* ]] && echo x || echo ' ')] $m")
        done
        items+=("-" "#Toggle with the key shown. Hardware-less" "#widgets (battery, backlight) hide anyway." "q|Back (applies changes)")
        tui_screen "Configure Widgets" "$(_status)" "${items[@]}"
        k="$(tui_key)"
        [[ "$k" == q || "$k" == $'\e' ]] && break
        [[ "$k" =~ ^[0-9a-f]$ ]] || continue
        i=$(( 16#$k - 1 )); ((i >= 0 && i < ${#DDAR_MODULES[@]})) || continue
        m="${DDAR_MODULES[i]}"
        local new=""
        if [[ " $(cfg WIDGETS) " == *" $m "* ]]; then
            # shellcheck disable=SC2046  # word splitting of the module list is intended
            new="$(printf '%s\n' $(cfg WIDGETS) | grep -vxF "$m" | tr '\n' ' ')"
        else
            new="$(cfg WIDGETS) $m"
        fi
        new="$(echo "$new" | xargs)"
        config_set WIDGETS "$new"; changed=1
        # Make sure an enabled widget is actually placed on the bar.
        if [[ " $new " == *" $m "* && " $(cfg BAR_LEFT) $(cfg BAR_CENTER) $(cfg BAR_RIGHT) " != *" $m "* ]]; then
            config_set BAR_RIGHT "$m $(cfg BAR_RIGHT)"
        fi
    done
    ((changed)) && _tui_apply
}

tui_bar() {
    local k changed=0
    while true; do
        tui_screen "Configure Bar" "$(_status)" \
            "1|Left:   $(cfg BAR_LEFT)" "2|Centre: $(cfg BAR_CENTER)" "3|Right:  $(cfg BAR_RIGHT)" "-" \
            "4|Height: $(cfg BAR_HEIGHT)px" "5|Workspace style: $(cfg WORKSPACE_STYLE)" \
            "6|Clock format: $(cfg CLOCK_FORMAT)" "7|Transparency: $(cfg TRANSPARENCY)%" \
            "8|Font: $(cfg FONT) $(cfg FONT_SIZE)pt" "-" "q|Back (applies changes)"
        k="$(tui_key)"
        case "$k" in
            1) tui_edit_setting BAR_LEFT && changed=1 ;;
            2) tui_edit_setting BAR_CENTER && changed=1 ;;
            3) tui_edit_setting BAR_RIGHT && changed=1 ;;
            4) tui_edit_setting BAR_HEIGHT && changed=1 ;;
            5) tui_edit_setting WORKSPACE_STYLE && changed=1 ;;
            6) tui_edit_setting CLOCK_FORMAT && changed=1 ;;
            7) tui_edit_setting TRANSPARENCY && changed=1 ;;
            8) tui_edit_setting FONT && changed=1; tui_edit_setting FONT_SIZE && changed=1 ;;
            q|$'\e') break ;;
        esac
    done
    ((changed)) && _tui_apply
}

tui_launcher() {
    local k changed=0
    while true; do
        tui_screen "Configure Launcher" "$(_status)" \
            "1|Layout: $(cfg LAUNCHER_STYLE)  (list / grid / compact)" "2|Icons: $(cfg LAUNCHER_ICONS)" \
            "3|Preview launcher" "-" "q|Back (applies changes)"
        k="$(tui_key)"
        case "$k" in
            1) tui_edit_setting LAUNCHER_STYLE && changed=1 ;;
            2) tui_edit_setting LAUNCHER_ICONS && changed=1 ;;
            3) if in_wayland; then ((changed)) && { generate_all; changed=0; }; ddar_launcher
               else warn "No Wayland session - cannot preview"; tui_pause; fi ;;
            q|$'\e') break ;;
        esac
    done
    ((changed)) && _tui_apply
}

tui_wallpaper() {
    local k p
    while true; do
        config_load
        tui_screen "Wallpapers" "$(_status)" \
            "#Current: $(basename "$(wallpaper_current)")" "#Folder:  $(cfg WALLPAPER_DIR)" "-" \
            "1|Next" "2|Previous" "3|Random" "4|Pick from list" "5|Set from path" "6|Change folder" \
            "7|Backend: $(cfg WALLPAPER_BACKEND) (using: $(wallpaper_backend))" "-" "q|Back"
        k="$(tui_key)"; printf '\n'
        case "$k" in
            1) ( wallpaper_step 1 ); tui_pause ;;
            2) ( wallpaper_step -1 ); tui_pause ;;
            3) ( wallpaper_random ); tui_pause ;;
            4) ( wallpaper_pick ); tui_pause ;;
            5) p="$(tui_prompt "Image path: " "")"; [[ -n "$p" ]] && ( wallpaper_set "$p" ); tui_pause ;;
            6) tui_edit_setting WALLPAPER_DIR; tui_pause ;;
            7) tui_edit_setting WALLPAPER_BACKEND && wallpaper_apply; tui_pause ;;
            q|$'\e') break ;;
        esac
    done
}

tui_shortcuts() {
    local k combo cmd n
    while true; do
        [[ -t 1 ]] && printf '\e[H\e[2J'
        _tui_title "Keyboard Shortcuts"
        printf '\n'
        shortcuts_list
        printf '\n %sa%s Add   %sr%s Remove   %se%s Edit file   %sc%s Check   %sq%s Back\n' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        k="$(tui_key)"; printf '\n'
        case "$k" in
            a)
                msg "Key combination, e.g. SUPER+SHIFT+B   (modifiers: SUPER ALT CTRL SHIFT)"
                combo="$(tui_prompt "Shortcut: " "")"
                [[ -n "$combo" ]] || continue
                msg "Command to run, e.g. firefox   (or @dispatcher args, e.g. @workspace 3)"
                cmd="$(tui_prompt "Command:  " "")"
                [[ -n "$cmd" ]] && ( shortcuts_add "$combo" "$cmd" )
                tui_pause ;;
            r) n="$(tui_prompt "Number or shortcut to remove: " "")"; [[ -n "$n" ]] && ( shortcuts_remove "$n" ); tui_pause ;;
            e) shortcuts_edit; tui_pause ;;
            c) shortcuts_check; tui_pause ;;
            q|$'\e') break ;;
        esac
    done
}

tui_settings() {
    local k changed=0
    while true; do
        tui_screen "Settings" "$(_status)" \
            "1|Accent colour: $(cfg ACCENT)" "2|Matugen: $(cfg MATUGEN)" \
            "3|Animations: $(cfg ANIMATIONS)" "4|Hyprland look: $(cfg HYPR_STYLE)" \
            "5|Transparency: $(cfg TRANSPARENCY)%" "6|UI font: $(cfg FONT)" \
            "7|Font size: $(cfg FONT_SIZE)" "8|Mono font: $(cfg MONO_FONT)" \
            "9|Terminal: $(cfg TERMINAL)" "a|Notifications: $(cfg NOTIFICATIONS)" \
            "b|Autostart: $(cfg AUTOSTART)" "c|Weather location: $(cfg WEATHER_LOCATION)" \
            "-" "e|Open ddar.conf in \$EDITOR" "q|Back (applies changes)"
        k="$(tui_key)"
        case "$k" in
            1) tui_edit_setting ACCENT && changed=1 ;;
            2) tui_edit_setting MATUGEN && changed=1 ;;
            3) tui_edit_setting ANIMATIONS && changed=1 ;;
            4) tui_edit_setting HYPR_STYLE && changed=1 ;;
            5) tui_edit_setting TRANSPARENCY && changed=1 ;;
            6) tui_edit_setting FONT && changed=1 ;;
            7) tui_edit_setting FONT_SIZE && changed=1 ;;
            8) tui_edit_setting MONO_FONT && changed=1 ;;
            9) tui_edit_setting TERMINAL && changed=1 ;;
            a) tui_edit_setting NOTIFICATIONS && changed=1 ;;
            b) tui_edit_setting AUTOSTART && changed=1 ;;
            c) tui_edit_setting WEATHER_LOCATION && changed=1 ;;
            e) ensure_user_config; "${VISUAL:-${EDITOR:-nano}}" "$DDAR_CONFIG_FILE"; config_load; changed=1 ;;
            q|$'\e') break ;;
        esac
    done
    ((changed)) && _tui_apply
}

tui_main() {
    local k
    [[ -t 0 && -t 1 ]] || { ddar_help; return 0; }
    ensure_user_config
    while true; do
        config_load
        tui_screen "DDAR RETRO DESKTOP" "$(_status)" \
            "1|Run / Launch" "2|Change Theme" "3|Update" "4|Configure Widgets" \
            "5|Configure Bar" "6|Configure Launcher" "7|Wallpapers" "8|System Info" \
            "9|Uninstall" "-" "k|Keyboard Shortcuts" "s|Settings" "q|Quit"
        k="$(tui_key)"; printf '\n'
        case "$k" in
            1) ( ddar_run ); tui_pause ;;
            2) tui_theme ;;
            3) ( ddar_update ); tui_pause ;;
            4) tui_widgets ;;
            5) tui_bar ;;
            6) tui_launcher ;;
            7) tui_wallpaper ;;
            8) ddar_info; tui_pause ;;
            9) "$DDAR_ROOT/uninstall.sh"; tui_pause ;;
            k) tui_shortcuts ;;
            s) tui_settings ;;
            q|$'\e') [[ -t 1 ]] && printf '\e[H\e[2J'; break ;;
        esac
    done
}
