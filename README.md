<p align="center"><img src="assets/logo.png" width="480" alt="auto-backup rsync logo"></p>

# auto-backup

Automated, resumable Linux and macOS backups with rsync, systemd timers, and launchd agents.

## Features

- **Resumable transfers** — `--partial` + `--partial-dir` lets rsync resume interrupted backups from where they left off. On GNU rsync, `--append-verify` adds checksum-based verification for appended data.
- **Hard-linked snapshots** — `--link-dest` against the previous snapshot means unchanged files cost zero extra space. Backups are fast and storage-efficient.
- **Retention policy** — keep-newest-per-bucket: daily, weekly, and monthly. Fully deterministic, no GNU date dependency.
- **Feature detection** — every rsync flag is checked against `rsync --help` at runtime. Works with both GNU rsync and Apple's openrsync. Install GNU rsync (`brew install rsync`) for full dedup and resume support on macOS.
- **Portable locking** — `mkdir`-based lock directories (no `flock` dependency). Works on Linux and macOS.
- **Remote destinations** — back up to `user@host:/path` over SSH. Pruning executes over the same SSH channel.
- **Hooks and notifications** — run pre/post commands, send alerts via ntfy, email, or webhook on failure.
- **Systemd + launchd** — install systemd timers (Linux) or launchd agents (macOS) automatically, or schedule via cron.

## Requirements

- `rsync` (GNU or openrsync)
- `bash` 3.2+
- `ssh` (for remote destinations only)
- `shellcheck` (optional, for linting)

## Quick Start

```bash
# Install (system-wide or per-user)
./install/install.sh

# Or manual setup:
mkdir -p /etc/auto-backup/jobs.d
cp etc/backup.conf /etc/auto-backup/
cp etc/jobs.d/*.conf /etc/auto-backup/jobs.d/

# Scaffold config and runtime dirs (per-user)
auto-backup init

# Edit a job
vim /etc/auto-backup/jobs.d/myjob.conf

# Validate
auto-backup check myjob

# Run
auto-backup run myjob

# Dry-run
auto-backup run myjob --dry-run
```

## Configuration

### Global defaults (`/etc/auto-backup/backup.conf`)

```bash
RETENTION_DAILY=7       # keep newest snapshot per day for 7 days
RETENTION_WEEKLY=4      # keep newest per week for 4 weeks
RETENTION_MONTHLY=6     # keep newest per month for 6 months
USE_DELETE=0            # 1 = mirror source deletions into snapshots
USE_CHECKSUM=0          # 1 = force checksum comparison (slower)
```

### Job configs (`/etc/auto-backup/jobs.d/<name>.conf`)

Each file defines one backup job. Sourced as bash.

| Key | Required | Description |
|-----|----------|-------------|
| `SOURCE` | yes* | Single source path |
| `SOURCES` | yes* | Array of source paths (alternative to `SOURCE`) |
| `DEST` | yes | Destination. Local: `/mnt/backup`. Remote: `user@host:/backups` |
| `EXCLUDES` | no | Array of rsync exclude patterns |
| `EXCLUDE_FILES` | no | Array of paths to `--exclude-from` files |
| `USE_DELETE` | no | Override `USE_DELETE` per job |
| `USE_CHECKSUM` | no | Override `USE_CHECKSUM` per job |
| `RSYNC_OPTIONS` | no | Array of extra rsync flags |
| `HOOK_PRE` | no | Array of commands to run before backup |
| `HOOK_POST` | no | Array of commands to run after successful backup |
| `ON_FAILURE` | no | Array of commands to run on failure |

\* Either `SOURCE` or `SOURCES` must be set.

### Example: local job

```bash
SOURCE="$HOME/Documents"
DEST=/Volumes/Backup/personal
EXCLUDES=(".DS_Store" "node_modules" "Library/Caches")
```

### Example: remote job

