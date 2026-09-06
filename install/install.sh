#!/usr/bin/env bash
# auto-backup installer — Linux (systemd timers) and macOS (launchd agents).
# Runs as root for system-wide install; falls back to per-user install otherwise.
# shellcheck shell=bash
set -euo pipefail

AB_PROG=auto-backup
NO_SCHED=0
DRY=0

usage() {
  cat <<'EOF'
Install auto-backup.

Usage: install.sh [options]

Options:
  --prefix DIR      Install prefix (Linux default /usr/local, Darwin /opt/homebrew if present)
  --no-scheduler    Install binaries/config only; skip systemd/launchd
  --dry-run         Print actions without executing
  -h, --help        This help

System-wide (root):   config /etc/auto-backup, runtime /var/log/auto-backup, launchd /Library/LaunchDaemons
Per-user (non-root):  config ~/.config/auto-backup, runtime ~/Library/Logs/auto-backup, launchd ~/Library/LaunchAgents
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=$2; shift 2 ;;
    --no-scheduler) NO_SCHED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IS_DARWIN=0
uname -s | grep -qi darwin && IS_DARWIN=1

if [ "$(id -u)" = 0 ]; then
  CONFDIR=${CONFDIR:-/etc/auto-backup}
  RUNTIME=${RUNTIME:-/var/log/auto-backup}
  if [ -n "${PREFIX:-}" ]; then
    BINDIR=$PREFIX/bin
  elif [ "$IS_DARWIN" = 1 ] && [ -d /opt/homebrew/bin ]; then
    BINDIR=/opt/homebrew/bin
  else
    BINDIR=/usr/local/bin
  fi
else
  CONFDIR=${CONFDIR:-$HOME/.config/auto-backup}
  RUNTIME=${RUNTIME:-$HOME/Library/Logs/auto-backup}
  BINDIR=${PREFIX:-$HOME}/bin
fi

log() { printf 'install: %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then
    log "(dry-run) $*"
  else
    "$@"
  fi
}

mkdir -p "$BINDIR" "$CONFDIR/jobs.d" "$RUNTIME/locks" "$RUNTIME/state"
run install -m 755 "$ROOT/bin/backup.sh" "$BINDIR/auto-backup"
run install -m 755 "$ROOT/bin/backup-lib.sh" "$BINDIR/backup-lib.sh"

if [ -f "$ROOT/etc/backup.conf" ] && [ ! -e "$CONFDIR/backup.conf" ]; then
  run install -m 644 "$ROOT/etc/backup.conf" "$CONFDIR/backup.conf"
fi
for f in "$ROOT"/etc/jobs.d/*.conf; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  if [ ! -e "$CONFDIR/jobs.d/$n" ]; then
    run install -m 644 "$f" "$CONFDIR/jobs.d/$n"
  fi
done

# --- scheduling ---------------------------------------------------------------
if [ "$NO_SCHED" = 1 ]; then
  log "skipping scheduler (--no-scheduler)"
  log "binaries : $BINDIR"
  log "config   : $CONFDIR"
  log "runtime  : $RUNTIME"
  exit 0
fi

if [ "$IS_DARWIN" = 1 ]; then
  SCHEDDIR=/Library/LaunchDaemons
  [ "$(id -u)" != 0 ] && SCHEDDIR=$HOME/Library/LaunchAgents
  LABEL_PREFIX=com.autobackup
  [ "$(id -u)" != 0 ] && LABEL_PREFIX=local.com.autobackup
  TPL="$ROOT/install/launchd/com.autobackup.job.plist.in"
  JOBS=()
  for f in "$CONFDIR"/jobs.d/*.conf; do
    [ -e "$f" ] || continue
    JOBS+=("$(basename "$f" .conf)")
  done
  if [ ${#JOBS[@]} -eq 0 ]; then
    log "no jobs defined — skipping launchd registration (define jobs in $CONFDIR/jobs.d)"
  else
    run mkdir -p "$SCHEDDIR"
    for job in "${JOBS[@]}"; do
      minute=$(( $(printf '%s' "$job" | cksum | awk '{print $1}') % 55 ))
      plist="$SCHEDDIR/$LABEL_PREFIX.$job.plist"
      run sed -e "s/@JOB@/$job/g" \
              -e "s/@LABEL@/$LABEL_PREFIX.$job/g" \
              -e "s|@BINDIR@|$BINDIR|g" \
              -e "s|@LOGDIR@|$RUNTIME|g" \
              -e "s/@HOUR@/3/g" \
              -e "s/@MINUTE@/$minute/g" \
              "$TPL" > "$plist"
      run launchctl unload "$plist" 2>/dev/null || true
      run launchctl load "$plist"
      log "registered launchd agent: $plist (runs daily at 03:$minute)"
    done
  fi
elif command -v systemctl >/dev/null 2>&1; then
  if [ "$(id -u)" != 0 ]; then
    log "systemd unit installation requires root (re-run with sudo) — skipping"
  else
    run install -m 644 "$ROOT/install/systemd/auto-backup@.service" /etc/systemd/system/auto-backup@.service
    run install -m 644 "$ROOT/install/systemd/auto-backup@.timer" /etc/systemd/system/auto-backup@.timer
    run systemctl daemon-reload
    for f in "$CONFDIR"/jobs.d/*.conf; do
      [ -e "$f" ] || continue
      job=$(basename "$f" .conf)
      run systemctl enable --now "auto-backup@$job.timer"
      log "enabled systemd timer: auto-backup@$job.timer"
    done
  fi
else
  log "no systemd or launchd found — schedule manually (e.g. cron): $BINDIR/auto-backup run all"
fi

log "done."
log "  binaries : $BINDIR/auto-backup"
log "  config   : $CONFDIR"
log "  runtime  : $RUNTIME"
log "  try      : $BINDIR/auto-backup list && $BINDIR/auto-backup check JOB"