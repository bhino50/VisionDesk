#!/usr/bin/env bash
# Startup, preflight and packaging-retention regression checks.
#
# Covers the three startup entry points: script/build_and_run.sh, script/build_vision.sh and
# script/generate_xcode_project.py, plus the shared helpers in script/lib/startup_preflight.sh.
#
# What it deliberately does not do:
#   * compile anything, open a network connection, launch an app or run codesign
#   * read the real signing configuration — every invocation points
#     VISION_DESK_SIGNING_IDENTITY_FILE at a fixture under a temporary directory
#   * change the machine's selected toolchain — `xcode-select` is only ever read, and one
#     check asserts the resolver never asks it to switch
#   * remove a real backup or staging directory — retention runs against fixture trees, one
#     of which has a space in its path to match the real checkout
#
# build_and_run.sh and build_vision.sh are only invoked for negative preflight cases, which
# exit before `swift build` and before project generation. Each such check also asserts that
# no staging directory appeared and that the real project file is byte-identical afterwards.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=script/lib/startup_preflight.sh
source "$ROOT_DIR/script/lib/startup_preflight.sh"

# Inherited configuration would make these checks depend on the operator's shell.
unset VISION_DESK_SIGNING_IDENTITY VISION_DESK_SIGNING_IDENTITY_FILE VISION_DESK_REMOTE_ADDRESS
unset VISION_DESK_TEAM_ID VISION_DESK_BUNDLE_ID VISION_DESK_MAC_BUNDLE_ID

FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/visiondesk-startup.XXXXXX")"
trap 'rm -rf "$FIXTURES"' EXIT
# A path containing a space reproduces the real checkout, "Mac Apps".
SPACED="$FIXTURES/Mac Apps"
SENTINEL="FIXTURE-IDENTITY-SENTINEL"
PASSED=0
FAILED=0

report() {
    local name="$1" status="$2"
    if ((status == 0)); then
        PASSED=$((PASSED + 1))
        printf 'PASS %s\n' "$name"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "$name" >&2
    fi
}

# Runs a command, capturing combined output and status without tripping `set -e`.
capture() {
    LAST_OUTPUT=""
    LAST_STATUS=0
    LAST_OUTPUT="$("$@" 2>&1)" || LAST_STATUS=$?
}

# Fixtures are named by the caller rather than numbered: these builders run inside command
# substitutions, where a shared counter would not survive the subshell and every fixture
# would collide on one path.
next_fixture() {
    printf '%s/%s\n' "$FIXTURES" "$1"
}

exists_all() {
    local path
    for path in "$@"; do
        if [[ ! -e "$path" ]]; then
            return 1
        fi
    done
    return 0
}

missing_all() {
    local path
    for path in "$@"; do
        if [[ -e "$path" ]]; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Embedded validators
#
# Both Python blocks are extracted from build_and_run.sh by heredoc delimiter, so these
# checks exercise the shipped validators rather than a copy that can drift.
# ---------------------------------------------------------------------------
extract_embedded_python() {
    python3 - "$ROOT_DIR/script/build_and_run.sh" "$1" "$2" <<'EXTRACT_PY'
import sys

path, delimiter, destination = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().splitlines()
opener = "<<'" + delimiter + "'"
start = None
for index, line in enumerate(lines):
    if line.rstrip().endswith(opener):
        start = index + 1
        break
if start is None:
    raise SystemExit("Missing embedded block: " + delimiter)
end = start
while end < len(lines) and lines[end].strip() != delimiter:
    end += 1
if end >= len(lines):
    raise SystemExit("Unterminated embedded block: " + delimiter)
with open(destination, "w", encoding="utf-8") as output:
    output.write("\n".join(lines[start:end]) + "\n")
EXTRACT_PY
}

REPORT_VALIDATOR="$FIXTURES/report_validator.py"
extract_embedded_python REPORT_PY "$REPORT_VALIDATOR"

check_report() {
    local name="$1" body="$2" mode="$3" expected="$4"
    local path="$FIXTURES/runtime-report.json"
    printf '%s' "$body" >"$path"
    capture python3 "$REPORT_VALIDATOR" "$path" "launch-id" "com.example.VisionDeskMac" "$mode"
    if { ((expected == 0)) && ((LAST_STATUS == 0)); } ||
        { ((expected != 0)) && ((LAST_STATUS != 0)); }; then
        report "runtime validator: $name" 0
    else
        report "runtime validator: $name" 1
    fi
}

# Composed field by field so that no fixture depends on a duplicate JSON key, where only the
# last occurrence survives parsing and the test would not say what it appears to say.
report_body() {
    printf '{"reportID":"%s","bundleID":"com.example.VisionDeskMac","windows":%s,"processID":%s%s}' \
        "${1:-launch-id}" "${2:-[\"main\"]}" "${3:-$$}" "${4:-}"
}

check_report "malformed JSON" '{ not json' --verify 1
check_report "wrong root type" '[]' --verify 1
check_report "mismatched launch identifier" "$(report_body other)" --verify 1
check_report "no visible window" "$(report_body launch-id '[]')" --verify 1
check_report "missing PID" \
    '{"reportID":"launch-id","bundleID":"com.example.VisionDeskMac","windows":["main"]}' --verify 1
check_report "boolean PID" "$(report_body launch-id '["main"]' true)" --verify 1
check_report "negative PID" "$(report_body launch-id '["main"]' -1)" --verify 1
check_report "verify ignores sharing state" \
    "$(report_body launch-id '["main"]' "$$" ',"sharing":false')" --verify 0

# ---------------------------------------------------------------------------
# Developer-directory preflight
# ---------------------------------------------------------------------------
make_developer_fixture() {
    local developer
    developer="$(next_fixture "$1")/Contents/Developer"
    mkdir -p "$developer/usr/bin"
    if [[ "${2:-}" == "with-xcodebuild" ]]; then
        printf '#!/bin/sh\necho "stub xcodebuild must not run" >&2\nexit 97\n' >"$developer/usr/bin/xcodebuild"
        chmod +x "$developer/usr/bin/xcodebuild"
    fi
    printf '%s\n' "$developer"
}

FULL_XCODE="$(make_developer_fixture full-xcode with-xcodebuild)"
TOOLS_ONLY="$(make_developer_fixture tools-only)"
XCODE_SELECT_LOG="$FIXTURES/xcode-select.log"
STUB_BIN="$FIXTURES/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/xcode-select" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$XCODE_SELECT_LOG"
if [ -n "\${VISIONDESK_STUB_DEVELOPER_DIR:-}" ]; then
    printf '%s\n' "\$VISIONDESK_STUB_DEVELOPER_DIR"
    exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/xcode-select"

resolve_with_stub() {
    (
        PATH="$STUB_BIN:$PATH"
        DEVELOPER_DIR=""
        export VISIONDESK_STUB_DEVELOPER_DIR="$2"
        visiondesk_resolve_developer_dir "$1"
    )
}

resolve_with_env() {
    capture env DEVELOPER_DIR="$1" bash -c \
        'source "$1"; shift; visiondesk_resolve_developer_dir "$@"' bash \
        "$ROOT_DIR/script/lib/startup_preflight.sh" "${@:2}"
}

resolve_with_env "$FULL_XCODE" full-xcode
report "developer dir: full Xcode accepted" \
    "$([[ $LAST_STATUS -eq 0 && "$LAST_OUTPUT" == "$FULL_XCODE" ]] && echo 0 || echo 1)"

resolve_with_env "$TOOLS_ONLY" full-xcode
report "developer dir: command-line tools rejected for xcodebuild" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"full Xcode installation"* ]] && echo 0 || echo 1)"

