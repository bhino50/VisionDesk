#!/usr/bin/env bash
# Startup preflight and packaging-retention helpers.
#
# Sourced by script/build_and_run.sh and script/build_vision.sh, and exercised directly by
# script/test_startup.sh against isolated fixture directories. Keeping these in one sourceable
# file is what lets the retention and preflight rules be tested without compiling, signing or
# launching anything, and without touching a real backup.
#
# Signing identities are credential selectors. visiondesk_read_signing_identity returns the
# value on stdout for the caller to pass to codesign and never writes it to a message; the
# guidance text names the input instead. Callers must preserve that.
#
# Nothing here changes the machine's selected toolchain: the developer directory is only ever
# read, never set.

# Resolves the developer directory for this run.
#
# Usage: visiondesk_resolve_developer_dir [any|full-xcode]
#
# Echoes the resolved directory on success. On failure it prints operator guidance to stderr
# and returns 1. An unset or failed lookup resolves to the empty string rather than silently
# producing a relative path, so a caller that appends `usr/bin/xcodebuild` cannot end up
# invoking the `/usr/bin` xcrun shim and reporting the shim's error instead of this one.
visiondesk_resolve_developer_dir() {
    local requirement="${1:-any}"
    local resolved="${DEVELOPER_DIR:-}"
    if [[ -z "$resolved" ]]; then
        # Read-only query. This deliberately never runs `xcode-select --switch`.
        resolved="$(xcode-select -p 2>/dev/null)" || resolved=""
    fi
    if [[ -z "$resolved" ]]; then
        echo "No developer directory is selected. Set DEVELOPER_DIR to an Xcode installation." >&2
        return 1
    fi
    if [[ ! -d "$resolved" ]]; then
        echo "DEVELOPER_DIR is not an existing directory. Set it to an Xcode installation." >&2
        return 1
    fi
    if [[ "$requirement" == "full-xcode" && ! -x "$resolved/usr/bin/xcodebuild" ]]; then
        echo "Set DEVELOPER_DIR to a full Xcode installation with visionOS support." >&2
        return 1
    fi
    printf '%s\n' "$resolved"
}

# Loads the Mac signing identity from the environment or the configured file.
#
# Usage: visiondesk_read_signing_identity <identity-file>
#
# Surrounding whitespace is trimmed so a file ending in spaces or holding only a blank line is
# rejected with guidance instead of reaching `codesign --sign " "`. A value spanning more than
# one line is ambiguous and is also rejected. The identity itself is never printed to stderr.
visiondesk_read_signing_identity() {
    local identity_file="$1"
    local identity="${VISION_DESK_SIGNING_IDENTITY:-}"
    local origin="VISION_DESK_SIGNING_IDENTITY"
    if [[ -z "$identity" && -f "$identity_file" ]]; then
        identity="$(<"$identity_file")"
        origin="$identity_file"
    fi
    identity="${identity//$'\r'/}"
    # Leftmost-longest matching assigns the capture the span between the first and last
    # non-whitespace characters, which trims spaces, tabs and newlines at both ends.
    if [[ "$identity" =~ ^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
        identity="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$identity" ]]; then
        echo "Set VISION_DESK_SIGNING_IDENTITY or $identity_file to an existing stable signing identity." >&2
        echo "Explicit '-' selects ad-hoc signing, which may require permissions again after rebuilding." >&2
        return 1
    fi
    if [[ "$identity" == *$'\n'* ]]; then
        echo "The signing identity from $origin spans more than one line. Use a single identity." >&2
        return 1
    fi
    printf '%s\n' "$identity"
}

# Releases a staging directory at script exit.
#
# Usage: visiondesk_release_staging <staging-dir> <staged-bundle> [exit-status] [verified]
#
# A staged bundle that outlived a failure is the operator's recoverable candidate, so it is
# kept and its path reported. An empty or already-moved staging directory is removed, which
# the previous `rmdir` could not do once the bundle existed. Removal is limited to directories
# carrying the generated `app-stage.` prefix.
#
# The trap is installed before the bundle is copied, signed and verified, so existence alone
# does not mean the bundle is usable. Callers raise `verified` only after `codesign --verify`
# succeeds; until then the bundle is described in neutral terms rather than as a signed build.
visiondesk_release_staging() {
    local staging_dir="$1" staged_bundle="$2" status="${3:-0}" verified="${4:-0}"
    if [[ -e "$staged_bundle" ]]; then
        if ((status != 0)); then
            if ((verified != 0)); then
                echo "Preserved signed build: $staged_bundle" >&2
            else
                echo "Preserved an unverified staged bundle: $staged_bundle" >&2
            fi
        fi
        return 0
    fi
    case "${staging_dir##*/}" in
        app-stage.?*) rm -rf "$staging_dir" ;;
    esac
}

