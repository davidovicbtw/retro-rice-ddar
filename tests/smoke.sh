#!/usr/bin/env bash
# shellcheck disable=SC2016  # the bash -c snippets expand their own "$0"/"$1"
# DDAR smoke tests: run in a throw-away $HOME, need only bash, jq and coreutils
# (shellcheck and rofi are used when installed). Does not touch your real
# configuration and does not need a running Hyprland.
#   tests/smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX" NO_COLOR=1
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
DDAR="$ROOT/bin/ddar"
pass=0; fail=0

t() { # t "description" command...
    local name="$1"; shift
    if "$@" >"$SANDBOX/out" 2>&1; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; sed 's/^/     /' "$SANDBOX/out" | tail -n 8; fi
}
not() { ! "$@"; }
gen() { "$ROOT/bin/ddar" generate; }
G="$SANDBOX/.local/state/ddar"
H="$SANDBOX/.config/hypr/ddar"

# --- static checks ---------------------------------------------------------
t "bash syntax" bash -c 'for f in "$0"/bin/ddar "$0"/scripts/* "$0"/lib/*.sh "$0"/install.sh "$0"/uninstall.sh "$0"/tests/*.sh; do bash -n "$f" || exit 1; done' "$ROOT"
if command -v shellcheck >/dev/null; then
    t "shellcheck" bash -c 'cd "$0" && shellcheck -x -S style bin/ddar scripts/* lib/*.sh install.sh uninstall.sh tests/*.sh' "$ROOT"
fi
t "waybar module template is valid JSON" jq empty "$ROOT/templates/waybar/modules.json"
t "executables are executable" bash -c 'for f in "$0"/bin/ddar "$0"/scripts/* "$0"/install.sh "$0"/uninstall.sh; do [[ -x "$f" ]] || { echo "$f"; exit 1; }; done' "$ROOT"

# --- generation --------------------------------------------------------------
for theme in $("$DDAR" theme list | sed 's/^\*//' | awk '{print $1}'); do
    t "theme $theme generates" bash -c '"$0" theme set "$1" && jq empty "$2/waybar/config.jsonc"' "$DDAR" "$theme" "$G"
done
t "no unrendered @@tokens" not grep -rl "@@" "$G" "$H"
t "hyprland snippets have balanced braces" bash -c 'for f in "$0"/*.conf; do awk "/\\{\$/{d++} /^[[:space:]]*\\}/{d--} END{exit d!=0}" "$f" || { echo "$f"; exit 1; }; done' "$H"
for style in list grid compact spotlight; do
    t "launcher style $style" bash -c '"$0" config set LAUNCHER_STYLE "$1" && "$0" generate && grep -qE "@import|window" "$2/rofi/launcher.rasi"' "$DDAR" "$style" "$G"
done
if command -v rofi >/dev/null && [[ -n "${DISPLAY:-}" ]]; then
    t "rofi parses launcher theme" bash -c '! rofi -theme "$0/rofi/launcher.rasi" -dump-theme 2>&1 | grep -q "Failed to parse"' "$G"
    t "rofi parses popup theme" bash -c '! rofi -theme "$0/rofi/popup.rasi" -dump-theme 2>&1 | grep -q "Failed to parse"' "$G"
fi

# The standalone copies in extras/ must match what the generator produces.
for pair in "retro:spotlight" "dark-retro:spotlight-dark"; do
    t "extras/rofi/themes/${pair#*:}.rasi is up to date" bash -c '
        h="$(mktemp -d)"; export HOME="$h"
        "$0" config set THEME "$1" && "$0" config set MATUGEN off && "$0" config set LAUNCHER_STYLE spotlight && "$0" generate &&
        diff -u "$2" "$h/.local/state/ddar/rofi/launcher.rasi"' "$DDAR" "${pair%%:*}" "$ROOT/extras/rofi/themes/${pair#*:}.rasi"
done

# --- themes and Matugen (fake matugen/dms from tests/fakes) ------------------
FAKES="$ROOT/tests/fakes"
DUSK="$ROOT/assets/wallpapers/ddar-dusk.png"
t "palette themes keep their official accent" bash -c '
    PATH="$3:$PATH"; "$0" config set THEME catppuccin && "$0" config set MATUGEN accent &&
    "$0" config set WALLPAPER "$4" && "$0" generate && grep -qx "accent=#cba6f7" "$1/palette.env"' "$DDAR" "$G" "" "$FAKES" "$DUSK"
t "retro (light) themes take the light Matugen accent" bash -c '
    PATH="$2:$PATH"; "$0" config set THEME retro && "$0" generate && grep -qx "accent=#8e4954" "$1/palette.env" && grep -qx "source=matugen (accent)" "$1/palette.env"' "$DDAR" "$G" "$FAKES"
t "dynamic uses the full Matugen palette" bash -c '
    PATH="$2:$PATH"; "$0" config set THEME dynamic && "$0" config set MATUGEN off && "$0" generate &&
    grep -qx "source=matugen (full)" "$1/palette.env" && grep -qx "face=#261d1e" "$1/palette.env"' "$DDAR" "$G" "$FAKES"
t "dynamic follows the DMS wallpaper (IPC)" bash -c '
    PATH="$2:$PATH" FAKE_DMS_WALLPAPER="$3" "$0" generate && grep -qx "wallpaper=$3" "$1/palette.env"' "$DDAR" "$G" "$FAKES" "$ROOT/assets/wallpapers/ddar-slate.png"
