#!/usr/bin/env bash
# Drives scripts/ddar-popup through real scenarios with fake rofi/nmcli/pactl/
# playerctl/powerprofilesctl (tests/fakes) and checks the commands it runs.
# Nothing on the system is changed. Usage: tests/popups.sh
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX" PATH="$ROOT/tests/fakes:$PATH" WAYLAND_DISPLAY=ddar-test NO_COLOR=1
export XDG_RUNTIME_DIR="$SANDBOX/run" FAKE_LOG="$SANDBOX/rofi.log" FAKE_CMDS="$SANDBOX/cmds.log" FAKE_STATE="$SANDBOX/rofi.state"
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME HYPRLAND_INSTANCE_SIGNATURE
mkdir -p "$XDG_RUNTIME_DIR"
"$ROOT/bin/ddar" generate >/dev/null 2>&1
pass=0; fail=0

# popup NAME "PICKS"
popup() {
    : >"$FAKE_LOG"; : >"$FAKE_CMDS"; rm -f "$FAKE_STATE"
    ROFI_PICKS="$2" timeout 10 "$ROOT/scripts/ddar-popup" "$1" >/dev/null 2>"$SANDBOX/stderr"
    return 0
}
expect() { # expect "description" FILE fixed-string
    if grep -qF -- "$3" "$2"; then pass=$((pass + 1)); printf 'ok   %s\n' "$1"
    else fail=$((fail + 1)); printf 'FAIL %s\n     expected: %s\n' "$1" "$3"; sed 's/^/     | /' "$2" | tail -n 6; fi
}
no_stderr() {
    if [[ ! -s "$SANDBOX/stderr" ]]; then pass=$((pass + 1)); printf 'ok   %s: no errors\n' "$1"
    else fail=$((fail + 1)); printf 'FAIL %s printed errors:\n' "$1"; sed 's/^/     | /' "$SANDBOX/stderr"; fi
}

popup network "3"
expect "network: SSID with ':' is unescaped in the status" "$FAKE_LOG" "<b>Network  </b> Home:Net"
expect "network: duplicate SSIDs are listed once" "$FAKE_LOG" "Cafe Free             55%"
expect "network: secured network asks for a password" "$FAKE_CMDS" "nmcli device wifi connect Cafe Free password secretpw"
no_stderr network
popup network "2"
expect "network: saved network is brought up by name" "$FAKE_CMDS" "nmcli connection up id Home:Net"
popup network "4"
expect "network: open network connects without password" "$FAKE_CMDS" "nmcli device wifi connect OpenSpot"
popup network "0"
expect "network: Wi-Fi toggle" "$FAKE_CMDS" "nmcli radio wifi off"
popup network "5"
expect "network: disconnect" "$FAKE_CMDS" "nmcli device disconnect wlan0"

popup audio "1 9"
expect "audio: volume bar is 10 cells" "$FAKE_LOG" "<tt>[████░░░░░░]</tt>"
expect "audio: +5%" "$FAKE_CMDS" "pactl set-sink-volume @DEFAULT_SINK@ +5%"
expect "audio: switch output device" "$FAKE_CMDS" "pactl set-default-sink bluez_output.AA"
no_stderr audio

popup power "0"
expect "power: set power profile" "$FAKE_CMDS" "powerprofilesctl set performance"
popup power "7 0"
expect "power: shutdown after confirmation" "$FAKE_CMDS" "systemctl poweroff"
popup power "6 1"
if grep -q reboot "$FAKE_CMDS"; then fail=$((fail + 1)); echo "FAIL power: reboot ran although cancelled"
else pass=$((pass + 1)); echo "ok   power: cancelled reboot does nothing"; fi

popup media "0 5"
expect "media: markup in titles is escaped" "$FAKE_LOG" "Something &lt;About&gt; Us &amp; More"
expect "media: play/pause" "$FAKE_CMDS" "playerctl -p spotify play-pause"
no_stderr media

popup session "4 0"
expect "power dialog: shut down after confirmation" "$FAKE_CMDS" "systemctl poweroff"
popup session "3 1"
if grep -q reboot "$FAKE_CMDS"; then fail=$((fail + 1)); echo "FAIL power dialog: reboot ran although cancelled"
else pass=$((pass + 1)); echo "ok   power dialog: cancelled reboot does nothing"; fi
popup session "1 0"
expect "power dialog: log out" "$FAKE_CMDS" "hyprctl dispatch exit"
popup session "0"
expect "power dialog: lock uses the DDAR hyprlock config" "$FAKE_CMDS" "hyprlock -c $HOME/.local/state/ddar/hyprlock/hyprlock.conf"
expect "power dialog: five buttons" "$FAKE_LOG" "Shut down|"

"$ROOT/bin/ddar" config set WALLPAPER_BACKEND dms >/dev/null
popup wallpapers "0"
expect "wallpaper picker: rows carry a preview image" "$FAKE_LOG" "icon"
expect "wallpaper picker: sets the wallpaper through DMS" "$FAKE_CMDS" "dms ipc call wallpaper set "
popup menu "10"
expect "DDAR menu: lock screen entry" "$FAKE_CMDS" "hyprlock -c"

popup calendar "ESC"
no_stderr calendar
popup system "ESC"
no_stderr system

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
