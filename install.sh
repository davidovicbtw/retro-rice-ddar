#!/usr/bin/env bash
# DDAR installer. Safe to run repeatedly: every step checks before it acts,
# existing files are backed up before they are changed, and nothing outside
# the files listed in the summary is touched.
#
#   ./install.sh            interactive install
#   ./install.sh --yes      answer every question with its default
#   ./install.sh --no-deps  skip the package step
set -uo pipefail

DDAR_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export DDAR_ROOT
# shellcheck source=lib/common.sh
source "$DDAR_ROOT/lib/common.sh"
# shellcheck source=lib/deps.sh
source "$DDAR_ROOT/lib/deps.sh"

SKIP_DEPS=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) DDAR_ASSUME_YES=1 ;;
        --no-deps) SKIP_DEPS=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $arg (see --help)" ;;
    esac
done

STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s== %d. %s ==%s\n' "$C_BOLD" "$STEP" "$*" "$C_RESET"; }

HYPR_CONF="$XDG_CONFIG_HOME/hypr/hyprland.conf"
KITTY_CONF="$XDG_CONFIG_HOME/kitty/kitty.conf"
BIN_DIR="$HOME/.local/bin"
MARK_BEGIN="# >>> DDAR >>> managed by DDAR install.sh - remove with uninstall.sh"
MARK_END="# <<< DDAR <<<"
BACKUP_DIR="$DDAR_GEN_DIR/backups/$(date +%Y%m%d-%H%M%S)"
CHANGES=()

backup() { # backup FILE -> copies it into this run's backup dir (once)
    local f="$1" dest
    [[ -e "$f" ]] || return 0
    dest="$BACKUP_DIR/${f#"$HOME"/}"
    [[ -e "$dest" ]] && return 0
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$f" "$dest" || die "Could not back up $f - aborting before changing it"
    ok "Backed up $f -> $dest"
}

has_block() { [[ -r "$1" ]] && grep -qF "$MARK_BEGIN" "$1"; }

append_block() { # append_block FILE LINE
    local f="$1" line="$2" nl=""
    backup "$f"
    mkdir -p "$(dirname "$f")"
    [[ -s "$f" && -n "$(tail -c1 "$f")" ]] && nl=$'\n'
    {
        printf '%s' "$nl"
        echo
        echo "$MARK_BEGIN"
        echo "$line"
        echo "$MARK_END"
    } >>"$f" || die "Could not write $f"
    CHANGES+=("appended DDAR block to $f")
}

# ------------------------------------------------------------------------
cat <<EOF
${C_INV}${C_BOLD}  DDAR RETRO DESKTOP - installer v$DDAR_VERSION  ${C_RESET}

This installer will:
  * check your system and tell you exactly what is missing
  * create your settings in $DDAR_CONFIG_DIR (only if absent)
  * generate configs into $DDAR_GEN_DIR and $DDAR_HYPR_DIR
  * add ONE 'source =' line to your hyprland.conf (after a backup)
  * link the 'ddar' command into $BIN_DIR
It never overwrites your existing configs.
EOF

