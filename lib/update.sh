# shellcheck shell=bash disable=SC2034  # DDAR_ASSUME_YES is read by confirm()
# ddar update: fast-forward the DDAR git checkout. Never resets, stashes or
# force-pulls; user settings live in ~/.config/ddar and are not touched.

ddar_update() {
    local check_only=0 arg branch upstream ahead behind
    for arg in "$@"; do
        case "$arg" in
            --check) check_only=1 ;;
            -y|--yes) DDAR_ASSUME_YES=1 ;;
            *) die "Usage: ddar update [--check] [--yes]" ;;
        esac
    done
    have git || die "git is not installed"
    if ! git -C "$DDAR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "DDAR at $DDAR_ROOT is not a git checkout. Re-install from a clone to enable updates."
    fi
    branch="$(git -C "$DDAR_ROOT" symbolic-ref --quiet --short HEAD)" ||
        die "The DDAR checkout is on a detached HEAD; check out a branch first."
    upstream="$(git -C "$DDAR_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" ||
        die "Branch '$branch' has no upstream. Set one with: git -C '$DDAR_ROOT' branch -u origin/$branch"

    info "Checking $upstream for updates"
    git -C "$DDAR_ROOT" fetch --quiet "${upstream%%/*}" || die "git fetch failed (network?)"
    read -r ahead behind < <(git -C "$DDAR_ROOT" rev-list --left-right --count "HEAD...$upstream")

    if ((behind == 0)); then
        ok "DDAR is up to date ($(git -C "$DDAR_ROOT" rev-parse --short HEAD) on $branch)"
        ((ahead > 0)) && msg "${C_DIM}(your checkout has $ahead local commit(s) not on $upstream)${C_RESET}"
        return 0
    fi

    msg ""
    msg "${C_BOLD}$behind new commit(s) on $upstream:${C_RESET}"
    git -C "$DDAR_ROOT" --no-pager log --oneline --no-decorate "HEAD..$upstream"
    msg ""
    git -C "$DDAR_ROOT" --no-pager diff --stat "HEAD...$upstream" | tail -n 15
    msg ""
    ((check_only)) && return 0

    if ((ahead > 0)); then
        warn "Your checkout has $ahead local commit(s); a fast-forward is impossible."
        die "Merge or rebase manually in $DDAR_ROOT - DDAR will not rewrite your history."
    fi
    if [[ -n "$(git -C "$DDAR_ROOT" status --porcelain --untracked-files=no)" ]]; then
        git -C "$DDAR_ROOT" status --short --untracked-files=no
        die "Files in $DDAR_ROOT were modified. Commit or stash them yourself, then re-run 'ddar update'. (Your settings belong in ~/.config/ddar.)"
    fi
    confirm "Apply the update?" y || { msg "Update cancelled."; return 0; }
    git -C "$DDAR_ROOT" merge --ff-only --quiet "$upstream" || die "Fast-forward failed; nothing was changed."
    ok "Updated to $(git -C "$DDAR_ROOT" rev-parse --short HEAD)"
    info "Regenerating configs"
    # Run the *new* code for the reload.
    "$DDAR_ROOT/bin/ddar" run
}