```bash
SOURCE=/srv/www
DEST=backup@backup.example.com:/backups/www
EXCLUDES=("*" "*.log" "cache/")
ON_FAILURE=("curl -fsS -m 10 -H 'Title: backup failed' -d 'job www failed' ntfy.sh/YOUR-TOPIC")
```

## How It Works

### Snapshot layout

```
DEST/
├── current -> snapshots/backup-20260906-120000
└── snapshots/
    ├── backup-20260906-120000/    ← newest
    ├── backup-20260905-120000/
    └── backup-20260901-120000/
```

`current` is a symlink at the destination root pointing to the newest snapshot. rsync's `--link-dest` hard-links unchanged files against the previous snapshot, so only changed data consumes new space.

### Resumability

If a transfer is interrupted, rsync's `--partial-dir=.rsync-partial` preserves partially transferred data. On the next run, rsync resumes from where it left off. On GNU rsync (including Homebrew's), `--append-verify` verifies file integrity during resume.

### Retention

`auto-backup prune <job>` applies keep-newest-per-bucket retention:

1. Walk snapshots newest-to-oldest
2. For each distinct day (up to `RETENTION_DAILY`): keep the newest snapshot
3. For each distinct ISO week (up to `RETENTION_WEEKLY`): keep the newest snapshot
4. For each distinct month (up to `RETENTION_MONTHLY`): keep the newest snapshot
5. Delete everything else

```bash
# Show what would be pruned
auto-backup prune myjob --dry-run

# Actually prune
auto-backup prune myjob
```

Pruning runs automatically after each successful backup.

## Scheduling

### systemd (Linux, root required)

```bash
# Install timer (done by install.sh for each job in jobs.d/)
systemctl enable --now auto-backup@myjob.timer

# Check status
systemctl status auto-backup@myjob.timer
systemctl list-timers --all | grep auto-backup

# Run manually
systemctl start auto-backup@myjob.service
```

### launchd (macOS)

```bash
# Install (done by install.sh)
# Plists installed to:
#   root: /Library/LaunchDaemons/com.autobackup.<job>.plist
#   user: ~/Library/LaunchAgents/local.com.autobackup.<job>.plist

# Manual load
launchctl load /Library/LaunchDaemons/com.autobackup.myjob.plist
launchctl list | grep auto-backup
```

### Cron fallback

```bash
# /etc/crontab (system-wide, randomized minute)
3 3 * * * root /usr/local/bin/auto-backup run all
```

## Remote Backups

Remote destinations use rsync over SSH. Pruning executes over the same SSH channel to delete old snapshots on the remote host.

**Requirements:**
- Passwordless SSH key authentication
- SSH host key already in `known_hosts`

```bash
# Test connectivity
auto-backup check remotejob

# Dry-run
auto-backup run remotejob --dry-run
```

## Notifications and Hooks

```bash
# In job config:
HOOK_PRE=("systemd-notify --status='backup starting'")
HOOK_POST=("systemd-notify --status='backup complete'")
ON_FAILURE=(
  "curl -fsS -m 10 -H 'Title: backup failed' -d 'job %j failed at $(date)' ntfy.sh/YOUR-TOPIC"
  "mail -s 'auto-backup failed' root@localhost <<< 'Job failed'"
)
```

## Uninstall

```bash
./install/uninstall.sh           # remove binaries, keep config
./install/uninstall.sh --purge   # remove everything
./install/uninstall.sh --dry-run # preview actions
```

## Troubleshooting

- **Stale lock**: If a backup was interrupted, the lock file may persist. Remove it: `rm -rf /var/log/auto-backup/locks/job-<name>`
- **openrsync limitations**: Apple's openrsync lacks `--append-verify`. Install GNU rsync for full support: `brew install rsync`
- **Shellcheck**: Run `shellcheck bin/*.sh` to lint. Config variables are suppressed via `.shellcheckrc`.
- **Verbose output**: Remove `-q` from the CLI or set `AB_QUIET=0` to see log output on stdout.
- **Debugging**: Check `/var/log/auto-backup/auto-backup.log` and `auto-backup status <job>` for last-run details.

## License

MIT