# Installs a staged bundle, keeping the bundle it replaces recoverable.
#
# Usage: visiondesk_install_bundle <staged-bundle> <app-bundle> <dist-dir> <app-name> [keep]
#
# The installed bundle is moved aside first so the destination is free, then the staged bundle
# is moved into place. If that second move fails the previous bundle is restored: leaving the
# destination empty would uninstall a working companion. Retention runs only after a
# successful install, because pruning earlier would discard recoverable copies at exactly the
# moment no companion is installed. When the restore itself fails, both the backup and the
# staged path are printed, since neither is discoverable from the destination.
visiondesk_install_bundle() {
    local staged="$1" app_bundle="$2" dist_dir="$3" app_name="$4" keep="${5:-3}"
    local backup_dir="" backup=""
    if [[ -e "$app_bundle" ]]; then
        backup_dir="$(mktemp -d "$dist_dir/previous.XXXXXX")"
        # Keep a recoverable bundle without registering another runnable app with the same ID.
        backup="$backup_dir/$app_name.app.backup"
        if ! mv "$app_bundle" "$backup"; then
            rmdir "$backup_dir" 2>/dev/null || true
            echo "Could not move the installed companion aside. It is still installed." >&2
            return 1
        fi
    fi
    if mv "$staged" "$app_bundle"; then
        # The policy bounds the recoverable copies that exist, not only the one this run
        # added: a first install into a dist that already carries backups still prunes to
        # `keep`. Retention is a no-op when there are none.
        visiondesk_retain_recent_backups "$dist_dir" "$app_name" "$keep"
        return 0
    fi
    if [[ -z "$backup" ]]; then
        echo "Installing the new companion failed. Nothing was replaced." >&2
        return 1
    fi
    if mv "$backup" "$app_bundle"; then
        rmdir "$backup_dir" 2>/dev/null || true
        echo "Installing the new companion failed; the previous one was restored." >&2
        return 1
    fi
    echo "Installing the new companion failed and the previous one could not be restored." >&2
    echo "Previous companion: $backup" >&2
    echo "Staged build: $staged" >&2
    return 1
}

# Removes staging directories abandoned by earlier runs.
#
# Usage: visiondesk_prune_stage_dirs <stage-root> [keep-dir]
#
# Call this only once a newer bundle has been signed and verified: that bundle supersedes any
# earlier candidate, and keep-dir is never removed, so every run still leaves one actionable
# path. Only directories named `app-stage.*` directly under stage-root are considered.
visiondesk_prune_stage_dirs() {
    local stage_root="$1" keep_dir="${2:-}" dir
    for dir in "$stage_root"/app-stage.*; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi
        # `-ef` compares device and inode, so a caller passing an equivalent spelling of the
        # current candidate — a trailing slash, a `./` segment, a symlinked parent — still
        # keeps it instead of having it pruned by a failed string comparison.
        if [[ -n "$keep_dir" ]] && { [[ "$dir" == "$keep_dir" ]] || [[ "$dir" -ef "$keep_dir" ]]; }; then
            continue
        fi
        case "${dir##*/}" in
            app-stage.?*) rm -rf "$dir" ;;
        esac
    done
}

# Bounds the recoverable backups this script created.
#
# Usage: visiondesk_retain_recent_backups <dist-dir> <app-name> [keep]
#
# Keeps the newest `keep` backups by modification time and removes the rest. A directory is
# only a candidate when its name carries the generated `previous.` prefix *and* it contains
# the expected `<app-name>.app.backup`, so an unrelated dist path is never removed.
visiondesk_retain_recent_backups() {
    local dist_dir="$1" app_name="$2" keep="${3:-3}" dir path index=0 stamp
    local -a owned=()
    for dir in "$dist_dir"/previous.*; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi
        if [[ ! -e "$dir/$app_name.app.backup" ]]; then
            continue
        fi
        owned+=("$dir")
    done
    if ((${#owned[@]} <= keep)); then
        return 0
    fi
    # Newest first. `%N` reproduces the path as passed, and reading the remainder of the line
    # into one variable keeps paths containing spaces intact.
    while IFS=' ' read -r stamp path; do
        index=$((index + 1))
        if ((index <= keep)); then
            continue
        fi
        case "${path##*/}" in
            previous.?*) rm -rf "$path" ;;
        esac
    done < <(stat -f '%m %N' "${owned[@]}" | sort -rn)
}
