# shellcheck shell=bash
# DDAR wallpapers: listing, selection and applying through a detected backend.

WP_EXT_RE='\.(png|jpe?g|webp)$'

wallpaper_dir() { expand_path "$(cfg WALLPAPER_DIR)"; }

# All candidate wallpapers: user directory first (plus the folder of the
# wallpaper DankMaterialShell shows), then bundled ones.
wallpaper_list() {
    local dir dmsdir="" d
    dir="$(wallpaper_dir)"
    d="$(dms_wallpaper 2>/dev/null)" && dmsdir="$(dirname "$d")"
    {
        for d in "$dir" "$dmsdir"; do
            [[ -n "$d" && -d "$d" ]] && find -L "$d" -maxdepth 2 -type f -printf '%p\n' 2>/dev/null | grep -iE "$WP_EXT_RE" | sort
        done
        find "$DDAR_ROOT/assets/wallpapers" -maxdepth 1 -type f -printf '%p\n' 2>/dev/null | grep -iE "$WP_EXT_RE" | sort
    } | awk '!seen[$0]++'
}

wallpaper_current() {
    local w
    if [[ "$(wallpaper_backend)" == dms ]] && w="$(dms_wallpaper)"; then printf '%s' "$w"; return; fi
    w="$(expand_path "$(cfg WALLPAPER)")"
    if [[ -n "$w" && -r "$w" ]]; then printf '%s' "$w"
    else printf '%s' "$DDAR_ROOT/assets/wallpapers/ddar-teal.png"; fi
}

# Prints the name of a running desktop shell that manages its own wallpaper.
desktop_shell_running() {
    local p
    for p in dms quickshell qs; do pgrep -x "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }; done
    return 1
}

wallpaper_backend() {
    local b; b="$(cfg WALLPAPER_BACKEND)"
    if [[ "$b" == auto ]]; then
        # DankMaterialShell draws the wallpaper itself: set it through DMS.
        # Other desktop shells do the same with no known interface: leave
        # them alone, a second wallpaper program would cover theirs.
        if have dms && desktop_shell_running >/dev/null; then echo dms; return; fi
        desktop_shell_running >/dev/null && { echo none; return; }
        for b in awww swww swaybg hyprpaper; do have "$b" && { echo "$b"; return; }; done
        echo none; return
    fi
    if [[ "$b" == dms ]] && ! have dms; then warn "WALLPAPER_BACKEND=dms but the dms command is not installed"; echo none; return; fi
    if [[ "$b" != none ]] && ! have "$b"; then warn "WALLPAPER_BACKEND=$b but '$b' is not installed"; echo none; return; fi
    echo "$b"
}

# Wait (max ~2s) until a command succeeds.
_wait_for() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done; return 1; }

# Draw the wallpaper. Only acts inside a Wayland session.
wallpaper_apply() {
    local f="${1:-$(wallpaper_current)}" b old
    in_wayland || return 0
    b="$(wallpaper_backend)"
    case "$b" in
        awww|swww)
            pgrep -x "$b-daemon" >/dev/null || spawn "$b-daemon"
            _wait_for "$b" query || { warn "$b-daemon did not start"; return 1; }
            "$b" img "$f" >/dev/null 2>&1 || warn "$b could not set $f"
            ;;
        swaybg)
            # Start the new instance first, then retire old ones: no blank flash.
            old="$(pgrep -x swaybg | tr '\n' ' ')"
            spawn swaybg -m fill -i "$f"
            sleep 0.3
            # shellcheck disable=SC2086
            [[ -n "$old" ]] && kill $old 2>/dev/null
            ;;
        hyprpaper)
            in_hyprland || return 0
            pgrep -x hyprpaper >/dev/null || spawn hyprpaper
            _wait_for hyprctl hyprpaper listloaded || _wait_for pgrep -x hyprpaper
            # hyprpaper < 0.8 needs preload first; >= 0.8 ignores/rejects it.
            hyprctl hyprpaper preload "$f" >/dev/null 2>&1 || true
            hyprctl hyprpaper wallpaper ",$f" >/dev/null 2>&1 || warn "hyprpaper could not set $f"
            ;;
        dms)
            timeout 5 dms ipc call wallpaper set "$f" >/dev/null 2>&1 || warn "DankMaterialShell did not accept the wallpaper (dms ipc call wallpaper set)"
            ;;
        none) ;;
    esac
}

