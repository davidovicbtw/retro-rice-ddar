# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# DDAR shared library: paths, logging, config parsing and template rendering.
# Sourced by bin/ddar, install.sh, uninstall.sh and the helper scripts.

# bash >= 5.2: '&' in ${var//pattern/replacement} would mean "the match".
# DDAR's escaping (e.g. '<' -> '&lt;') needs it literal everywhere.
shopt -u patsub_replacement 2>/dev/null || true

# ---------------------------------------------------------------- paths ----
# DDAR_ROOT must be set by the caller (the repository / install directory).
: "${DDAR_ROOT:?DDAR_ROOT must be set before sourcing common.sh}"

DDAR_VERSION="1.0.0"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

DDAR_CONFIG_DIR="$XDG_CONFIG_HOME/ddar"          # user preferences (edit these)
DDAR_CONFIG_FILE="$DDAR_CONFIG_DIR/ddar.conf"
DDAR_SHORTCUTS_FILE="$DDAR_CONFIG_DIR/shortcuts.conf"
DDAR_USER_THEMES="$DDAR_CONFIG_DIR/themes"       # optional user themes
DDAR_GEN_DIR="$XDG_STATE_HOME/ddar"               # generated files (never edit)
DDAR_CACHE_DIR="$XDG_CACHE_HOME/ddar"             # disposable cache
DDAR_HYPR_DIR="$XDG_CONFIG_HOME/hypr/ddar"        # generated Hyprland snippets
DDAR_SCRIPTS="$DDAR_ROOT/scripts"
DDAR_TEMPLATES="$DDAR_ROOT/templates"
DDAR_DEFAULTS="$DDAR_ROOT/defaults"

