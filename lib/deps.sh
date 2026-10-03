# shellcheck shell=bash
# Dependency table shared by install.sh and `ddar doctor`.
# command|arch package|level|purpose      level: required | recommended | optional
DDAR_DEPS=(
"hyprctl|hyprland|required|the compositor DDAR integrates with"
"waybar|waybar|required|the top bar"
"rofi|rofi|required|launcher, DDAR menu and bar popups (rofi >= 2.0 has Wayland support)"
"jq|jq|required|config generation"
"flock|util-linux|required|run locking"
"pgrep|procps-ng|required|process detection"
"kitty|kitty|recommended|terminal (themed); any terminal works for popups"
"matugen|matugen|recommended|wallpaper-based colours"
"mako|mako|recommended|themed notifications"
"notify-send|libnotify|recommended|desktop notifications from ddar"
"playerctl|playerctl|recommended|media controls"
"pactl|libpulse|recommended|audio popup (works with PipeWire via pipewire-pulse)"
"nmcli|networkmanager|recommended|Wi-Fi popup"
"awww|awww|recommended|wallpaper daemon (alternatives: swaybg, hyprpaper)"
"git|git|recommended|ddar update"
"powerprofilesctl|power-profiles-daemon|optional|power profiles in the battery popup"
"brightnessctl|brightnessctl|optional|backlight widget"
"curl|curl|optional|weather widget"
"pavucontrol|pavucontrol|optional|full audio mixer from the audio popup"
"btop|btop|optional|process viewer from the system popup"
"hyprlock|hyprlock|recommended|the DDAR lock screen (ddar lock)"
"magick|imagemagick|optional|wallpaper previews in the picker"
"inotifywait|inotify-tools|optional|theme 'dynamic' follows DankMaterialShell wallpaper changes live"
)

# Fonts are packages, not commands: fc-list check.
DDAR_FONT_PKGS="noto-fonts ttf-dejavu"

# deps_check LEVEL -> prints missing "cmd|pkg|purpose" lines for that level.
deps_missing() {
    local level="$1" row cmd pkg lvl purpose
    for row in "${DDAR_DEPS[@]}"; do
        IFS='|' read -r cmd pkg lvl purpose <<<"$row"
        [[ "$lvl" == "$level" ]] || continue
        if [[ "$cmd" == awww ]]; then
            have awww || have swww || have swaybg || have hyprpaper || echo "$cmd|$pkg|$purpose"
            continue
        fi
        have "$cmd" || echo "$cmd|$pkg|$purpose"
    done
}

deps_report() {
    local level line cmd pkg purpose missing_req=0
    for level in required recommended optional; do
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            IFS='|' read -r cmd pkg purpose <<<"$line"
            case "$level" in
                required) err "missing  $cmd ($pkg) - $purpose"; missing_req=1 ;;
                recommended) warn "missing  $cmd ($pkg) - $purpose" ;;
                optional) msg "${C_DIM}[ -- ] optional $cmd ($pkg) - $purpose${C_RESET}" ;;
            esac
        done < <(deps_missing "$level")
    done
    if have fc-list && ! fc-list : family 2>/dev/null | grep -iE 'DejaVu|Noto Sans' >/dev/null; then
        warn "No DejaVu/Noto fonts found ($DDAR_FONT_PKGS) - text may fall back to a default font"
    fi
    return "$missing_req"
}
