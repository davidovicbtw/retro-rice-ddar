# shellcheck shell=bash disable=SC2004,SC2154
# (PAL/CFG are associative arrays declared in common.sh. Checked on its own,
#  the linter mistakes their string keys for arithmetic variables.)
# DDAR generator: turns ddar.conf + theme (+ optional Matugen palette) into
# the generated configs for Waybar, Rofi, Kitty, Mako and Hyprland.
# Requires common.sh to be sourced first.

# Keys every theme must define (other than NAME/DESCRIPTION/MODE).
THEME_KEYS=(face face_hi face_lo frame text text_dim field field_text tip tip_text
            accent accent_text urgent good warn desktop term_bg term_fg
            color0 color1 color2 color3 color4 color5 color6 color7
            color8 color9 color10 color11 color12 color13 color14 color15)

# Find a theme directory: user themes override bundled ones.
theme_path() {
    local name="$1"
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || return 1
    if [[ -r "$DDAR_USER_THEMES/$name/theme.conf" ]]; then
        printf '%s' "$DDAR_USER_THEMES/$name/theme.conf"
    elif [[ -r "$DDAR_ROOT/themes/$name/theme.conf" ]]; then
        printf '%s' "$DDAR_ROOT/themes/$name/theme.conf"
    else
        return 1
    fi
}

theme_names() {
    local d
    for d in "$DDAR_ROOT"/themes/*/ "$DDAR_USER_THEMES"/*/; do
        [[ -r "$d/theme.conf" ]] && basename "$d"
    done | sort -u
}

# theme_meta FILE KEY  -> NAME / DESCRIPTION / MODE
theme_meta() {
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$1" | head -n1
}

