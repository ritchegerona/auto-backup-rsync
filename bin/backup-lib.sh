#!/usr/bin/env bash
# auto-backup — shared library (Linux + macOS, bash 3.2+).
# Sourced by the auto-backup CLI; not meant to be executed directly.
#
# Design notes
#   * Every rsync flag is feature-detected against `rsync --help`, so GNU
#     rsync and Apple's openrsync are both supported and degrade gracefully.
#   * Snapshots live under <DEST>/snapshots/backup-YYYYMMDD-HHMMSS/ and are
#     hard-linked against the newest previous snapshot (--link-dest), so
#     unchanged data costs no extra space and backups are fast.
#   * Transfers are resumable: --partial plus a per-snapshot --partial-dir.
#   * Retention is a deterministic keep-newest-per-bucket policy
#     (daily / weekly / monthly) that is pure string logic, fully testable
#     and portable (no GNU date dependence).
# shellcheck shell=bash

AB_PROG=${AB_PROG:-auto-backup}
AB_VERSION='0.3.0'
export AB_PROG

# --- default paths (overridable via env or -c/-r flags) ------------------
AB_CONFIG_DIR=${AB_CONFIG_DIR:-/etc/auto-backup}
AB_RUNTIME_DIR=${AB_RUNTIME_DIR:-/var/log/auto-backup}
AB_RSYNC_BIN=${AB_RSYNC_BIN:-rsync}

AB_DRY_RUN=${AB_DRY_RUN:-0}
AB_QUIET=${AB_QUIET:-0}
AB_LOG_TO_FILE=1
AB_RSYNC_HELP=""
AB_LOCK_CUR=""
_nl=$'\n'

# --- io -------------------------------------------------------------------
ab_log()   { printf '%s\n' "$*"; }
ab_warn()  { printf '%s: warning: %s\n' "$AB_PROG" "$*" >&2; }
ab_error() { printf '%s: error: %s\n' "$AB_PROG" "$*" >&2; }
ab_fail()  { ab_error "$*"; exit 1; }

ab_now()   { date '+%Y-%m-%d %H:%M:%S %z'; }
ab_now_ts(){ date '+%Y%m%d-%H%M%S'; }
ab_snapshot_name() { printf 'backup-%s\n' "$(ab_now_ts)"; }

ab_log_line() {
  local msg=$*
  [ "$AB_QUIET" != 1 ] && ab_log "$msg"
  if [ "$AB_LOG_TO_FILE" = 1 ]; then
    mkdir -p "$AB_RUNTIME_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(ab_now)" "$msg" >> "$AB_RUNTIME_DIR/auto-backup.log" 2>/dev/null || true
  fi
}

ab_require_tools() {
  if [ ! -x "$AB_RSYNC_BIN" ]; then
    command -v "$AB_RSYNC_BIN" >/dev/null 2>&1 || ab_fail "required tool not found: $AB_RSYNC_BIN"
  fi
  command -v date >/dev/null 2>&1 || ab_fail "required tool not found: date"
}

# Expand an (optionally unset) array variable to stdout, one element per line.
# Safe under bash 3.2 on both Linux and macOS; the ${name[@]+...} guard makes
# it a no-op when the variable is unset.
ab_expand_array() {
  # shellcheck disable=SC2294
  eval 'for _ab_i in "${'"$1"'[@]+"${'"$1"'[@]}"}"; do printf "%s\n" "$_ab_i"; done'
}

# --- rsync capability detection (openrsync vs GNU rsync) ------------------
ab_rsync_help() {
  if [ -z "$AB_RSYNC_HELP" ]; then
    AB_RSYNC_HELP=$("$AB_RSYNC_BIN" --help 2>&1 || true)
  fi
  printf '%s' "$AB_RSYNC_HELP"
}
ab_rsync_has() {
  ab_rsync_help | grep -q -- "--$1"
  return $?
}