resolve_with_env "$TOOLS_ONLY"
report "developer dir: any toolchain accepted when xcodebuild is not needed" \
    "$([[ $LAST_STATUS -eq 0 && "$LAST_OUTPUT" == "$TOOLS_ONLY" ]] && echo 0 || echo 1)"

resolve_with_env "$FIXTURES/no-such-developer-dir"
report "developer dir: nonexistent path rejected" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"existing directory"* ]] && echo 0 || echo 1)"

capture resolve_with_stub full-xcode ""
report "developer dir: failed lookup reports no selection" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"No developer directory is selected"* ]] && echo 0 || echo 1)"

# The regression: an empty resolution used to build "/usr/bin/xcodebuild", the executable
# xcrun shim, so the guard passed and the build failed later with the shim's error.
capture resolve_with_stub full-xcode "$TOOLS_ONLY"
report "developer dir: selected tools-only toolchain cannot satisfy the xcodebuild guard" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" != *"/usr/bin/xcodebuild"* ]] && echo 0 || echo 1)"

# Two separate properties. An empty log means the lookup was never needed, which is not a
# failure of the no-switch rule, so each is asserted on its own.
switch_requested=0
if [[ -f "$XCODE_SELECT_LOG" ]] && grep -qE '(^| )(-s|--switch|-r|--reset)' "$XCODE_SELECT_LOG"; then
    switch_requested=1
fi
report "developer dir: selection is never switched" "$switch_requested"
report "developer dir: the lookup was actually consulted" \
    "$([[ -s "$XCODE_SELECT_LOG" ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Signing identity preflight
#
# Fixture values only. A rejection must never echo the identity, so each failure message is
# searched for the sentinel.
# ---------------------------------------------------------------------------
identity_fixture() {
    local path
    path="$(next_fixture "identity-$1").txt"
    printf '%s' "$2" >"$path"
    printf '%s\n' "$path"
}

read_identity() {
    local errors="$FIXTURES/identity-stderr.txt"
    IDENTITY_STATUS=0
    IDENTITY_OUT="$(visiondesk_read_signing_identity "$1" 2>"$errors")" || IDENTITY_STATUS=$?
    IDENTITY_ERR="$(cat "$errors")"
}

read_identity "$(identity_fixture padded "  $SENTINEL  "$'\n')"
report "signing identity: surrounding whitespace trimmed" \
    "$([[ $IDENTITY_STATUS -eq 0 && "$IDENTITY_OUT" == "$SENTINEL" ]] && echo 0 || echo 1)"

read_identity "$(identity_fixture crlf "$SENTINEL"$'\r\n')"
report "signing identity: carriage return trimmed" \
    "$([[ $IDENTITY_STATUS -eq 0 && "$IDENTITY_OUT" == "$SENTINEL" ]] && echo 0 || echo 1)"