# ------------------------------------------------------------- logging ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
    C_INV=$'\e[7m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_INV=""
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s[ .. ]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Ask a yes/no question. $1 = prompt, $2 = default (y|n).
confirm() {
    local prompt="$1" def="${2:-n}" ans hint="[y/N]"
    [[ "$def" == y ]] && hint="[Y/n]"
    # --yes / no terminal: take the default answer.
    if [[ "${DDAR_ASSUME_YES:-0}" == 1 || ! -t 0 ]]; then [[ "$def" == y ]]; return; fi
    read -r -p "$prompt $hint " ans || ans=""
    ans="${ans:-$def}"
    [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

in_hyprland() { [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && have hyprctl; }
in_wayland()  { [[ -n "${WAYLAND_DISPLAY:-}" ]]; }

# Send a desktop notification if possible, otherwise print.
notify() {
    if in_wayland && have notify-send; then
        notify-send -a DDAR "DDAR" "$*" 2>/dev/null || msg "$*"
    else
        msg "$*"
    fi
}

# ------------------------------------------------------- configuration ----
# The config file is a simple KEY="value" file. It is PARSED, never sourced,
# so a malformed or hostile file cannot execute code.

# Schema: KEY|type|default|description
#   types: enum:a,b,c  color  colororauto  int:min:max  modules  text  path  fontname
DDAR_SCHEMA=(
"THEME|theme|retro|Colour theme (see: ddar theme list)"
"MATUGEN|enum:off,accent,full|accent|Wallpaper colours: off, accent only, or full palette"
"ACCENT|colororauto|auto|Accent colour override (#rrggbb or auto)"
"WALLPAPER_DIR|path|~/Pictures/Wallpapers|Directory scanned for wallpapers"
"WALLPAPER|path||Current wallpaper (set by: ddar wallpaper)"
"WALLPAPER_BACKEND|enum:auto,dms,awww,swww,swaybg,hyprpaper,none|auto|Program used to draw the wallpaper (dms = DankMaterialShell)"
"FONT|fontname|Noto Sans|UI font family"
"FONT_SIZE|int:8:16|10|UI font size (pt)"
"MONO_FONT|fontname|monospace|Monospace font (terminal, popups)"
"BAR_HEIGHT|int:22:40|26|Bar height (px)"
"BAR_LEFT|modules|ddar workspaces|Bar modules, left"
"BAR_CENTER|modules|taskbar|Bar modules, centre"
"BAR_RIGHT|modules|media cpu memory network volume battery tray clock|Bar modules, right"
"WIDGETS|modules|ddar workspaces taskbar media cpu memory network volume battery tray clock|Enabled widgets"
"WORKSPACE_STYLE|enum:numbers,boxes,roman|numbers|Workspace button style"
"CLOCK_FORMAT|text|%a %H:%M|Clock format (strftime)"
"TRANSPARENCY|int:0:60|0|Bar/launcher transparency (percent)"
"ANIMATIONS|enum:off,low,normal|low|Hyprland animation intensity"
"HYPR_STYLE|enum:on,off|on|Let DDAR set Hyprland borders/gaps/rounding/animations"
"LAUNCHER_STYLE|enum:list,grid,compact,spotlight|list|Rofi launcher layout"
"LAUNCHER_ICONS|enum:on,off|on|Show application icons in the launcher"
"TERMINAL|text|auto|Terminal used for TUI popups (auto = detect)"
"NOTIFICATIONS|enum:auto,mako,off|auto|Start mako if no notification daemon is running"
"WEATHER_LOCATION|text||Weather location for the weather widget (empty = by IP)"
"AUTOSTART|enum:on,off|on|Start DDAR from Hyprland (exec-once)"
"TITLEBARS|enum:off,floating,all|off|Retro window title bars (needs the hyprbars plugin; see: ddar titlebars)"
)

# All known bar modules (widgets). Kept in one place so generator and TUI agree.
DDAR_MODULES=(ddar workspaces taskbar window media cpu memory network volume battery backlight tray clock weather)

_schema_field() { # $1=KEY $2=field index (1=type 2=default 3=desc)
    local row
    for row in "${DDAR_SCHEMA[@]}"; do
        if [[ "${row%%|*}" == "$1" ]]; then
            IFS='|' read -r -a _f <<<"$row"
            printf '%s' "${_f[$2]}"
            return 0
        fi
    done
    return 1
}

config_known_key() { _schema_field "$1" 0 >/dev/null; }

declare -gA CFG=()

# Load defaults, then overlay the user's config file.
config_load() {
    local row key val line
    CFG=()
    for row in "${DDAR_SCHEMA[@]}"; do
        IFS='|' read -r key _ val _ <<<"$row"
        CFG[$key]="$val"
    done
    [[ -r "$DDAR_CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        val="${val%"${val##*[![:space:]]}"}"           # trim right
        if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        if config_known_key "$key" && config_validate "$key" "$val" >/dev/null 2>&1; then
            CFG[$key]="$val"
        elif config_known_key "$key"; then
            warn "ddar.conf: ignoring invalid value for $key: '$val'"
        fi
    done <"$DDAR_CONFIG_FILE"
}

cfg() { printf '%s' "${CFG[$1]-}"; }

# Expand a leading ~ in a configured path.
expand_path() {
    local p="$1"
    # shellcheck disable=SC2088  # matching a literal ~ is the point here
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p:2}" ;;
    esac
    printf '%s' "$p"
}

# Validate a value against the schema. Prints a reason on failure.
config_validate() {
    local key="$1" val="$2" type
    type="$(_schema_field "$key" 1)" || { echo "unknown key: $key"; return 1; }
    # shellcheck disable=SC1003
    case "$val" in *$'\n'*|*'"'*|*'\'*|*'`'*|*'$'*) echo "value may not contain quotes, backslashes, \$ or backticks"; return 1 ;; esac
    case "$type" in
        enum:*)
            local opt; IFS=',' read -r -a _opts <<<"${type#enum:}"
            for opt in "${_opts[@]}"; do [[ "$val" == "$opt" ]] && return 0; done
            echo "must be one of: ${type#enum:}"; return 1 ;;
        int:*)
            local lo hi; IFS=':' read -r _ lo hi <<<"$type"
            [[ "$val" =~ ^[0-9]+$ ]] && (( val >= lo && val <= hi )) && return 0
            echo "must be a number between $lo and $hi"; return 1 ;;
        color) [[ "$val" =~ ^#[0-9a-fA-F]{6}$ ]] && return 0; echo "must be #rrggbb"; return 1 ;;
        colororauto) [[ "$val" == auto || "$val" =~ ^#[0-9a-fA-F]{6}$ ]] && return 0; echo "must be auto or #rrggbb"; return 1 ;;
        theme) [[ "$val" =~ ^[a-z0-9-]+$ ]] && return 0; echo "theme names use a-z, 0-9 and -"; return 1 ;;
        modules)
            local m; for m in $val; do
                _is_module "$m" || { echo "unknown module '$m' (known: ${DDAR_MODULES[*]})"; return 1; }
            done; return 0 ;;
        fontname) [[ "$val" =~ ^[A-Za-z0-9\ ._-]+$ ]] && return 0; echo "font names use letters, digits, space . _ -"; return 1 ;;
        path) [[ "$val" != *"'"* ]] && return 0; echo "paths may not contain single quotes"; return 1 ;;
        text) [[ "$val" =~ ^[A-Za-z0-9\ %:./,_+-]*$ ]] && return 0; echo "allowed characters: letters digits space % : . / , _ + -"; return 1 ;;
    esac
    return 0
}

_is_module() { local m; for m in "${DDAR_MODULES[@]}"; do [[ "$m" == "$1" ]] && return 0; done; return 1; }

# Set KEY=VALUE in the user config, preserving comments and other lines.
config_set() {
    local key="$1" val="$2" reason tmp
    config_known_key "$key" || die "Unknown setting: $key (see: ddar config list)"
    if ! reason="$(config_validate "$key" "$val")"; then die "Invalid value for $key: $reason"; fi
    ensure_user_config
    tmp="$(mktemp "$DDAR_CONFIG_DIR/.ddar.conf.XXXXXX")"
    awk -v k="$key" -v v="$val" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=\"" v "\""; done = 1 }; next }
        { print }
        END { if (!done) print k "=\"" v "\"" }
    ' "$DDAR_CONFIG_FILE" >"$tmp"
    mv -f "$tmp" "$DDAR_CONFIG_FILE"
    CFG[$key]="$val"
}

ensure_user_config() {
    mkdir -p "$DDAR_CONFIG_DIR"
    [[ -e "$DDAR_CONFIG_FILE" ]] || cp "$DDAR_DEFAULTS/ddar.conf" "$DDAR_CONFIG_FILE"
    [[ -e "$DDAR_SHORTCUTS_FILE" ]] || cp "$DDAR_DEFAULTS/shortcuts.conf" "$DDAR_SHORTCUTS_FILE"
}

# ------------------------------------------------------------ templates ----
# render_template SRC DEST : replaces @@key@@ with values from the global
# associative array PAL (palette + settings). Unknown tokens are left alone.
declare -gA PAL=()

render_template() {
    local src="$1" dest="$2" content key
    content="$(<"$src")"
    for key in "${!PAL[@]}"; do
        content="${content//@@${key}@@/${PAL[$key]}}"
    done
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" >"$dest.tmp.$$"
    mv -f "$dest.tmp.$$" "$dest"
}

# ------------------------------------------------------------- terminal ----
detect_terminal() {
    local t; t="$(cfg TERMINAL)"
    if [[ -n "$t" && "$t" != auto ]]; then printf '%s' "$t"; return; fi
    for t in kitty foot alacritty wezterm ghostty konsole xterm; do
        have "$t" && { printf '%s' "$t"; return; }
    done
    return 1
}

# Start a detached background program. fd 9 (the `ddar run` lock) is closed
# so long-running children never keep the lock held.
spawn() { setsid -f "$@" </dev/null >/dev/null 2>&1 9>&-; }

# Run a command in a new terminal window (used by bar popups).
run_in_terminal() {
    local term; term="$(detect_terminal)" || { notify "No terminal emulator found"; return 1; }
    case "$term" in
        kitty)     spawn kitty --class ddar-term -e "$@" ;;
        wezterm)   spawn wezterm start -- "$@" ;;
        *)         spawn "$term" -e "$@" ;;
    esac
}