# ------------------------------------------------------------------------
step "Pre-flight checks"
[[ "$EUID" -ne 0 ]] || die "Do not run the installer as root; it configures your user account. sudo is used only for pacman."
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die "bash >= 4.4 is required"
case "$DDAR_ROOT" in
    *"'"*|*$'\n'*|*'"'*) die "Please move DDAR to a path without quotes or newlines (current: $DDAR_ROOT)" ;;
    /tmp/*) warn "DDAR is in /tmp and will vanish on reboot. Clone it somewhere permanent (e.g. ~/.local/share/ddar)." ;;
esac
ok "Installing from $DDAR_ROOT"

IS_ARCH=0
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")"
    [[ " $os_id " == *" arch "* ]] && IS_ARCH=1
fi
if ((IS_ARCH)) && have pacman; then
    ok "Arch Linux (or derivative) detected"
else
    warn "This does not look like Arch Linux. DDAR targets Arch; packages will not be installed automatically."
    msg "  Dependencies are still checked; install missing ones with your package manager."
    confirm "Continue anyway?" y || exit 1
fi

if have hyprctl; then
    ok "Hyprland found: $(hyprctl version -j 2>/dev/null | jq -r '.tag // empty' 2>/dev/null || echo 'installed')"
else
    warn "Hyprland (hyprctl) not found"
fi
if in_hyprland; then ok "Running inside a Hyprland session"; else msg "${C_DIM}Not inside a Hyprland session - components will start on next login (or run 'ddar run').${C_RESET}"; fi

# ------------------------------------------------------------------------
step "Dependencies"
deps_report; missing_required=$?
if ((SKIP_DEPS == 0)) && ((IS_ARCH)) && have pacman; then
    mapfile -t req < <(deps_missing required | cut -d'|' -f2 | sort -u)
    mapfile -t rec < <(deps_missing recommended | cut -d'|' -f2 | sort -u)
    if ((${#req[@]})); then
        msg "Required packages: ${req[*]}"
        if confirm "Install them now with 'sudo pacman -S --needed'?" y; then
            sudo pacman -S --needed "${req[@]}" || die "pacman failed; nothing else was changed"
        fi
    fi
    if ((${#rec[@]})); then
        msg "Recommended packages: ${rec[*]}"
        if confirm "Install recommended packages too?" n; then
            sudo pacman -S --needed "${rec[@]}" || warn "pacman failed for some recommended packages - continuing"
        fi
    fi
    if have fc-list && ! fc-list : family 2>/dev/null | grep -iE 'DejaVu|Noto Sans' >/dev/null; then
        read -r -a font_pkgs <<<"$DDAR_FONT_PKGS"
        confirm "Install fonts (${font_pkgs[*]})?" y && { sudo pacman -S --needed "${font_pkgs[@]}" || warn "font install failed"; }
    fi
    deps_missing required | grep -q . && missing_required=1 || missing_required=0
fi
if ((missing_required)); then
    err "Required dependencies are still missing (listed above)."
    die "Install them and re-run ./install.sh - no changes were made."
fi
ok "All required dependencies present"

# ------------------------------------------------------------------------
step "User settings"
mkdir -p "$DDAR_CONFIG_DIR"
for f in ddar.conf shortcuts.conf; do
    if [[ -e "$DDAR_CONFIG_DIR/$f" ]]; then
        ok "Keeping your existing $DDAR_CONFIG_DIR/$f"
    else
        cp "$DDAR_DEFAULTS/$f" "$DDAR_CONFIG_DIR/$f" && ok "Created $DDAR_CONFIG_DIR/$f"
        CHANGES+=("created $DDAR_CONFIG_DIR/$f")
    fi
done
config_load
wpdir="$(expand_path "$(cfg WALLPAPER_DIR)")"
if [[ -d "$wpdir" ]]; then ok "Wallpaper folder: $wpdir"
else msg "${C_DIM}Wallpaper folder $wpdir does not exist; DDAR will use its bundled wallpapers until you create it.${C_RESET}"; fi

# ------------------------------------------------------------------------
step "Desktop shell detection"
shell_pids=""
for p in dms quickshell qs; do pgrep -x "$p" >/dev/null 2>&1 && shell_pids+="$p "; done
if [[ -z "$shell_pids" && -r "$HYPR_CONF" ]] && grep -qE '^[[:space:]]*exec(-once)?[[:space:]]*=.*\b(dms|quickshell|qs)\b' "$HYPR_CONF"; then
    shell_pids="(started from hyprland.conf)"
fi
if [[ -n "$shell_pids" ]]; then
    warn "A desktop shell is in use: $shell_pids (e.g. DankMaterialShell)."
    msg "  It draws its own wallpaper, so DDAR will NOT start a wallpaper program."
    [[ "$(cfg WALLPAPER_BACKEND)" == auto ]] && config_set WALLPAPER_BACKEND none && ok "WALLPAPER_BACKEND=none"
    msg "  It probably has its own bar too; DDAR's Waybar would be a second bar."
else
    ok "No Quickshell-based desktop shell detected"
fi

# ------------------------------------------------------------------------
step "Hyprland startup inspection"
AUTOSTART_WANTED="$(cfg AUTOSTART)"
if [[ -r "$HYPR_CONF" ]]; then
    conflicts="$(grep -nE '^[[:space:]]*exec(-once)?[[:space:]]*=.*\b(waybar|mako|dunst|swaync|swww|awww|swaybg|hyprpaper)\b' "$HYPR_CONF" || true)"
    if [[ -n "$conflicts" ]]; then
        warn "Your hyprland.conf already starts components DDAR can manage:"
        printf '      %s\n' "$conflicts" | sed 's/^/  /'
        msg "  DDAR will NOT edit these lines. If you enable DDAR autostart, comment out the"
        msg "  waybar line yourself to avoid two bars (or run 'ddar run --replace' once)."
        msg "  Other notification daemons are respected: DDAR only starts mako if none runs."
    else
        ok "No conflicting exec lines found in hyprland.conf"
    fi
    if confirm "Start DDAR automatically with Hyprland (exec-once in DDAR's own file)?" y; then
        config_set AUTOSTART on
    else
        config_set AUTOSTART off
    fi
    AUTOSTART_WANTED="$(cfg AUTOSTART)"
fi

# ------------------------------------------------------------------------
step "Generating configs"
"$DDAR_ROOT/bin/ddar" generate || die "Config generation failed"
ok "Generated: $DDAR_GEN_DIR (waybar, rofi, kitty, mako) and $DDAR_HYPR_DIR"

# ------------------------------------------------------------------------
step "Hyprland integration"
SOURCE_LINE="source = $DDAR_HYPR_DIR/ddar.conf"
if [[ ! -e "$HYPR_CONF" ]]; then
    warn "$HYPR_CONF does not exist yet."
    msg "  Start Hyprland once (it writes a default config), then re-run ./install.sh."
    msg "  Or add this line to your config yourself:  $SOURCE_LINE"
elif has_block "$HYPR_CONF"; then
    ok "hyprland.conf already sources DDAR - unchanged"
elif grep -qF "$DDAR_HYPR_DIR/ddar.conf" "$HYPR_CONF"; then
    ok "hyprland.conf already sources DDAR (added by you) - unchanged"
else
    if [[ -L "$HYPR_CONF" ]]; then
        warn "hyprland.conf is a symlink to $(readlink -f "$HYPR_CONF") (dotfile manager?)."
    fi
    msg "Will append to $HYPR_CONF:"
    msg "    $SOURCE_LINE"
    msg "  (at the end, so DDAR's look settings take precedence; set HYPR_STYLE=\"off\" to keep yours)"
    if confirm "Add the DDAR source line?" y; then
        append_block "$HYPR_CONF" "$SOURCE_LINE"
        ok "hyprland.conf now sources DDAR"
    else
        msg "Skipped. Add it manually later:  $SOURCE_LINE"
    fi
fi

# ------------------------------------------------------------------------
step "Terminal colours (kitty)"
KITTY_LINE="include $DDAR_GEN_DIR/kitty/colors.conf"
if ! have kitty; then
    msg "${C_DIM}kitty not installed - skipped${C_RESET}"
elif has_block "$KITTY_CONF"; then
    ok "kitty.conf already includes DDAR colours - unchanged"
elif confirm "Theme kitty with DDAR colours (adds one include line to kitty.conf)?" n; then
    append_block "$KITTY_CONF" "$KITTY_LINE"
    ok "kitty.conf includes DDAR colours"
else
    msg "Skipped. To enable later add to kitty.conf:  $KITTY_LINE"
fi

# ------------------------------------------------------------------------
step "The ddar command"
mkdir -p "$BIN_DIR"
target="$DDAR_ROOT/bin/ddar"
if [[ -L "$BIN_DIR/ddar" && "$(readlink -f "$BIN_DIR/ddar")" == "$(readlink -f "$target")" ]]; then
    ok "$BIN_DIR/ddar already points to this checkout"
elif [[ -e "$BIN_DIR/ddar" || -L "$BIN_DIR/ddar" ]]; then
    warn "$BIN_DIR/ddar exists and is not this DDAR - leaving it alone."
    msg "  Remove it yourself and re-run, or call $target directly."
else
    ln -s "$target" "$BIN_DIR/ddar" && ok "Linked $BIN_DIR/ddar -> $target"
    CHANGES+=("linked $BIN_DIR/ddar")
fi
chmod +x "$DDAR_ROOT/bin/ddar" "$DDAR_ROOT/scripts/"* "$DDAR_ROOT/install.sh" "$DDAR_ROOT/uninstall.sh"
case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR is in your PATH" ;;
    *) warn "$BIN_DIR is not in your PATH. Add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ------------------------------------------------------------------------
step "Start"
if in_hyprland; then
    if confirm "Start DDAR now (ddar run)?" y; then
        if pgrep -x waybar >/dev/null && confirm "A Waybar is already running. Replace it with DDAR's bar?" y; then
            "$DDAR_ROOT/bin/ddar" run --replace
        else
            "$DDAR_ROOT/bin/ddar" run
        fi
    fi
else
    msg "Log in to Hyprland$([[ "$AUTOSTART_WANTED" == on ]] && echo ' - DDAR starts automatically' || echo ' and run: ddar run')."
fi

# ------------------------------------------------------------------------
printf '\n%s== Done ==%s\n' "$C_BOLD" "$C_RESET"
if ((${#CHANGES[@]})); then
    msg "Changes made this run:"; printf '  - %s\n' "${CHANGES[@]}"
else
    msg "Nothing needed changing (already installed)."
fi
[[ -d "$BACKUP_DIR" ]] && msg "Backups: $BACKUP_DIR"
cat <<EOF

Next steps:
  ddar              open the DDAR menu
  ddar run          start / reload the desktop
  ddar shortcut     list keyboard shortcuts (SUPER+ALT+D opens the launcher)
  ddar doctor       check the installation
EOF