read_identity "$(identity_fixture space ' ')"
report "signing identity: single space rejected with guidance" \
    "$([[ $IDENTITY_STATUS -ne 0 && -z "$IDENTITY_OUT" && "$IDENTITY_ERR" == *"stable signing identity"* ]] && echo 0 || echo 1)"

read_identity "$(identity_fixture blank-lines $'\n\n\t\n')"
report "signing identity: blank lines rejected" \
    "$([[ $IDENTITY_STATUS -ne 0 && -z "$IDENTITY_OUT" ]] && echo 0 || echo 1)"

read_identity "$(identity_fixture two-lines "$SENTINEL"$'\nsecond identity\n')"
report "signing identity: multiple lines rejected without echoing the value" \
    "$([[ $IDENTITY_STATUS -ne 0 && "$IDENTITY_ERR" != *"$SENTINEL"* && "$IDENTITY_ERR" == *"more than one line"* ]] && echo 0 || echo 1)"

read_identity "$(identity_fixture adhoc '-')"
report "signing identity: explicit ad-hoc dash still accepted" \
    "$([[ $IDENTITY_STATUS -eq 0 && "$IDENTITY_OUT" == "-" ]] && echo 0 || echo 1)"

read_identity "$FIXTURES/no-such-identity-file.txt"
report "signing identity: absent file and unset variable rejected" \
    "$([[ $IDENTITY_STATUS -ne 0 && "$IDENTITY_ERR" == *"VISION_DESK_SIGNING_IDENTITY"* ]] && echo 0 || echo 1)"

VISION_DESK_SIGNING_IDENTITY="  $SENTINEL  "
read_identity "$(identity_fixture losing-file 'file-value-must-not-win')"
unset VISION_DESK_SIGNING_IDENTITY
report "signing identity: environment wins over the file and is trimmed" \
    "$([[ $IDENTITY_STATUS -eq 0 && "$IDENTITY_OUT" == "$SENTINEL" ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Backup retention
# ---------------------------------------------------------------------------
DIST="$SPACED/dist"
mkdir -p "$DIST/VisionDeskMac.app" "$DIST/previous.foreign" "$DIST/previous-manual/VisionDeskMac.app.backup"
: >"$DIST/runtime-report.json"
for stamp in 01 02 03 04 05; do
    mkdir -p "$DIST/previous.a$stamp/VisionDeskMac.app.backup"
    touch -t "202601${stamp}0101" "$DIST/previous.a$stamp"
done
visiondesk_retain_recent_backups "$DIST" VisionDeskMac 3
report "backup retention: three newest own backups kept" \
    "$(exists_all "$DIST/previous.a03" "$DIST/previous.a04" "$DIST/previous.a05" && echo 0 || echo 1)"
report "backup retention: older own backups pruned" \
    "$(missing_all "$DIST/previous.a01" "$DIST/previous.a02" && echo 0 || echo 1)"
report "backup retention: unrelated dist paths untouched" \
    "$(exists_all "$DIST/VisionDeskMac.app" "$DIST/runtime-report.json" "$DIST/previous.foreign" \
        "$DIST/previous-manual/VisionDeskMac.app.backup" && echo 0 || echo 1)"

UNDER="$SPACED/dist-under-limit"
mkdir -p "$UNDER/previous.b01/VisionDeskMac.app.backup" "$UNDER/previous.b02/VisionDeskMac.app.backup"
visiondesk_retain_recent_backups "$UNDER" VisionDeskMac 3
report "backup retention: nothing pruned below the limit" \
    "$(exists_all "$UNDER/previous.b01" "$UNDER/previous.b02" && echo 0 || echo 1)"

OTHER="$SPACED/dist-other-app"
mkdir -p "$OTHER/previous.c01/OtherApp.app.backup" "$OTHER/previous.c02/OtherApp.app.backup" \
    "$OTHER/previous.c03/OtherApp.app.backup" "$OTHER/previous.c04/OtherApp.app.backup"
visiondesk_retain_recent_backups "$OTHER" VisionDeskMac 3
report "backup retention: another app's backups are not this script's to prune" \
    "$(exists_all "$OTHER/previous.c01" "$OTHER/previous.c02" "$OTHER/previous.c03" "$OTHER/previous.c04" \
        && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Staging release and pruning
# ---------------------------------------------------------------------------
STAGE="$SPACED/.build"
mkdir -p "$STAGE/clang-module-cache" "$STAGE/app-stage.keep" "$STAGE/app-stage.old1" "$STAGE/app-stage.old2"
mkdir -p "$STAGE/app-stage.failed/VisionDeskMac.app" "$STAGE/app-stage.done" "$STAGE/not-a-stage"

capture visiondesk_release_staging "$STAGE/app-stage.failed" "$STAGE/app-stage.failed/VisionDeskMac.app" 1 1
report "staging: a verified candidate is kept and reported as a signed build" \
    "$([[ -d "$STAGE/app-stage.failed/VisionDeskMac.app" && "$LAST_OUTPUT" == *"Preserved signed build"* \
        && "$LAST_OUTPUT" == *"app-stage.failed/VisionDeskMac.app"* ]] && echo 0 || echo 1)"