# --- locking ---------------------------------------------------------------
# mkdir(2) is atomic on every platform and needs no extra tooling (macOS has
# no flock), so it is used as the lock primitive with PID-based stale
# detection. flock(1) would require a non-portable dependency.
ab_lock_acquire() {
  local name=$1 lk pid
  lk="$AB_RUNTIME_DIR/locks/$name"
  mkdir -p "$AB_RUNTIME_DIR/locks" || ab_fail "cannot create lock dir: $AB_RUNTIME_DIR/locks"
  if mkdir "$lk" 2>/dev/null; then
    printf '%s\n' "$$" > "$lk/pid"
    AB_LOCK_PREV=$AB_LOCK_CUR
    AB_LOCK_CUR="$lk"
    return 0
  fi
  if [ -f "$lk/pid" ]; then
    pid=$(sed 's/[^0-9]//g' "$lk/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      ab_fail "job '$name' is already locked by running process $pid"
    fi
    rm -rf "$lk"
    if mkdir "$lk" 2>/dev/null; then
      printf '%s\n' "$$" > "$lk/pid"
      AB_LOCK_PREV=$AB_LOCK_CUR
      AB_LOCK_CUR="$lk"
      return 0
    fi
  fi
  ab_fail "could not acquire lock for '$name' ($lk)"
}
ab_lock_release() {
  if [ -n "$AB_LOCK_CUR" ]; then
    rm -rf "$AB_LOCK_CUR"
    AB_LOCK_CUR=$AB_LOCK_PREV
    AB_LOCK_PREV=""
  fi
}

# --- config ----------------------------------------------------------------
ab_require_config_dir() {
  [ -d "$AB_CONFIG_DIR/jobs.d" ] || ab_fail "config dir not found: $AB_CONFIG_DIR (run 'auto-backup init' first)"
}
ab_source_global() {
  [ -n "${BACKUP_CONF_SOURCED:-}" ] && return 0
  if [ -f "$AB_CONFIG_DIR/backup.conf" ]; then
    . "$AB_CONFIG_DIR/backup.conf"
  fi
  BACKUP_CONF_SOURCED=1
}
ab_job_config() { printf '%s/jobs.d/%s.conf\n' "$AB_CONFIG_DIR" "$1"; }
ab_job_names() {
  local f
  ab_require_config_dir
  for f in "$AB_CONFIG_DIR"/jobs.d/*.conf; do
    [ -e "$f" ] || continue
    printf '%s\n' "$(basename "$f" .conf)"
  done
}
ab_load_job() {
  local f job=$1
  ab_source_global
  f=$(ab_job_config "$job")
  [ -f "$f" ] || ab_fail "no such job: '$job'"
  . "$f"
  JOB_NAME=$job
}
ab_validate_job() {
  local job=$1
  [ -n "$DEST" ] || ab_fail "job '$job': DEST is not set ($(ab_job_config "$job"))"
  [ -n "${SOURCE+x}" ] || [ -n "${SOURCES+x}" ] || ab_fail "job '$job': set SOURCE or SOURCES"
  : "${RETENTION_DAILY:=7}" "${RETENTION_WEEKLY:=4}" "${RETENTION_MONTHLY:=6}"
  : "${USE_DELETE:=0}" "${USE_CHECKSUM:=0}"
}
ab_sources_of_job() {
  if [ -n "${SOURCES+x}" ]; then
    ab_expand_array SOURCES
  elif [ -n "${SOURCE:-}" ]; then
    printf '%s\n' "$SOURCE"
  fi
}

# --- destination helpers ----------------------------------------------------
ab_dest_is_remote() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }
ab_dest_host() { printf '%s\n' "${1%%:*}"; }
ab_dest_path() { printf '%s\n' "${1#*:}"; }
ab_dest_snaps_root() { printf '%s/snapshots\n' "$1"; }

ab_mkdir_snaps() {
  local dest=$1
  if ab_dest_is_remote "$dest"; then
    ssh -o BatchMode=yes "$(ab_dest_host "$dest")" "mkdir -p '$(ab_dest_path "$dest")/snapshots'" \
      || ab_fail "cannot create remote snapshot dir ($dest)"
  else
    mkdir -p "$(ab_dest_snaps_root "$dest")" || ab_fail "cannot create snapshot dir on $dest"
  fi
}

ab_list_snapshots() {
  local dest=$1
  if ab_dest_is_remote "$dest"; then
    ssh -o BatchMode=yes "$(ab_dest_host "$dest")" \
      "ls -dr '$(ab_dest_path "$dest")/snapshots'/backup-* 2>/dev/null" 2>/dev/null \
      | sed 's#.*/##' | grep -E '^backup-'
    return 0
  fi
  [ -d "$(ab_dest_snaps_root "$dest")" ] || return 0
  ls -1 "$(ab_dest_snaps_root "$dest")" 2>/dev/null | grep -E '^backup-'
}
ab_all_snapshots_sorted() { ab_list_snapshots "$1" | sort; }
ab_newest_snapshot() { ab_all_snapshots_sorted "$1" | tail -n 1; }

ab_remove_snapshot() {
  local dest=$1 name=$2
  if ab_dest_is_remote "$dest"; then
    ssh -o BatchMode=yes "$(ab_dest_host "$dest")" "rm -rf -- '$(ab_dest_path "$dest")/snapshots/$name'"
  elif [ -d "$(ab_dest_snaps_root "$dest")/$name" ]; then
    rm -rf -- "$(ab_dest_snaps_root "$dest")/$name"
  fi
}

# --- rsync command build ----------------------------------------------------
ab_compose_rsync_args() {
  local src=$1 newname=$2 prev=$3 ld
  AB_RSYNC_ARGS=( -a --partial )
  if ab_rsync_has partial-dir; then
    AB_RSYNC_ARGS+=(--partial-dir=.rsync-partial)
  fi
  if ab_rsync_has append-verify; then
    AB_RSYNC_ARGS+=(--append-verify)
  fi
  if [ "${USE_CHECKSUM:-0}" = 1 ] && ab_rsync_has checksum; then
    AB_RSYNC_ARGS+=(--checksum)
  fi
  if [ -n "$prev" ] && ab_rsync_has link-dest; then
    if ab_dest_is_remote "$DEST"; then
      ld="snapshots/$prev"
    else
      ld="$(ab_dest_snaps_root "$DEST")/$prev"
    fi
    AB_RSYNC_ARGS+=(--link-dest="$ld")
  fi
  while IFS= read -r e; do
    [ -n "$e" ] && AB_RSYNC_ARGS+=(--exclude="$e")
  done <<< "$(ab_expand_array EXCLUDES)"
  while IFS= read -r e; do
    [ -n "$e" ] && AB_RSYNC_ARGS+=(--exclude-from="$e")
  done <<< "$(ab_expand_array EXCLUDE_FILES)"
  [ "${USE_DELETE:-0}" = 1 ] && AB_RSYNC_ARGS+=(--delete)
  while IFS= read -r e; do
    [ -n "$e" ] && AB_RSYNC_ARGS+=("$e")
  done <<< "$(ab_expand_array RSYNC_OPTIONS)"
}

ab_run_rsync() {
  local src=$1 deststr=$2
  if [ "$AB_DRY_RUN" = 1 ]; then
    ab_log "  (dry-run) rsync ${AB_RSYNC_ARGS[*]} '$src' '$deststr'"
    return 0
  fi
  "$AB_RSYNC_BIN" "${AB_RSYNC_ARGS[@]}" "$src" "$deststr"
}

# --- retention (keep-newest-per-bucket; pure and portable) -------------------
# Reads snapshot names (backup-YYYYMMDD-HHMMSS) from stdin in any order,
# sorts them newest-first internally, and prints the snapshots to KEEP.
# Snapshot names are compared lexically, so no epoch arithmetic is needed.
ab_retention_keep() {
  local daily=$1 weekly=$2 monthly=$3
  local s daykey monthkey weekkey
  local keep seen_d seen_w seen_m
  local dcount wcount mcount add
  dcount=0; wcount=0; mcount=0
  keep=""; seen_d=""; seen_w=""; seen_m=""
  while read -r s; do
    [ -n "$s" ] || continue
    daykey=${s:7:8}
    monthkey=${s:7:6}
    weekkey=$(ab_week_key "$daykey")
    add=0
    if [ "$daily" -gt 0 ] 2>/dev/null && [ "$dcount" -lt "$daily" ] \
       && ! printf '%s\n' "$seen_d" | grep -Fqx "$daykey"; then
      add=1
      seen_d="$seen_d$_nl$daykey"; dcount=$((dcount + 1))
    elif [ "$weekly" -gt 0 ] 2>/dev/null && [ "$wcount" -lt "$weekly" ] \
       && ! printf '%s\n' "$seen_w" | grep -Fqx "$weekkey"; then
      add=1
      seen_w="$seen_w$_nl$weekkey"; wcount=$((wcount + 1))
    elif [ "$monthly" -gt 0 ] 2>/dev/null && [ "$mcount" -lt "$monthly" ] \
       && ! printf '%s\n' "$seen_m" | grep -Fqx "$monthkey"; then
      add=1
      seen_m="$seen_m$_nl$monthkey"; mcount=$((mcount + 1))
    fi
    [ "$add" = 1 ] && keep="$keep$_nl$s"
  done < <(sort -r)
  printf '%s\n' "$keep" | grep -E '^backup-' | sort -u
}

# ISO week key (YYYY-Www) for a YYYYMMDD date; works with GNU and BSD date.
ab_week_key() {
  local d=$1 w
  if w=$(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%G-W%V 2>/dev/null); then
    printf '%s\n' "$w"
  elif w=$(date -j -f "%Y%m%d" "$d" +%G-W%V 2>/dev/null); then
    printf '%s\n' "$w"
  else
    printf '%s\n' "$d"
  fi
}

# --- pruning ----------------------------------------------------------------
ab_prune_job() {
  local job=$1 all keep del s
  ab_load_job "$job"
  ab_validate_job "$job"
  ab_lock_acquire "prune-$job"
  trap ab_lock_release EXIT
  all=$(ab_all_snapshots_sorted "$DEST")
  if [ -z "$all" ]; then
    ab_log "job '$job': no snapshots to prune"
    ab_lock_release
    trap - EXIT
    return 0
  fi
  keep=$(printf '%s\n' "$all" | ab_retention_keep "$RETENTION_DAILY" "$RETENTION_WEEKLY" "$RETENTION_MONTHLY")
  del=$(comm -23 <(printf '%s\n' "$all" | sort -u) \
                  <(printf '%s\n' "$keep" | grep -E '^backup-' | sort -u))
  if [ -n "$del" ]; then
    ab_log "job '$job': pruning $(printf '%s\n' "$del" | wc -l | tr -d ' ') snapshot(s) (keeping $(printf '%s\n' "$keep" | grep -cE '^backup-'))"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$AB_DRY_RUN" = 1 ]; then
        ab_log "  (dry-run) would remove $s"
      else
        ab_remove_snapshot "$DEST" "$s" || ab_warn "failed to remove $s"
      fi
    done <<< "$del"
  else
    ab_log "job '$job': nothing to prune (keeping $(printf '%s\n' "$keep" | grep -cE '^backup-'))"
  fi
  ab_lock_release
  trap - EXIT
  return 0
}

# --- hooks ------------------------------------------------------------------
ab_run_hook() {
  local kind=$1 cmd=$2
  if [ -n "$cmd" ]; then
    ab_log "  hook($kind): $cmd"
    eval "$cmd" || { ab_error "hook($kind) failed: $cmd"; return 1; }
  fi
  return 0
}

# --- status -----------------------------------------------------------------
ab_status_path() { printf '%s/state/%s.status\n' "$AB_RUNTIME_DIR" "$1"; }
ab_status_write() {
  local job=$1 st=$2 snap=$3 secs=$4
  mkdir -p "$AB_RUNTIME_DIR/state"
  {
    printf 'last_run=%s\n' "$(ab_now)"
    printf 'state=%s\n' "$st"
    printf 'snapshot=%s\n' "$snap"
    printf 'duration_sec=%s\n' "$secs"
  } > "$(ab_status_path "$job")"
}
ab_status_read() {
  local f
  f=$(ab_status_path "$1")
  if [ -f "$f" ]; then
    cat "$f"
  else
    printf 'no status recorded for job %s\n' "$1"
  fi
}

# --- run ---------------------------------------------------------------------
ab_run_job() {
  local job=$1 src run_rc snapnew prev deststr st taken
  run_rc=0
  ab_log_line "job '$job': starting"
  ab_load_job "$job"
  ab_validate_job "$job"
  ab_require_tools
  ab_lock_acquire "job-$job"
  trap ab_lock_release EXIT
  ab_mkdir_snaps "$DEST"
  prev=$(ab_newest_snapshot "$DEST")
  snapnew=$(ab_snapshot_name)
  ab_log_line "job '$job': dest=$DEST snapshot=$snapnew previous=${prev:-none} dry_run=$AB_DRY_RUN"

  while IFS= read -r e; do
    ab_run_hook pre "$e" || run_rc=1
  done <<< "$(ab_expand_array HOOK_PRE)"

  taken=$(date +%s)
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    ns="$src"
    [ -d "$src" ] && ns="${src%/}/"
    ab_compose_rsync_args "$ns" "$snapnew" "$prev"
    deststr="$(ab_dest_snaps_root "$DEST")/$snapnew/"
    ab_log_line "job '$job': rsync ${AB_RSYNC_ARGS[*]} '$ns' -> '$deststr'"
    if ! ab_run_rsync "$ns" "$deststr"; then
      run_rc=1
      break
    fi
  done <<< "$(ab_sources_of_job)"
  taken=$(( $(date +%s) - taken ))

  if [ "$run_rc" = 0 ]; then
    if ! ab_dest_is_remote "$DEST"; then
      rm -f -- "$DEST/current" 2>/dev/null
      rm -rf -- "$DEST/current" 2>/dev/null || true
      ln -sfn "snapshots/$snapnew" "$DEST/current"
    fi
    while IFS= read -r e; do
      ab_run_hook post "$e" || run_rc=1
    done <<< "$(ab_expand_array HOOK_POST)"
    [ "$run_rc" = 0 ] && ab_prune_job "$job"
    trap ab_lock_release EXIT
    st=ok
  else
    st=failed
    if ! ab_dest_is_remote "$DEST"; then
      rm -rf -- "$(ab_dest_snaps_root "$DEST")/$snapnew"
    fi
    while IFS= read -r e; do
      ab_run_hook on-failure "$e" || true
    done <<< "$(ab_expand_array ON_FAILURE)"
  fi

  ab_status_write "$job" "$st" "$snapnew" "$taken"
  ab_log_line "job '$job': state=$st snapshot=$snapnew duration=${taken}s"
  ab_lock_release
  trap - EXIT
  [ "$st" = ok ] && return 0 || return 1
}

# --- check / list --------------------------------------------------------------
ab_check_job() {
  local job=$1 src ns fail
  fail=0
  ab_load_job "$job"
  ab_validate_job "$job"
  ab_require_tools
  ab_mkdir_snaps "$DEST" || fail=1
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    [ -e "$src" ] || { ab_error "job '$job': source missing: $src"; fail=1; continue; }
    ns="$src"
    [ -d "$src" ] && ns="${src%/}/"
    ab_compose_rsync_args "$ns" "__check__" ""
    if "$AB_RSYNC_BIN" -n "${AB_RSYNC_ARGS[@]}" "$ns" "$(ab_dest_snaps_root "$DEST")/__check__/" >/dev/null 2>&1; then
      ab_log "job '$job': ok  $ns -> $DEST"
    else
      ab_error "job '$job': rsync check failed for '$ns' -> '$DEST'"
      fail=1
    fi
  done <<< "$(ab_sources_of_job)"
  return $fail
}

ab_list_jobs() {
  local job
  ab_require_config_dir
  for job in $(ab_job_names); do
    (
      BACKUP_CONF_SOURCED=""
      if ab_load_job "$job" 2>/dev/null && ab_validate_job "$job" 2>/dev/null; then
        printf '%-20s %-36s -> %s\n' "$job" "$(ab_sources_of_job | tr '\n' ',' | sed 's/,$//')" "$DEST"
      else
        printf '%-20s <config error>\n' "$job"
      fi
    )
  done
}

ab_version() { printf '%s %s\n' "$AB_PROG" "$AB_VERSION"; }