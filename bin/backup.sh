#!/usr/bin/env bash
# auto-backup — CLI entrypoint. Linux + macOS.
# shellcheck shell=bash
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
. "$SCRIPT_DIR/backup-lib.sh"

usage() {
  cat <<'EOF'
auto-backup — automated, resumable rsync snapshots with retention.

Usage: auto-backup [options] <command> [args]

Commands:
  run    [JOB ...] [--dry-run]   Run backup for one job, several, or all (default)
  prune  [JOB ...] [--dry-run]   Apply retention policy (kept count per job)
  check  [JOB ...]               Validate config and test sources/destination
  list                            List configured jobs and their destinations
  status [JOB ...]                Show last-run status for jobs
  init   [--force]                Scaffold config dirs and sample jobs
  version                         Print version

Options:
  -c DIR   Config dir   (default: /etc/auto-backup)
  -r DIR   Runtime dir  (default: /var/log/auto-backup)
  -q       Quiet (log to file only)

Examples:
  auto-backup run docs                # run one job
  auto-backup run --dry-run all       # simulate everything
  auto-backup prune home --dry-run    # show what retention would remove
  auto-backup check web               # verify a job end to end
EOF
}

main() {
  local cmd args
  parse_global "$@"
  set -- "${AB_ARGS[@]}"
  cmd=${1:-run}
  shift || true
  case "$cmd" in
    run)    ab_cmd_run "$@" ;;
    prune)  ab_cmd_prune "$@" ;;
    check)  ab_cmd_check "$@" ;;
    list)   ab_cmd_list "$@" ;;
    status) ab_cmd_status "$@" ;;
    init)   ab_cmd_init "$@" ;;
    version|-V) ab_version ;;
    help|-h|--help) usage; exit 0 ;;
    *)      usage; exit 2 ;;
  esac
}

parse_global() {
  local a i=1
  AB_ARGS=()
  while [ $i -le $# ]; do
    a=${!i}
    case "$a" in
      -c) i=$((i + 1)); AB_CONFIG_DIR=${!i} ;;
      -r) i=$((i + 1)); AB_RUNTIME_DIR=${!i} ;;
      -q) AB_QUIET=1 ;;
      *)  AB_ARGS+=("$a") ;;
    esac
    i=$((i + 1))
  done
}

# --- command implementations ---------------------------------------------------
ab_job_targets() {
  # expands CLI job args into an explicit list; "all" (or nothing) means every job
  local x want
  if [ $# -eq 0 ]; then
    ab_job_names
    return 0
  fi
  for want in "$@"; do
    if [ "$want" = all ]; then
      ab_job_names
    else
      printf '%s\n' "$want"
    fi
  done
}

ab_cmd_run() {
  local arg rc=0 j
  AB_DRY_RUN=0
  AB_TARGETS=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) AB_DRY_RUN=1 ;;
      -*) usage >&2; exit 2 ;;
      *)  AB_TARGETS+=("$arg") ;;
    esac
  done
  for j in $(ab_job_targets "${AB_TARGETS[@]}"); do
    ab_run_job "$j" || rc=1
  done
  return $rc
}

ab_cmd_prune() {
  local arg rc=0 j
  AB_DRY_RUN=0
  AB_TARGETS=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) AB_DRY_RUN=1 ;;
      -*) usage >&2; exit 2 ;;
      *)  AB_TARGETS+=("$arg") ;;
    esac
  done
  for j in $(ab_job_targets "${AB_TARGETS[@]}"); do
    ab_prune_job "$j" || rc=1
  done
  return $rc
}

ab_cmd_check() {
  local arg rc=0 j
  AB_TARGETS=()
  for arg in "$@"; do
    case "$arg" in
      -*) usage >&2; exit 2 ;;
      *)  AB_TARGETS+=("$arg") ;;
    esac
  done
  for j in $(ab_job_targets "${AB_TARGETS[@]}"); do
    ab_check_job "$j" || rc=1
  done
  return $rc
}

ab_cmd_list() { ab_list_jobs; }

ab_cmd_status() {
  local j
  if [ $# -eq 0 ]; then
    for j in $(ab_job_names); do
      printf '%s:\n' "$j"
      ab_status_read "$j"
    done
  else
    for j in "$@"; do
      ab_status_read "$j"
    done
  fi
}

ab_cmd_init() {
  local force=0 arg src f
  for arg in "$@"; do
    [ "$arg" = --force ] && force=1
  done
  mkdir -p "$AB_CONFIG_DIR/jobs.d" "$AB_RUNTIME_DIR/locks" "$AB_RUNTIME_DIR/state"
  src="$(dirname "$SCRIPT_DIR")/etc"
  if [ -f "$src/backup.conf" ]; then
    install -m 644 "$src/backup.conf" "$AB_CONFIG_DIR/backup.conf" 2>/dev/null || true
  fi
  if [ "$force" = 1 ] || [ -z "$(ls -A "$AB_CONFIG_DIR/jobs.d" 2>/dev/null)" ]; then
    for f in "$src"/jobs.d/*.conf; do
      [ -e "$f" ] || continue
      if [ -e "$AB_CONFIG_DIR/jobs.d/$(basename "$f")" ] && [ "$force" != 1 ]; then
        continue
      fi
      cp "$f" "$AB_CONFIG_DIR/jobs.d/" && chmod 644 "$AB_CONFIG_DIR/jobs.d/$(basename "$f")"
    done
  fi
  printf '%s initialized.\n  config : %s\n  runtime: %s\n\nEdit the jobs under %s/jobs.d/, then run:\n  %s check JOB\n  %s run JOB\n' \
    "$AB_PROG" "$AB_CONFIG_DIR" "$AB_RUNTIME_DIR" "$AB_CONFIG_DIR" "$AB_PROG" "$AB_PROG"
}

main "$@"