# The trap is armed before signing, so a bundle that exists is not necessarily signed.
capture visiondesk_release_staging "$STAGE/app-stage.failed" "$STAGE/app-stage.failed/VisionDeskMac.app" 1 0
report "staging: an unverified candidate is kept without claiming it is signed" \
    "$([[ -d "$STAGE/app-stage.failed/VisionDeskMac.app" && "$LAST_OUTPUT" == *"unverified staged bundle"* \
        && "$LAST_OUTPUT" != *"signed build"* ]] && echo 0 || echo 1)"

capture visiondesk_release_staging "$STAGE/app-stage.failed" "$STAGE/app-stage.failed/VisionDeskMac.app" 0 1
report "staging: successful build-only keeps the candidate silently" \
    "$([[ -d "$STAGE/app-stage.failed/VisionDeskMac.app" && -z "$LAST_OUTPUT" ]] && echo 0 || echo 1)"

visiondesk_release_staging "$STAGE/app-stage.done" "$STAGE/app-stage.done/VisionDeskMac.app" 0
report "staging: moved bundle leaves no empty directory behind" \
    "$(missing_all "$STAGE/app-stage.done" && echo 0 || echo 1)"

visiondesk_release_staging "$STAGE/not-a-stage" "$STAGE/not-a-stage/VisionDeskMac.app" 0
report "staging: a directory without the generated prefix is never removed" \
    "$(exists_all "$STAGE/not-a-stage" && echo 0 || echo 1)"

visiondesk_prune_stage_dirs "$STAGE" "$STAGE/app-stage.keep"
report "staging: abandoned directories from earlier runs pruned" \
    "$(missing_all "$STAGE/app-stage.old1" "$STAGE/app-stage.old2" "$STAGE/app-stage.failed" && echo 0 || echo 1)"
report "staging: current candidate and unrelated build paths kept" \
    "$(exists_all "$STAGE/app-stage.keep" "$STAGE/clang-module-cache" "$STAGE/not-a-stage" && echo 0 || echo 1)"

EMPTY_STAGE="$SPACED/.build-empty"
mkdir -p "$EMPTY_STAGE/swift-module-cache"
visiondesk_prune_stage_dirs "$EMPTY_STAGE" ""
report "staging: pruning an unstaged tree is a no-op" \
    "$(exists_all "$EMPTY_STAGE/swift-module-cache" && echo 0 || echo 1)"

# A keep path spelled differently must still be recognised as the current candidate, not
# pruned because a string comparison missed.
ALIAS_STAGE="$SPACED/.build-alias"
mkdir -p "$ALIAS_STAGE/app-stage.keep" "$ALIAS_STAGE/app-stage.stale"
visiondesk_prune_stage_dirs "$ALIAS_STAGE" "$ALIAS_STAGE/./app-stage.keep/"
report "staging: an equivalent spelling of the keep path is preserved" \
    "$(exists_all "$ALIAS_STAGE/app-stage.keep" && missing_all "$ALIAS_STAGE/app-stage.stale" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Bundle install, restore and retention ordering
#
# `mv` is shadowed by a stub on PATH so a failing install can be observed without touching a
# real app. The helper calls `mv` unqualified, so no test-only seam exists in the shipped
# code. Fixture trees only; `dist/VisionDeskMac.app` here is a directory holding a marker file.
# ---------------------------------------------------------------------------
PREFLIGHT_LIB="$ROOT_DIR/script/lib/startup_preflight.sh"
INSTALL_STUBS="$FIXTURES/install-stubs"
mkdir -p "$INSTALL_STUBS/refuse-install" "$INSTALL_STUBS/refuse-both"
cat >"$INSTALL_STUBS/refuse-install/mv" <<'STUB'
#!/bin/sh
case "$1" in
    *app-stage.*) echo "stub mv: refusing the staged install" >&2; exit 1 ;;
esac
exec /bin/mv "$@"
STUB
cat >"$INSTALL_STUBS/refuse-both/mv" <<'STUB'
#!/bin/sh
case "$1" in
    *app-stage.*|*previous.*) echo "stub mv: refusing" >&2; exit 1 ;;
esac
exec /bin/mv "$@"
STUB
chmod +x "$INSTALL_STUBS/refuse-install/mv" "$INSTALL_STUBS/refuse-both/mv"

make_install_fixture() {
    local root
    root="$(next_fixture "install-$1")"
    mkdir -p "$root/dist/VisionDeskMac.app/Contents" "$root/.build/app-stage.new/VisionDeskMac.app/Contents"
    printf 'installed\n' >"$root/dist/VisionDeskMac.app/Contents/marker"
    printf 'staged\n' >"$root/.build/app-stage.new/VisionDeskMac.app/Contents/marker"
    printf '%s\n' "$root"
}

# Timestamps increase with the index and stay a valid [[CC]YY]MMDDhhmm, so a two-digit index
# cannot silently produce a malformed stamp the way string concatenation did.
seed_backups() {
    local dist="$1" count="$2" index
    for ((index = 1; index <= count; index++)); do
        mkdir -p "$dist/previous.seed$index/VisionDeskMac.app.backup"
        touch -t "$(printf '20260101%02d%02d' "$((index / 60))" "$((index % 60))")" \
            "$dist/previous.seed$index"
    done
}

