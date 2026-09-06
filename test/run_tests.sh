#!/usr/bin/env bash
# auto-backup test suite — bash 3.2+ compatible, no external deps.
# Runs against a fake rsync stub; tests the library in-process.
# shellcheck shell=bash
set -o pipefail

PASS=0; FAIL=0
FAILED=()

# --- tiny assert framework --------------------------------------------------
pass() { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf 'FAIL  %s\n' "$1"; }
assert_eq()   { local name=$1 want=$2 got=$3; [ "$want" = "$got" ] && pass "$name" || { fail "$name"; printf '  want=%s got=%s\n' "$want" "$got" >&2; }; }
assert_contains() { local name=$1 needle=$2 haystack=$3; case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name"; printf '  needle=%s not in haystack\n' "$needle" >&2 ;; esac; }
assert_rc()   { local name=$1 expect=$2 got=$3; [ "$expect" = "$got" ] && pass "$name" || { fail "$name"; printf '  expected rc=%s got=%s\n' "$expect" "$got" >&2; }; }

# --- sandbox setup -----------------------------------------------------------
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/abtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

AB_CONFIG_DIR="$TMP/cfg"
AB_RUNTIME_DIR="$TMP/run"
STUB_LOG="$TMP/rsync.log"
export AB_CONFIG_DIR AB_RUNTIME_DIR STUB_LOG

# rsync stub
mkdir -p "$TMP/bin"
cat > "$TMP/bin/rsync" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
cat <<'EOF'
rsync  --partial --partial-dir --link-dest=DIR --exclude=PATTERN
       --exclude-from=FILE --delete --checksum --append
       --list-only --stats --dry-run
EOF
exit 0
fi
# skip the help-only flag
if [ "$1" = "--version" ]; then echo "rsync stub 1.0"; exit 0; fi
args=("$@")
# find the destination (last non-flag argument)
dest=""
i=$(( ${#args[@]} - 1 ))
while [ $i -ge 0 ]; do
  case "${args[$i]}" in
    -*) i=$((i-1)); continue ;;
    *)  dest="${args[$i]}"; break ;;
  esac
done
# log everything
printf '%s\n' "${args[@]}" >> "${STUB_LOG:-/dev/null}"
# simulate create unless dry-run, check, or dest is "current" (managed by ln -sfn)
case "$dest" in *current) exit 0 ;; esac
if [ "$dest" != "" ] && ! printf '%s\n' "${args[@]}" | grep -qFx -e '-n' -e '--dry-run'; then
  mkdir -p "$dest" 2>/dev/null || true
  echo ok > "$dest/.rsync-marker" 2>/dev/null || true
fi
exit 0
STUB
chmod +x "$TMP/bin/rsync"
AB_RSYNC_BIN="$TMP/bin/rsync"
export AB_RSYNC_BIN

# Source the library (this lets us test lib functions directly)
. "$ROOT/bin/backup-lib.sh"
AB_LOG_TO_FILE=0  # suppress log file writes in tests

# --- write minimal config for integration tests -----------------------------
mkdir -p "$AB_CONFIG_DIR/jobs.d" "$AB_RUNTIME_DIR" "$TMP/src" "$TMP/dest"

cat > "$AB_CONFIG_DIR/backup.conf" <<'CFG'
RETENTION_DAILY=2
RETENTION_WEEKLY=1
RETENTION_MONTHLY=1
CFG
cat > "$AB_CONFIG_DIR/jobs.d/x.conf" <<'JOB'
SOURCE="${TMP_SRC}"
DEST="${TMP_DEST}"
JOB
# note: $TMP_SRC/TMP_DEST are not expanded in heredoc — ok, they're only
# used as shell variables via ab_load_job + ab_validate_job. We define them
# via environment when sourcing.
export TMP_SRC="$TMP/src" TMP_DEST="$TMP/dest"

# ==========================================================
#  t: version
# ==========================================================
t_version() {
  local out
  out=$("$ROOT/bin/backup.sh" version)
  assert_contains "version contains version string" "auto-backup" "$out"
}

# ==========================================================
#  t: snapshot name format
# ==========================================================
t_snapshot_name_format() {
  local s
  s=$(ab_snapshot_name)
  assert_contains "snapshot name starts with backup-" "backup-" "$s"
  # extract the timestamp part after "backup-"
  local ts=${s#backup-}
  assert_eq "snapshot name format correct" "15" "${#ts}"
}

# ==========================================================
#  t: now_ts format
# ==========================================================
t_now_ts_format() {
  local ts
  ts=$(ab_now_ts)
  assert_eq "now_ts length is 15" "15" "${#ts}"
}

# ==========================================================
#  t: rsync feature detection
# ==========================================================
t_rsync_has() {
  assert_rc "has partial-dir"   0 "$(ab_rsync_has partial-dir; echo $?)"
  assert_rc "has link-dest"     0 "$(ab_rsync_has link-dest; echo $?)"
  assert_rc "no append-verify"  1 "$(ab_rsync_has append-verify; echo $?)"
}

# ==========================================================
#  t: destination helpers
# ==========================================================
t_dest_helpers() {
  assert_rc "remote dest detected"    0 "$(ab_dest_is_remote user@host:/x; echo $?)"
  assert_rc "local dest detected"     1 "$(ab_dest_is_remote /x; echo $?)"
  assert_eq  "host extracted"         "user@host" "$(ab_dest_host 'user@host:/x')"
  assert_eq  "path extracted"         "/x"        "$(ab_dest_path 'user@host:/x')"
}

# ==========================================================
#  t: week key
# ==========================================================
t_week_key() {
  local w
  w=$(ab_week_key "20260906")
  assert_contains "week key format" "W" "$w"
}

# ==========================================================
#  t: retention keep
# ==========================================================
t_retention_keep() {
  local got
  got=$(printf '%s\n' \
    backup-2026-09-03-000000 \
    backup-2026-09-02-000000 \
    backup-2026-09-01-100000 \
    backup-2026-09-01-000000 \
    backup-2026-08-30-000000 \
    backup-2026-08-15-000000 \
    backup-2026-07-01-000000 \
    | ab_retention_keep 2 1 1)
  assert_contains "daily 09-03 kept"   "backup-2026-09-03-000000" "$got"
  assert_contains "daily 09-02 kept"   "backup-2026-09-02-000000" "$got"
  assert_contains "weekly 09-01 kept"  "backup-2026-09-01-100000" "$got"
  # count lines (should be 4)
  local cnt
  cnt=$(printf '%s\n' "$got" | grep -c '^backup-')
  assert_eq "retention keeps 4 snapshots" "4" "$cnt"

  # empty input → empty
  got=$(printf '' | ab_retention_keep 2 1 1)
  assert_eq "empty input → empty" "" "$got"
}

# ==========================================================
#  t: locking
# ==========================================================
t_locking() {
  ab_lock_acquire testlock
  assert_eq "lock dir exists" "1" "$([ -d "$AB_RUNTIME_DIR/locks/testlock" ] && echo 1 || echo 0)"
  # second acquire must fail
  local rc
  ( AB_QUIET=1; ab_lock_acquire testlock ) 2>/dev/null; rc=$?
  assert_rc "second acquire fails" "1" "$rc"
  ab_lock_release
  assert_eq "lock released" "0" "$([ -d "$AB_RUNTIME_DIR/locks/testlock" ] && echo 1 || echo 0)"
}

# ==========================================================
#  t: config load
# ==========================================================
t_config_load() {
  local f="$AB_CONFIG_DIR/jobs.d/x.conf"
  # verify RETENTION_DAILY from global config
  BACKUP_CONF_SOURCED=""
  . "$AB_CONFIG_DIR/backup.conf"
  assert_eq "global RETENTION_DAILY" "2" "$RETENTION_DAILY"
}

# ==========================================================
#  t: init via CLI
# ==========================================================
t_init_cli() {
  local fresh="$TMP/fresh_cfg"
  mkdir -p "$fresh" 2>/dev/null
  rm -rf "$fresh/jobs.d" 2>/dev/null
  "$ROOT/bin/backup.sh" -c "$fresh" -r "$TMP/run" init >/dev/null 2>&1
  assert_eq "init creates jobs.d" "1" "$([ -d "$fresh/jobs.d" ] && echo 1 || echo 0)"
}

# ==========================================================
#  t: list
# ==========================================================
t_list() {
  local out
  out=$("$ROOT/bin/backup.sh" -c "$AB_CONFIG_DIR" -r "$AB_RUNTIME_DIR" list)
  assert_contains "list contains job x" "x" "$out"
}

# ==========================================================
#  t: check (dry-run)
# ==========================================================
t_check() {
  local rc
  "$ROOT/bin/backup.sh" -c "$AB_CONFIG_DIR" -r "$AB_RUNTIME_DIR" check x >/dev/null 2>&1; rc=$?
  assert_rc "check passes" "0" "$rc"
}

# ==========================================================
#  t: end-to-end run
# ==========================================================
t_run_e2e() {
  # ensure clean dest
  rm -rf "$TMP/dest/snapshots" "$TMP/dest/current"
  mkdir -p "$TMP/src"
  echo "hello" > "$TMP/src/test.txt"

  "$ROOT/bin/backup.sh" -c "$AB_CONFIG_DIR" -r "$AB_RUNTIME_DIR" run x >/dev/null 2>&1
  assert_eq "first run exit 0" "0" "$?"

  # snapshot dir created
  local cnt
  cnt=$(ls "$TMP/dest/snapshots" 2>/dev/null | grep -c '^backup-')
  assert_eq "first run creates snapshot" "1" "$cnt"

  # current symlink exists (local dest)
  assert_eq "current symlink exists" "1" "$([ -L "$TMP/dest/current" ] && echo 1 || echo 0)"

  # status file
  assert_eq "status file contains ok" "1" "$(grep -c 'state=ok' "$AB_RUNTIME_DIR/state/x.status" 2>/dev/null || echo 0)"

  # stub log contains --partial-dir
  assert_contains "first run uses --partial-dir" "--partial-dir" "$(cat "$STUB_LOG")"

  # second run
  > "$STUB_LOG"
  sleep 1
  "$ROOT/bin/backup.sh" -c "$AB_CONFIG_DIR" -r "$AB_RUNTIME_DIR" run x >/dev/null 2>&1
  assert_eq "second run exit 0" "0" "$?"

  cnt=$(ls "$TMP/dest/snapshots" 2>/dev/null | grep -c '^backup-')
  assert_eq "two snapshots exist" "2" "$cnt"

  # second run has --link-dest (prev existed)
  assert_contains "second run uses --link-dest" "--link-dest" "$(cat "$STUB_LOG")"

  # no append-verify (stub doesn't support it)
  assert_eq "no append-verify" "0" "$(grep -c 'append-verify' "$STUB_LOG" 2>/dev/null || true)"
}

# ==========================================================
#  t: prune real
# ==========================================================
t_prune() {
  # create a fake old snapshot
  mkdir -p "$TMP/dest/snapshots/backup-2026-07-01-000000"
  # should be pruned by retention (keep 2 daily, 1 weekly, 1 monthly; only 3 unique months remain → oldest 1 removed)
  "$ROOT/bin/backup.sh" -c "$AB_CONFIG_DIR" -r "$AB_RUNTIME_DIR" prune x >/dev/null 2>&1
  assert_eq "prune exit 0" "0" "$?"
}

# ==========================================================
#  t: lock release after run
# ==========================================================
t_lock_release() {
  assert_eq "locks dir clean after run" "0" "$([ -d "$AB_RUNTIME_DIR/locks" ] && ls "$AB_RUNTIME_DIR/locks" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
}

# ==========================================================
#  Run all tests
# ==========================================================
for t in t_version t_snapshot_name_format t_now_ts_format t_rsync_has t_dest_helpers t_week_key t_retention_keep t_locking t_config_load t_init_cli t_list t_check t_run_e2e t_prune t_lock_release; do
  $t
done

echo ""
printf '%s tests run: %d passed, %d failed\n' "$((PASS+FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && { printf 'FAILED tests: %s\n' "${FAILED[*]}"; exit 1; }
exit 0