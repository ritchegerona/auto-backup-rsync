#!/usr/bin/env bash
# auto-backup uninstaller — reverses install.sh on Linux (systemd) and macOS (launchd).
# shellcheck shell=bash
set -euo pipefail

DRY=0
PURGE=0

usage() {
  cat <<'EOF'
Uninstall auto-backup.

Usage: uninstall.sh [options]

Options:
  --dry-run   Print actions without executing
  --purge     Also remove config, runtime, and scheduled entries
  -h, --help  This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# Resolve install-time layout the same way install.sh does.
IS_DARWIN=0
uname -s | grep -qi darwin && IS_DARWIN=1

if [ "$(id -u)" = 0 ]; then
  CONFDIR=/etc/auto-backup
  RUNTIME=/var/log/auto-backup
  if [ "$IS_DARWIN" = 1 ] && [ -d /opt/homebrew/bin ]; then
    BINDIR=/opt/homebrew/bin
  else
    BINDIR=/usr/local/bin
  fi
else
  CONFDIR=$HOME/.config/auto-backup
  RUNTIME=$HOME/Library/Logs/auto-backup
  BINDIR=$HOME/bin
fi

log() { printf 'uninstall: %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then
    log "(dry-run) $*"
  else
    "$@"
  fi
}

# --- scheduled entries ----------------------------------------------------------
if [ "$IS_DARWIN" = 1 ]; then
  SCHEDDIR=/Library/LaunchDaemons
  LABEL_PREFIX=com.autobackup
  [ "$(id -u)" != 0 ] && { SCHEDDIR=$HOME/Library/LaunchAgents; LABEL_PREFIX=local.com.autobackup; }
  for plist in "$SCHEDDIR"/"$LABEL_PREFIX".*.plist; do
    [ -e "$plist" ] || continue
    run launchctl unload "$plist" 2>/dev/null || true
    run rm -f "$plist"
    log "removed launchd entries: $plist"
  done
else
  if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
    for t in /etc/systemd/system/auto-backup@*.timer; do
      [ -e "$t" ] || continue
      unit=$(basename "$t")
      run systemctl disable --now "$unit" 2>/dev/null || true
      log "disabled systemd timer: $unit"
    done
    run rm -f /etc/systemd/system/auto-backup@.service /etc/systemd/system/auto-backup@.timer
    run systemctl daemon-reload
  fi
fi

# --- binaries ----------------------------------------------------------------
run rm -f "$BINDIR/auto-backup" "$BINDIR/backup-lib.sh"

# --- config / runtime ----------------------------------------------------------
if [ "$PURGE" = 1 ]; then
  run rm -rf "$CONFDIR"
  [ -d "$RUNTIME" ] && run rm -rf "$RUNTIME"
  log "purged config ($CONFDIR) and runtime ($RUNTIME)"
else
  log "kept config ($CONFDIR) and runtime ($RUNTIME); use --purge to remove"
fi

log "done."