# Locates the single recoverable backup a fixture install produced. mktemp randomises the
# directory name, so the marker is found by globbing rather than by reconstructing the path.
backup_marker() {
    local dist="$1" dir
    for dir in "$dist"/previous.*; do
        if [[ -f "$dir/VisionDeskMac.app.backup/Contents/marker" ]]; then
            printf '%s\n' "$dir/VisionDeskMac.app.backup/Contents/marker"
            return 0
        fi
    done
    return 1
}

count_backups() {
    local dist="$1" count=0 dir
    for dir in "$dist"/previous.*; do
        if [[ -d "$dir" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

install_with_stub() {
    local stub="$1" root="$2"
    capture env PATH="$stub:$PATH" bash -c \
        'source "$1"; shift; visiondesk_install_bundle "$@"' bash "$PREFLIGHT_LIB" \
        "$root/.build/app-stage.new/VisionDeskMac.app" "$root/dist/VisionDeskMac.app" \
        "$root/dist" VisionDeskMac 3
}

INSTALL_OK="$(make_install_fixture success)"
seed_backups "$INSTALL_OK/dist" 4
capture visiondesk_install_bundle "$INSTALL_OK/.build/app-stage.new/VisionDeskMac.app" \
    "$INSTALL_OK/dist/VisionDeskMac.app" "$INSTALL_OK/dist" VisionDeskMac 3
install_ok=1
if [[ $LAST_STATUS -eq 0 ]] &&
    grep -q staged "$INSTALL_OK/dist/VisionDeskMac.app/Contents/marker" &&
    missing_all "$INSTALL_OK/.build/app-stage.new/VisionDeskMac.app"; then
    install_ok=0
fi
report "install: the staged bundle replaces the installed one" "$install_ok"
report "install: retention runs once the install succeeded" \
    "$([[ "$(count_backups "$INSTALL_OK/dist")" == 3 ]] && echo 0 || echo 1)"

INSTALL_FAIL="$(make_install_fixture restored)"
seed_backups "$INSTALL_FAIL/dist" 4
install_with_stub "$INSTALL_STUBS/refuse-install" "$INSTALL_FAIL"
restored=1
if [[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"previous one was restored"* ]] &&
    grep -q installed "$INSTALL_FAIL/dist/VisionDeskMac.app/Contents/marker"; then
    restored=0
fi
report "install: a failed install restores the previous companion" "$restored"
report "install: the staged candidate survives a failed install" \
    "$(exists_all "$INSTALL_FAIL/.build/app-stage.new/VisionDeskMac.app" && echo 0 || echo 1)"
# Pruning before the install succeeded would discard copies while no companion is installed.
report "install: retention does not run when the install failed" \
    "$([[ "$(count_backups "$INSTALL_FAIL/dist")" == 4 ]] && echo 0 || echo 1)"

INSTALL_STUCK="$(make_install_fixture unrecoverable)"
install_with_stub "$INSTALL_STUBS/refuse-both" "$INSTALL_STUCK"
stuck=1
if [[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"could not be restored"* &&
    "$LAST_OUTPUT" == *"/previous."*"/VisionDeskMac.app.backup"* &&
    "$LAST_OUTPUT" == *"/app-stage.new/VisionDeskMac.app"* ]]; then
    stuck=0
fi
report "install: an unrecoverable install prints the backup and staged paths" "$stuck"

# The destination is empty in this state, so recovery depends on the backup itself still
# holding the old bundle. This inspects the backup, not the staged candidate checked above.
STUCK_MARKER="$(backup_marker "$INSTALL_STUCK/dist" || true)"
report "install: the previous companion is still readable from its backup" \
    "$([[ -n "$STUCK_MARKER" ]] && grep -q installed "$STUCK_MARKER" \
        && missing_all "$INSTALL_STUCK/dist/VisionDeskMac.app" && echo 0 || echo 1)"

INSTALL_FRESH="$(next_fixture install-fresh)"
mkdir -p "$INSTALL_FRESH/dist" "$INSTALL_FRESH/.build/app-stage.new/VisionDeskMac.app/Contents"
printf 'staged\n' >"$INSTALL_FRESH/.build/app-stage.new/VisionDeskMac.app/Contents/marker"
capture visiondesk_install_bundle "$INSTALL_FRESH/.build/app-stage.new/VisionDeskMac.app" \
    "$INSTALL_FRESH/dist/VisionDeskMac.app" "$INSTALL_FRESH/dist" VisionDeskMac 3
report "install: a first install creates no backup" \
    "$([[ $LAST_STATUS -eq 0 && "$(count_backups "$INSTALL_FRESH/dist")" == 0 ]] \
        && exists_all "$INSTALL_FRESH/dist/VisionDeskMac.app" && echo 0 || echo 1)"

# Retention is a bound on the copies that exist, so a fresh install into a dist that already
# carries owned backups must still prune — while adding none of its own.
INSTALL_SEEDED="$(next_fixture install-fresh-seeded)"
mkdir -p "$INSTALL_SEEDED/dist" "$INSTALL_SEEDED/.build/app-stage.new/VisionDeskMac.app/Contents"
printf 'staged\n' >"$INSTALL_SEEDED/.build/app-stage.new/VisionDeskMac.app/Contents/marker"
seed_backups "$INSTALL_SEEDED/dist" 4
capture visiondesk_install_bundle "$INSTALL_SEEDED/.build/app-stage.new/VisionDeskMac.app" \
    "$INSTALL_SEEDED/dist/VisionDeskMac.app" "$INSTALL_SEEDED/dist" VisionDeskMac 3
report "install: a fresh install still bounds pre-existing owned backups" \
    "$([[ $LAST_STATUS -eq 0 && "$(count_backups "$INSTALL_SEEDED/dist")" == 3 ]] \
        && exists_all "$INSTALL_SEEDED/dist/VisionDeskMac.app" && echo 0 || echo 1)"

seeded_only=0
for dir in "$INSTALL_SEEDED/dist"/previous.*; do
    if [[ ! -d "$dir" ]]; then
        continue
    fi
    case "${dir##*/}" in
        previous.seed?*) ;;
        *) seeded_only=1 ;;
    esac
done
report "install: a fresh install adds no backup of its own while pruning" "$seeded_only"

# ---------------------------------------------------------------------------
# Project generation
#
# Generation runs only inside fixture trees. The real VisionDesk.xcodeproj is hashed before
# and after the negative script invocations below and must not change.
# ---------------------------------------------------------------------------
GENERATOR="$ROOT_DIR/script/generate_xcode_project.py"

project_hash() {
    local file="$1/VisionDesk.xcodeproj/project.pbxproj"
    if [[ -f "$file" ]]; then
        shasum -a 256 "$file" | cut -d' ' -f1
    else
        printf 'absent\n'
    fi
}

make_generator_fixture() {
    local root
    root="$(next_fixture "generator-$1")"
    mkdir -p "$root/script" "$root/Sources/DeskCore" "$root/Sources/DeskTransport" \
        "$root/VisionApp" "$root/VisionTests"
    cp "$GENERATOR" "$root/script/generate_xcode_project.py"
    : >"$root/Sources/DeskCore/Core.swift"
    : >"$root/Sources/DeskTransport/Transport.swift"
    : >"$root/VisionApp/App.swift"
    : >"$root/VisionTests/Tests.swift"
    if [[ "${2:-}" == "with-resources" ]]; then
        : >"$root/VisionApp/Info.plist"
        : >"$root/VisionApp/VisionDesk.entitlements"
        : >"$root/VisionApp/PrivacyInfo.xcprivacy"
        : >"$root/Sources/DeskTransport/PrivacyInfo.xcprivacy"
        local icon="$root/VisionApp/Assets.xcassets/AppIcon.solidimagestack"
        mkdir -p "$icon/Front.solidimagestacklayer/Content.imageset" \
            "$icon/Back.solidimagestacklayer/Content.imageset"
        : >"$icon/Contents.json"
        : >"$root/VisionApp/Assets.xcassets/Contents.json"
        : >"$icon/Front.solidimagestacklayer/Contents.json"
        : >"$icon/Front.solidimagestacklayer/Content.imageset/Contents.json"
        : >"$icon/Back.solidimagestacklayer/Contents.json"
        : >"$icon/Back.solidimagestacklayer/Content.imageset/Contents.json"
        : >"$icon/Front.solidimagestacklayer/Content.imageset/foreground.png"
        : >"$icon/Back.solidimagestacklayer/Content.imageset/background.png"
    fi
    printf '%s\n' "$root"
}

run_generator() {
    local root="$1"
    shift
    capture env -u VISION_DESK_TEAM_ID -u VISION_DESK_BUNDLE_ID "$@" \
        python3 "$root/script/generate_xcode_project.py"
}

NO_RESOURCES="$(make_generator_fixture no-resources)"
run_generator "$NO_RESOURCES"
report "generation: missing Info.plist stops before the project is written" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"Missing required app resource: VisionApp/Info.plist"* \
        && ! -e "$NO_RESOURCES/VisionDesk.xcodeproj" ]] && echo 0 || echo 1)"