# Load a theme file into PAL (safe parser, colours only).
load_theme() {
    local file line key val k missing=()
    file="$(theme_path "$1")" || { warn "Theme '$1' not found, falling back to 'retro'"; file="$DDAR_ROOT/themes/retro/theme.conf"; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*([a-z0-9_]+)[[:space:]]*=[[:space:]]*(#[0-9a-fA-F]{6})[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            PAL[$key]="${val,,}"
        fi
    done <"$file"
    PAL[mode]="$(theme_meta "$file" MODE)"
    [[ "${PAL[mode]}" == dark ]] || PAL[mode]=light
    PAL[theme_name]="$(theme_meta "$file" NAME)"
    PAL[dynamic]="$(theme_meta "$file" DYNAMIC)"   # yes: always full Matugen
    PAL[fixed]="$(theme_meta "$file" FIXED)"       # yes: never Matugen (official palettes)
    for k in "${THEME_KEYS[@]}"; do [[ -n "${PAL[$k]:-}" ]] || missing+=("$k"); done
    if ((${#missing[@]})); then
        warn "Theme '$1' is missing: ${missing[*]} - using 'retro' values for those"
        local -A saved=(); for k in "${!PAL[@]}"; do saved[$k]="${PAL[$k]}"; done
        load_theme retro
        for k in "${!saved[@]}"; do PAL[$k]="${saved[$k]}"; done
    fi
}

# ------------------------------------------------------------ colour math --
_hex2rgb() { local h="${1#\#}"; printf '%d %d %d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

# mix A B T(0-100): T percent of B blended into A
mix() {
    local r1 g1 b1 r2 g2 b2 t="$3"
    read -r r1 g1 b1 <<<"$(_hex2rgb "$1")"
    read -r r2 g2 b2 <<<"$(_hex2rgb "$2")"
    printf '#%02x%02x%02x' $(( (r1*(100-t) + r2*t) / 100 )) $(( (g1*(100-t) + g2*t) / 100 )) $(( (b1*(100-t) + b2*t) / 100 ))
}

# Relative brightness 0-255 (fast approximation, good enough for contrast picks)
luma() { local r g b; read -r r g b <<<"$(_hex2rgb "$1")"; echo $(( (r*299 + g*587 + b*114) / 1000 )); }

readable_on() { if (( $(luma "$1") > 150 )); then printf '#111111'; else printf '#ffffff'; fi; }

# ---------------------------------------------------------------- matugen --
# Prints "key=#hex" lines for the roles DDAR uses, from the wallpaper.
matugen_palette() {
    local img="$1" mode="$2" sum cache json
    have matugen && have jq && [[ -r "$img" ]] || return 1
    sum="$(cksum <"$img" | cut -d' ' -f1)"
    cache="$DDAR_CACHE_DIR/matugen-$sum.json"
    mkdir -p "$DDAR_CACHE_DIR"
    if [[ ! -s "$cache" ]]; then
        # matugen >= 4 needs --prefer when it is not attached to a terminal;
        # older versions do not know the flag, so retry without it.
        json="$(matugen image "$img" --json hex --dry-run --prefer saturation 2>/dev/null)" ||
            json="$(matugen image "$img" --json hex --dry-run 2>/dev/null)" || return 1
        printf '%s' "$json" >"$cache.tmp" && mv -f "$cache.tmp" "$cache"
    fi
    # Supports both the matugen 4 layout (.colors.role.mode.color) and the
    # older one (.colors.mode.role).
    jq -r --arg m "$mode" '
        def c($n): (.colors[$n][$m].color? // .colors[$m][$n]? // empty);
        [ ["accent", c("primary")], ["accent_text", c("on_primary")],
          ["m_surface", c("surface_container")], ["m_surface_hi", c("surface_bright")],
          ["m_surface_lo", c("surface_dim")], ["m_outline", c("outline")],
          ["m_text", c("on_surface")], ["m_text_dim", c("on_surface_variant")],
          ["m_field", c("surface_container_lowest")], ["m_error", c("error")] ]
        | .[] | select(.[1] != null and (.[1] | test("^#[0-9a-fA-F]{6}$"))) | "\(.[0])=\(.[1])"
    ' "$cache" 2>/dev/null
}

# The wallpaper DankMaterialShell is showing, if DMS is installed: first its
# IPC, then its session file. Only an existing image file is accepted.
dms_wallpaper() {
    local p=""
    have dms || return 1
    p="$(timeout 2 dms ipc call wallpaper get 2>/dev/null | tail -n1)"
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    if [[ ! -f "$p" ]] && have jq; then
        p="$(jq -r '.wallpaperPath // empty' "$XDG_STATE_HOME/DankMaterialShell/session.json" 2>/dev/null)"
    fi
    [[ -f "$p" && -r "$p" ]] || return 1
    printf '%s' "$p"
}

# Image the colours are derived from: DMS's wallpaper, else DDAR's own.
colour_wallpaper() {
    local img
    img="$(dms_wallpaper)" && { printf '%s' "$img"; return 0; }
    img="$(expand_path "$(cfg WALLPAPER)")"
    if [[ -z "$img" && "${PAL[dynamic]:-}" == yes ]]; then img="$DDAR_ROOT/assets/wallpapers/ddar-teal.png"; fi
    [[ -n "$img" && -r "$img" ]] && printf '%s' "$img"
}

apply_matugen() {
    local mode img line key val
    if [[ "${PAL[dynamic]:-}" == yes ]]; then mode=full
    elif [[ "${PAL[fixed]:-}" == yes ]]; then return 0
    else mode="$(cfg MATUGEN)"; fi
    [[ "$mode" == off ]] && return 0
    img="$(colour_wallpaper)" || return 0
    PAL[colour_img]="$img"
    if ! have matugen; then
        [[ "${PAL[dynamic]:-}" == yes ]] && warn "Theme 'dynamic' needs matugen (sudo pacman -S matugen) - using fallback colours"
        return 0
    fi
    local -A M=()
    while IFS='=' read -r key val; do [[ -n "$key" ]] && M[$key]="$val"; done < <(matugen_palette "$img" "${PAL[mode]}")
    if [[ -z "${M[accent]:-}" ]]; then warn "Matugen produced no palette, keeping theme colours"; return 0; fi
    PAL[accent]="${M[accent]}"
    PAL[accent_text]="${M[accent_text]:-$(readable_on "${M[accent]}")}"
    if [[ "$mode" == full && -n "${M[m_surface]:-}" ]]; then
        # Full mode re-skins the panels, but keeps the retro bevel structure:
        # highlight/shadow edges are derived from the surface colour.
        PAL[face]="${M[m_surface]}"
        PAL[face_hi]="$(mix "${M[m_surface]}" '#ffffff' 45)"
        PAL[face_lo]="$(mix "${M[m_surface]}" '#000000' 35)"
        PAL[frame]="${M[m_outline]:-$(mix "${M[m_surface]}" '#000000' 75)}"
        PAL[text]="${M[m_text]:-${PAL[text]}}"
        PAL[text_dim]="${M[m_text_dim]:-${PAL[text_dim]}}"
        PAL[field]="${M[m_field]:-${PAL[field]}}"
        PAL[field_text]="${M[m_text]:-${PAL[field_text]}}"
        PAL[term_bg]="${M[m_field]:-${PAL[term_bg]}}"
        PAL[term_fg]="${M[m_text]:-${PAL[term_fg]}}"
        PAL[urgent]="${M[m_error]:-${PAL[urgent]}}"
    fi
    PAL[palette_source]="matugen ($mode)"
}

# Fill in every derived key the templates use.
derive_palette() {
    local acc t
    if [[ "$(cfg ACCENT)" != auto ]]; then
        PAL[accent]="$(cfg ACCENT)"
        PAL[accent_text]="$(readable_on "${PAL[accent]}")"
        PAL[palette_source]="accent override"
    fi
    acc="${PAL[accent]}"
    PAL[select]="$acc"
    PAL[select_text]="${PAL[accent_text]}"
    PAL[title_a]="$acc"
    if [[ "${PAL[mode]}" == dark ]]; then PAL[title_b]="$(mix "$acc" "${PAL[face]}" 55)"
    else PAL[title_b]="$(mix "$acc" '#ffffff' 35)"; fi
    PAL[title_text]="${PAL[accent_text]}"
    PAL[term_cursor]="$acc"
    PAL[face_pressed]="$(mix "${PAL[face]}" "${PAL[face_lo]}" 25)"
    PAL[face_hover]="$(mix "${PAL[face]}" "${PAL[face_hi]}" 30)"

    # Transparency: 0 = opaque.
    t="$(cfg TRANSPARENCY)"
    PAL[opacity]="$(printf '0.%02d' $((100 - t)))"; ((t == 0)) && PAL[opacity]="1.0"
    PAL[alpha_hex]="$(printf '%02x' $(( (100 - t) * 255 / 100 )))"

    # Hyprland wants rgb(rrggbb) without '#'.
    local k
    for k in accent title_b frame face face_lo; do PAL[${k}_rgb]="${PAL[$k]#\#}"; done

    PAL[font]="$(cfg FONT)"
    PAL[font_size]="$(cfg FONT_SIZE)"
    PAL[mono_font]="$(cfg MONO_FONT)"
    PAL[bar_height]="$(cfg BAR_HEIGHT)"
    PAL[scripts]="$DDAR_SCRIPTS"
    PAL[gen]="$DDAR_GEN_DIR"
    PAL[hypr_dir]="$DDAR_HYPR_DIR"
    PAL[version]="$DDAR_VERSION"
    PAL[palette_source]="${PAL[palette_source]:-theme}"
}

build_palette() {
    PAL=()
    load_theme "$(cfg THEME)"
    apply_matugen
    derive_palette
}

# ---------------------------------------------------------------- waybar --
# Map DDAR module names to Waybar module ids.
_waybar_id() {
    case "$1" in
        ddar) echo custom/ddar ;; workspaces) echo hyprland/workspaces ;;
        taskbar) echo wlr/taskbar ;; window) echo hyprland/window ;;
        media) echo mpris ;; volume) echo pulseaudio ;; weather) echo custom/weather ;;
        *) echo "$1" ;;
    esac
}