wallpaper_set() {
    local f="$1"
    [[ -n "$f" ]] || die "Usage: ddar wallpaper set <file>"
    f="$(expand_path "$f")"
    [[ -f "$f" && -r "$f" ]] || die "Not a readable file: $f"
    [[ "${f,,}" =~ $WP_EXT_RE ]] || die "Unsupported image type (use png, jpg or webp): $f"
    f="$(realpath -- "$f")"
    config_set WALLPAPER "$f"
    wallpaper_apply "$f"
    ok "Wallpaper: $f"
    if [[ "$(wallpaper_backend)" == none ]]; then
        msg "${C_DIM}DDAR does not draw wallpapers here (WALLPAPER_BACKEND=$(cfg WALLPAPER_BACKEND)$(desktop_shell_running >/dev/null && echo ', desktop shell detected')); the image is only used for colours.${C_RESET}"
    fi
    if [[ "$(cfg MATUGEN)" != off ]]; then
        if have matugen; then
            info "Regenerating colours from the wallpaper (MATUGEN=$(cfg MATUGEN))"
            ddar_apply_theme_change
        else
            msg "${C_DIM}Tip: install matugen to derive colours from the wallpaper.${C_RESET}"
        fi
    fi
}

# Step through the list: $1 = +1 or -1
wallpaper_step() {
    local step="$1" cur i n
    local -a list
    mapfile -t list < <(wallpaper_list)
    n=${#list[@]}
    ((n)) || die "No wallpapers found in $(wallpaper_dir) or the bundled set"
    cur="$(wallpaper_current)"
    for ((i = 0; i < n; i++)); do [[ "${list[i]}" == "$cur" ]] && break; done
    ((i == n)) && i=-1
    wallpaper_set "${list[$(( (i + step + n) % n ))]}"
}

wallpaper_random() {
    local -a list; mapfile -t list < <(wallpaper_list)
    ((${#list[@]})) || die "No wallpapers found"
    wallpaper_set "${list[RANDOM % ${#list[@]}]}"
}

# Cached preview image for the picker (ImageMagick); the original file is
# used when ImageMagick is missing. Cache key: path + modification time.
wallpaper_thumb() {
    local f="$1" key thumb tool=""
    have magick && tool=magick
    [[ -z "$tool" ]] && have convert && tool=convert
    [[ -n "$tool" ]] || { printf '%s' "$f"; return; }
    key="$(printf '%s %s' "$f" "$(stat -c %Y "$f" 2>/dev/null)" | cksum | cut -d' ' -f1)"
    thumb="$DDAR_CACHE_DIR/thumbs/$key.png"
    if [[ ! -s "$thumb" ]]; then
        mkdir -p "$DDAR_CACHE_DIR/thumbs"
        "$tool" "${f}[0]" -thumbnail '192x108^' -gravity center -extent 192x108 "$thumb" 2>/dev/null || { printf '%s' "$f"; return; }
    fi
    printf '%s' "$thumb"
}

# Interactive picker: rofi inside a session, numbered list in a terminal.
wallpaper_pick() {
    local -a list; local choice i
    mapfile -t list < <(wallpaper_list)
    ((${#list[@]})) || die "No wallpapers found. Put images in $(wallpaper_dir)"
    if [[ ! -t 0 ]] && in_wayland && have rofi; then
        "$DDAR_SCRIPTS/ddar-popup" wallpapers
        return
    fi
    msg "Current: $(wallpaper_current)"
    for i in "${!list[@]}"; do printf '%3d) %s\n' "$((i + 1))" "${list[i]/#$HOME/\~}"; done
    read -r -p "Number (Enter = cancel): " choice || return 0
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#list[@]})); then msg "Cancelled."; return 0; fi
    wallpaper_set "${list[choice-1]}"
}