NO_ENTITLEMENTS="$(make_generator_fixture no-entitlements)"
: >"$NO_ENTITLEMENTS/VisionApp/Info.plist"
run_generator "$NO_ENTITLEMENTS"
report "generation: missing entitlements stops before the project is written" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"VisionApp/VisionDesk.entitlements"* \
        && ! -e "$NO_ENTITLEMENTS/VisionDesk.xcodeproj" ]] && echo 0 || echo 1)"

COMPLETE="$(make_generator_fixture complete with-resources)"
run_generator "$COMPLETE" VISION_DESK_BUNDLE_ID=com.fixture.VisionDesk VISION_DESK_TEAM_ID=ABCDE12345
generated=1
if [[ $LAST_STATUS -eq 0 ]] &&
    grep -q 'com.fixture.VisionDesk' "$COMPLETE/VisionDesk.xcodeproj/project.pbxproj" &&
    grep -q 'ABCDE12345' "$COMPLETE/VisionDesk.xcodeproj/project.pbxproj"; then
    generated=0
fi
report "generation: complete fixture writes a project carrying the registered identifiers" "$generated"

capture python3 - "$COMPLETE/VisionDesk.xcodeproj/project.pbxproj" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as project_file:
    objects = plistlib.load(project_file)["objects"]
for name, expected in (
    ("VisionDesk", "VisionApp/PrivacyInfo.xcprivacy"),
    ("DeskTransport", "Sources/DeskTransport/PrivacyInfo.xcprivacy"),
):
    target = next(item for item in objects.values()
                  if item["isa"] == "PBXNativeTarget" and item["name"] == name)
    copied_paths = [objects[objects[build]["fileRef"]]["path"]
                    for phase in target["buildPhases"]
                    if objects[phase]["isa"] == "PBXResourcesBuildPhase"
                    for build in objects[phase]["files"]]
    assert copied_paths.count(expected) == 1, (name, copied_paths)
    assert sum(path.endswith(".xcprivacy") for path in copied_paths) == 1, copied_paths