# Is the widget enabled and does the hardware exist?
_module_active() {
    local m="$1"
    [[ " $(cfg WIDGETS) " == *" $m "* ]] || return 1
    case "$m" in
        battery) compgen -G "/sys/class/power_supply/BAT*" >/dev/null ;;
        backlight) compgen -G "/sys/class/backlight/*" >/dev/null ;;
        *) return 0 ;;
    esac
}

_module_list_json() {
    local m ids=()
    for m in $1; do _module_active "$m" && ids+=("$(_waybar_id "$m")"); done
    printf '%s\n' "${ids[@]}" | jq -R . | jq -s 'map(select(length > 0))'
}

gen_waybar() {
    local out="$DDAR_GEN_DIR/waybar" ws_fmt clock clock_interval=60
    mkdir -p "$out"
    clock="$(cfg CLOCK_FORMAT)"
    [[ "$clock" == *%S* || "$clock" == *%T* ]] && clock_interval=1
    case "$(cfg WORKSPACE_STYLE)" in
        boxes) ws_fmt='{icon}' ;;
        roman) ws_fmt='{icon}' ;;
        *)     ws_fmt='{name}' ;;
    esac
    jq --arg scripts "$DDAR_SCRIPTS" \
       --argjson height "$(cfg BAR_HEIGHT)" \
       --argjson left "$(_module_list_json "$(cfg BAR_LEFT)")" \
       --argjson center "$(_module_list_json "$(cfg BAR_CENTER)")" \
       --argjson right "$(_module_list_json "$(cfg BAR_RIGHT)")" \
       --arg clock "{:$clock}" --argjson clock_interval "$clock_interval" \
       --arg ws_fmt "$ws_fmt" --arg ws_style "$(cfg WORKSPACE_STYLE)" '
        walk(if type == "string" then gsub("@SCRIPTS@"; $scripts) else . end)
        | .modules as $m
        | {
            "layer": "top", "position": "top", "height": $height,
            "spacing": 0, "margin": "0", "reload_style_on_change": false,
            "modules-left": $left, "modules-center": $center, "modules-right": $right
          }
        + ($m | with_entries(select(.key as $k | ($left + $center + $right) | index($k))))
        | if .["clock"] then .["clock"].format = $clock | .["clock"].interval = $clock_interval else . end
        | if .["hyprland/workspaces"] then
            .["hyprland/workspaces"].format = $ws_fmt
            | .["hyprland/workspaces"]["format-icons"] =
                (if $ws_style == "boxes" then {"active": "■", "urgent": "▣", "default": "□"}
                 elif $ws_style == "roman" then {"1":"I","2":"II","3":"III","4":"IV","5":"V","6":"VI","7":"VII","8":"VIII","9":"IX","10":"X","default":"•"}
                 else null end)
            | if .["hyprland/workspaces"]["format-icons"] == null then del(.["hyprland/workspaces"]["format-icons"]) else . end
          else . end
    ' "$DDAR_TEMPLATES/waybar/modules.json" >"$out/config.jsonc.tmp" || die "Failed to generate Waybar config"
    mv -f "$out/config.jsonc.tmp" "$out/config.jsonc"
    render_template "$DDAR_TEMPLATES/waybar/colors.css" "$out/colors.css"
    render_template "$DDAR_TEMPLATES/waybar/style.css" "$out/style.css"
}