mkdir -p "$SANDBOX/.local/state/DankMaterialShell"
printf '{"wallpaperPath": "%s"}\n' "$ROOT/assets/wallpapers/ddar-teal.png" >"$SANDBOX/.local/state/DankMaterialShell/session.json"
t "dynamic falls back to DMS session.json" bash -c '
    PATH="$2:$PATH" FAKE_DMS_WALLPAPER="not a file" "$0" generate && grep -qx "wallpaper=$3" "$1/palette.env"' "$DDAR" "$G" "$FAKES" "$ROOT/assets/wallpapers/ddar-teal.png"
t "dynamic without matugen keeps its fallback colours" bash -c '
    PATH="$(printf "%s" "$PATH" | tr ":" "\n" | grep -v cargo | paste -sd:)"; command -v matugen && exit 1
    "$0" generate 2>&1 | grep -q "needs matugen" && grep -qx "source=theme" "$1/palette.env"' "$DDAR" "$G"
"$DDAR" config set THEME retro >/dev/null 2>&1; "$DDAR" config set WALLPAPER "" >/dev/null 2>&1; "$DDAR" config set MATUGEN accent >/dev/null 2>&1

# --- lock screen and title bars ----------------------------------------------
t "hyprlock config is generated with balanced blocks" bash -c '
    f="$0/hyprlock/hyprlock.conf"; [[ -s "$f" ]] && ! grep -q "@@" "$f" &&
    awk "/\{\$/{d++} /^[[:space:]]*\}/{d--} END{exit d!=0}" "$f" && grep -q "^input-field {" "$f"' "$G"
t "title bars off by default (no plugin config)" bash -c '! grep -q "hyprbars" "$0/titlebars.conf"' "$H"
t "title bars: floating generates the no-bar rule" bash -c '
    "$0" config set TITLEBARS floating && "$0" generate && grep -q "hyprbars-button" "$1/titlebars.conf" &&
    grep -q "match:float = 0" "$1/titlebars-rules.conf"' "$DDAR" "$H"
t "title bars: all has no rule" bash -c '"$0" config set TITLEBARS all && "$0" generate && ! grep -q "match:float" "$1/titlebars-rules.conf"' "$DDAR" "$H"
t "ddar titlebars refuses without the plugin" not "$DDAR" titlebars on
"$DDAR" config set TITLEBARS off >/dev/null 2>&1; "$DDAR" generate >/dev/null 2>&1

# --- configuration -----------------------------------------------------------
t "config rejects out-of-range values" not "$DDAR" config set FONT_SIZE 99
t "config rejects unknown modules" not "$DDAR" config set BAR_RIGHT "cpu nonsense"
t "config rejects shell metacharacters" not "$DDAR" config set CLOCK_FORMAT '$(id)'
t "config accepts valid accent" "$DDAR" config set ACCENT '#aa5500'
t "accent override reaches palette" bash -c '"$0" generate && grep -qx "accent=#aa5500" "$1/palette.env"' "$DDAR" "$G"
echo 'THEME="$(touch '"$SANDBOX"'/pwned)"' >>"$SANDBOX/.config/ddar/ddar.conf"
t "config file is parsed, never executed" bash -c '"$0" config get THEME >/dev/null; [[ ! -e "$1/pwned" ]]' "$DDAR" "$SANDBOX"
"$DDAR" config set ACCENT auto >/dev/null 2>&1
t "clock with seconds ticks every second" bash -c '"$0" config set CLOCK_FORMAT "%H:%M:%S" && "$0" generate && jq -e ".clock.interval == 1" "$1/waybar/config.jsonc"' "$DDAR" "$G"
t "disabled widget leaves the bar" bash -c '"$0" config set WIDGETS "ddar workspaces clock" && "$0" generate && jq -e "(.\"modules-right\" | index(\"cpu\")) == null" "$1/waybar/config.jsonc"' "$DDAR" "$G"

# --- shortcuts ---------------------------------------------------------------
t "shortcut add" "$DDAR" shortcut add SUPER+SHIFT+B firefox
t "shortcut becomes a bind" grep -qx 'bind = SUPER SHIFT, B, exec, firefox' "$H/shortcuts.conf"
t "dispatcher shortcut" bash -c '"$0" shortcut add SUPER+ALT+3 @workspace 3 && grep -qx "bind = SUPER ALT, 3, workspace, 3" "$1/shortcuts.conf"' "$DDAR" "$H"
t "'#' is escaped for hyprland" bash -c '"$0" shortcut add CTRL+F1 "echo a#b" && grep -qF "echo a##b" "$1/shortcuts.conf"' "$DDAR" "$H"
t "ddar commands get an absolute path" grep -qF "exec, $ROOT/bin/ddar launcher" "$H/shortcuts.conf"
t "duplicate shortcut rejected" not "$DDAR" shortcut add shift+super+b chromium
t "missing key rejected" not "$DDAR" shortcut add SUPER+ foo
t "unknown modifier rejected" not "$DDAR" shortcut add HYPER+X foo
t "shortcut remove by combo" bash -c '"$0" shortcut remove SUPER+SHIFT+B && ! grep -q "firefox" "$1/shortcuts.conf"' "$DDAR" "$H"
t "shortcut check passes" "$DDAR" shortcut check

# --- wallpapers ----------------------------------------------------------------
t "bundled wallpapers listed" bash -c '[[ $("$0" wallpaper list | wc -l) -ge 3 ]]' "$DDAR"
t "wallpaper next cycles" bash -c '"$0" config set MATUGEN off && a=$("$0" wallpaper current) && "$0" wallpaper next && [[ "$("$0" wallpaper current)" != "$a" ]]' "$DDAR"
t "wallpaper set rejects non-images" not "$DDAR" wallpaper set "$ROOT/README.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