PY
report "generation: app and transport each copy their own privacy manifest into their bundle" "$LAST_STATUS"

for manifest in VisionApp/PrivacyInfo.xcprivacy Sources/DeskTransport/PrivacyInfo.xcprivacy; do
    NO_MANIFEST="$(make_generator_fixture no-manifest with-resources)"
    run_generator "$NO_MANIFEST"
    NO_MANIFEST_HASH="$(project_hash "$NO_MANIFEST")"
    rm "$NO_MANIFEST/$manifest"
    run_generator "$NO_MANIFEST"
    report "generation: missing $manifest preserves an existing project" \
        "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"$manifest"* \
            && "$(project_hash "$NO_MANIFEST")" == "$NO_MANIFEST_HASH" ]] && echo 0 || echo 1)"
done

NO_ICON="$(make_generator_fixture no-icon with-resources)"
run_generator "$NO_ICON"
NO_ICON_HASH="$(project_hash "$NO_ICON")"
rm "$NO_ICON/VisionApp/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset/foreground.png"
run_generator "$NO_ICON"
report "generation: a missing icon layer preserves the existing project" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"foreground.png"* \
        && "$(project_hash "$NO_ICON")" == "$NO_ICON_HASH" ]] && echo 0 || echo 1)"

REGISTERED_HASH="$(project_hash "$COMPLETE")"
NO_ICON_METADATA="$(make_generator_fixture no-icon-metadata with-resources)"
run_generator "$NO_ICON_METADATA"
NO_ICON_METADATA_HASH="$(project_hash "$NO_ICON_METADATA")"
rm "$NO_ICON_METADATA/VisionApp/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset/Contents.json"
run_generator "$NO_ICON_METADATA"
report "generation: missing icon imageset metadata preserves the existing project" \
    "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"Content.imageset/Contents.json"* \
        && "$(project_hash "$NO_ICON_METADATA")" == "$NO_ICON_METADATA_HASH" ]] && echo 0 || echo 1)"

for invalid in "VISION_DESK_BUNDLE_ID=not reverse dns" "VISION_DESK_BUNDLE_ID=" \
    "VISION_DESK_TEAM_ID=SHORT" "VISION_DESK_TEAM_ID=" "VISION_DESK_TEAM_ID=TOOLONGTEAMID"; do
    run_generator "$COMPLETE" "$invalid"
    report "generation: ${invalid%%=*} rejected, registered project preserved ('${invalid#*=}')" \
        "$([[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"left unchanged"* \
            && "$(project_hash "$COMPLETE")" == "$REGISTERED_HASH" ]] && echo 0 || echo 1)"
done

run_generator "$COMPLETE" VISION_DESK_BUNDLE_ID=com.fixture.Updated VISION_DESK_TEAM_ID=ABCDE12345
regenerated=1
if [[ $LAST_STATUS -eq 0 && "$(project_hash "$COMPLETE")" != "$REGISTERED_HASH" ]] &&
    grep -q 'com.fixture.Updated' "$COMPLETE/VisionDesk.xcodeproj/project.pbxproj"; then
    regenerated=0
fi
report "generation: a valid identifier change still regenerates the project" "$regenerated"

# "Left unchanged" has to hold for a project that already exists, not only for a fixture that
# never had one, so this case generates first and then removes a required resource.
EXISTING="$(make_generator_fixture existing with-resources)"
run_generator "$EXISTING" VISION_DESK_BUNDLE_ID=com.fixture.Existing VISION_DESK_TEAM_ID=ABCDE12345
EXISTING_HASH="$(project_hash "$EXISTING")"
rm "$EXISTING/VisionApp/Info.plist"
run_generator "$EXISTING"
report "generation: a missing resource preserves an already generated project" \
    "$([[ "$EXISTING_HASH" != absent && $LAST_STATUS -ne 0 \
        && "$LAST_OUTPUT" == *"Missing required app resource: VisionApp/Info.plist"* \
        && "$LAST_OUTPUT" == *"left unchanged"* \
        && "$(project_hash "$EXISTING")" == "$EXISTING_HASH" ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Negative preflight in the real checkout