# ------------------------------------------------------------ other apps --
gen_rofi() {
    local out="$DDAR_GEN_DIR/rofi" style
    style="$(cfg LAUNCHER_STYLE)"
    PAL[show_icons]="$( [[ "$(cfg LAUNCHER_ICONS)" == on ]] && echo true || echo false )"
    render_template "$DDAR_TEMPLATES/rofi/colors.rasi" "$out/colors.rasi"
    render_template "$DDAR_TEMPLATES/rofi/base.rasi" "$out/base.rasi"
    render_template "$DDAR_TEMPLATES/rofi/launcher-$style.rasi" "$out/launcher.rasi"
    render_template "$DDAR_TEMPLATES/rofi/popup.rasi" "$out/popup.rasi"
}

gen_kitty() { render_template "$DDAR_TEMPLATES/kitty/colors.conf" "$DDAR_GEN_DIR/kitty/colors.conf"; }
gen_mako()  { render_template "$DDAR_TEMPLATES/mako/config" "$DDAR_GEN_DIR/mako/config"; }

gen_hypr() {
    local anim
    mkdir -p "$DDAR_HYPR_DIR"
    render_template "$DDAR_TEMPLATES/hypr/ddar.conf" "$DDAR_HYPR_DIR/ddar.conf"
    render_template "$DDAR_TEMPLATES/hypr/colors.conf" "$DDAR_HYPR_DIR/colors.conf"
    if [[ "$(cfg HYPR_STYLE)" == on ]]; then
        render_template "$DDAR_TEMPLATES/hypr/look.conf" "$DDAR_HYPR_DIR/look.conf"
        anim="$(cfg ANIMATIONS)"
        render_template "$DDAR_TEMPLATES/hypr/animations-$anim.conf" "$DDAR_HYPR_DIR/animations.conf"
    else
        printf '# HYPR_STYLE=off: DDAR leaves your look settings alone.\n' >"$DDAR_HYPR_DIR/look.conf"
        printf '# HYPR_STYLE=off\n' >"$DDAR_HYPR_DIR/animations.conf"
    fi
    if [[ "$(cfg AUTOSTART)" == on ]]; then
        printf '# Generated by DDAR - edit ~/.config/ddar/ddar.conf (AUTOSTART) instead.\nexec-once = %s/bin/ddar run --boot\n' \
            "$DDAR_ROOT" >"$DDAR_HYPR_DIR/autostart.conf"
    else
        printf '# AUTOSTART=off\n' >"$DDAR_HYPR_DIR/autostart.conf"
    fi
    shortcuts_generate
}

write_palette_env() {
    local k f="$DDAR_GEN_DIR/palette.env"
    mkdir -p "$DDAR_GEN_DIR"
    {
        echo "# Generated by DDAR $DDAR_VERSION - resolved palette (read-only)"
        for k in $(printf '%s\n' "${!PAL[@]}" | sort); do
            [[ "${PAL[$k]}" =~ ^#[0-9a-f]{6}$ ]] && echo "$k=${PAL[$k]}"
        done
        echo "theme=$(cfg THEME)"
        echo "source=${PAL[palette_source]}"
        echo "wallpaper=${PAL[colour_img]:-}"
    } >"$f"
}

# Generate everything. Cheap enough (well under a second) to run on every change.
generate_all() {
    have jq || die "jq is required to generate configs (sudo pacman -S jq)"
    ensure_user_config
    config_load
    build_palette
    mkdir -p "$DDAR_GEN_DIR"
    gen_waybar
    gen_rofi
    gen_kitty
    gen_mako
    gen_hypr
    write_palette_env
}