#
# Each case must stop before `swift build` and before generation: the real project hash and
# the staging-directory count are both compared across the invocation.
# ---------------------------------------------------------------------------
stage_count() {
    local count=0 dir
    for dir in "$ROOT_DIR"/.build/app-stage.*; do
        if [[ -d "$dir" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

REAL_HASH="$(project_hash "$ROOT_DIR")"
REAL_STAGES="$(stage_count)"
BLANK_IDENTITY="$(identity_fixture preflight-blank '   ')"
PREFLIGHT_OUTPUT=""

check_preflight() {
    local name="$1" expected_fragment="$2"
    shift 2
    capture env -u VISION_DESK_TEAM_ID -u VISION_DESK_BUNDLE_ID -u VISION_DESK_REMOTE_ADDRESS \
        DEVELOPER_DIR="$FULL_XCODE" VISION_DESK_SIGNING_IDENTITY_FILE="$BLANK_IDENTITY" "$@"
    PREFLIGHT_OUTPUT="$PREFLIGHT_OUTPUT$LAST_OUTPUT"
    local ok=1
    if [[ $LAST_STATUS -ne 0 && "$LAST_OUTPUT" == *"$expected_fragment"* &&
        "$(project_hash "$ROOT_DIR")" == "$REAL_HASH" && "$(stage_count)" == "$REAL_STAGES" ]]; then
        ok=0
    fi
    report "preflight: $name" "$ok"
}

check_preflight "device build without a team identifier" "VISION_DESK_TEAM_ID" \
    "$ROOT_DIR/script/build_vision.sh" device
check_preflight "unsupported visionOS mode" "usage:" \
    "$ROOT_DIR/script/build_vision.sh" not-a-mode
check_preflight "unsupported companion mode" "usage:" \
    "$ROOT_DIR/script/build_and_run.sh" --not-a-mode
check_preflight "remote launcher still requires signing" "stable signing identity" \
    "$ROOT_DIR/script/build_and_run.sh" --remote-host
check_preflight "blank signing identity file" "stable signing identity" \
    "$ROOT_DIR/script/build_and_run.sh" --verify
check_preflight "invalid companion bundle identifier" "reverse-DNS bundle identifier" \
    env VISION_DESK_MAC_BUNDLE_ID=not-reverse-dns "$ROOT_DIR/script/build_and_run.sh" --verify

report "preflight: the real signing configuration was never consulted" \
    "$([[ "$PREFLIGHT_OUTPUT" != *"config/mac-signing-identity.txt"* ]] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Documented modes match accepted modes
# ---------------------------------------------------------------------------
check_modes() {
    capture python3 - "$ROOT_DIR/script/$1" <<'MODE_PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('case "$MODE" in')
body = text[start:text.index("esac", start)]
accepted = set()
for group in re.findall(r"(?:in |\n|;; )\s*([A-Za-z0-9|_*-]+)\)", body):
    for token in group.split("|"):
        token = token.strip()
        if token and token != "*":
            accepted.add(token)
documented = {
    token.strip()
    for token in re.search(r"usage: \$0 \[([^\]]*)\]", text).group(1).split("|")
}
if not accepted:
    raise SystemExit("no accepted modes were parsed")
if accepted != documented:
    raise SystemExit(f"accepted={sorted(accepted)} documented={sorted(documented)}")
MODE_PY
    report "usage text lists every accepted mode: $1" "$LAST_STATUS"
}

check_modes build_and_run.sh
check_modes build_vision.sh

# The mode list above only covers the first `case`. REPORT_MODE is a second dispatch, and a
# mode that reports must also launch with a runtime report and be validated afterwards.
capture python3 - "$ROOT_DIR/script/build_and_run.sh" <<'PARITY_PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()


def case_patterns(block):
    found = set()
    for group in re.findall(r"(?:in |\n|;; )\s*([A-Za-z0-9|_*-]+)\)", block):
        for token in group.split("|"):
            token = token.strip()
            if token and token != "*":
                found.add(token)
    return found


first = text.index('case "$MODE" in')
accepted = case_patterns(text[first : text.index("esac", first)])
second = text.index('case "$MODE" in', text.index("REPORT_MODE=0"))
reporting = case_patterns(text[second : text.index("esac", second)])

expected = {"--verify", "--capture-check", "--input-check"}
if reporting != expected:
    raise SystemExit(f"reporting modes drifted: {sorted(reporting)} != {sorted(expected)}")
if not reporting <= accepted:
    raise SystemExit(f"reporting modes are not accepted modes: {sorted(reporting - accepted)}")

launch = text[text.index("if ((REPORT_MODE)); then") :]
opens = [line.strip() for line in launch.splitlines() if "/usr/bin/open" in line]
with_report = [line for line in opens if "--runtime-report-id" in line]
if len(with_report) != len(reporting):
    raise SystemExit(f"{len(reporting)} reporting modes but {len(with_report)} reporting launches")
for mode in sorted(reporting):
    if f'"$MODE" == "{mode}"' not in launch:
        raise SystemExit(f"{mode} reports but has no launch branch")
plain = [line for line in opens if "--args" not in line]
if len(plain) != 1:
    raise SystemExit(f"expected exactly one non-reporting launch, found {len(plain)}")
if launch.count("if ((REPORT_MODE)); then") != 2:
    raise SystemExit("a reporting launch is no longer paired with report validation")
if "--enable-remote-host" in text:
    raise SystemExit("launcher must not silently configure remote access")
PARITY_PY
report "report modes dispatch and validate consistently: build_and_run.sh" "$LAST_STATUS"

printf '\n%d startup checks passed, %d failed.\n' "$PASSED" "$FAILED"
if ((FAILED > 0)); then
    exit 1
fi
