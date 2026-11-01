#!/usr/bin/env bash
# Install unattended nightly APT patching on Ubuntu servers.
set -Eeuo pipefail

PATCH_SCRIPT=/usr/local/sbin/nightly-patch.sh
CRON_FILE=/etc/cron.d/nightly-patch
ROTATE_FILE=/etc/logrotate.d/nightly-patch
APT_POLICY=/etc/apt/apt.conf.d/99-nightly-patch-schedule
HOUR="${PATCH_HOUR:-3}"
MINUTE="${PATCH_MINUTE:-0}"

if (( EUID != 0 )); then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi
if ! grep -qi '^ID=ubuntu\|^ID_LIKE=.*ubuntu' /etc/os-release; then
  echo "This installer is intended for Ubuntu." >&2
  exit 1
fi
if ! [[ "$HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ && "$MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; then
  echo "PATCH_HOUR must be 0-23 and PATCH_MINUTE must be 0-59." >&2
  exit 1
fi
for cmd in apt-get flock logrotate crontab; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd. Install it before running this setup." >&2
    exit 1
  fi
done

# Prevent running two independent copies if the legacy root crontab entry exists.
if crontab -l -u root 2>/dev/null | grep -E '^[[:space:]]*[^#].*/usr/local/sbin/nightly-patch\.sh' >/dev/null; then
  echo "An existing root crontab entry invokes $PATCH_SCRIPT." >&2
  echo "Remove that entry with sudo crontab -e before using this installer to avoid double scheduling." >&2
  exit 1
fi

cat > "$PATCH_SCRIPT" <<'PATCH'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/nightly-patch.log

exec 9>/run/nightly-patch.lock
if ! flock -n 9; then
  echo "Patch run already active, skipping" >&2
  exit 0
fi
exec >>"$LOG" 2>&1
printf '\n========== Patch started: %s (%s) ==========\n' "$(date -Is)" "$(hostname)"
trap 'status=$?; printf "Patch finished: %s; exit status: %s\n" "$(date -Is)" "$status"; exit "$status"' EXIT

# Fail if any configured repository fails, rather than using stale index data.
apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update

# Allow new dependencies (including kernel packages), never package removals.
apt-get -y \
  -o DPkg::Lock::Timeout=600 \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  --no-remove --with-new-pkgs upgrade

# No automatic autoremove: retired kernels/dependencies need separate review.
apt-get clean

if [[ -e /run/reboot-required ]]; then
  echo 'REBOOT REQUIRED (not automatically performed)'
else
  echo 'No reboot required'
fi
apt list --upgradable 2>/dev/null || true
PATCH
chmod 750 "$PATCH_SCRIPT"
chown root:root "$PATCH_SCRIPT"

cat > "$ROTATE_FILE" <<'ROTATE'
/var/log/nightly-patch.log {
    su root root
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
ROTATE
chmod 644 "$ROTATE_FILE"
chown root:root "$ROTATE_FILE"

# CRON_TZ is deliberately not set: use the server's system timezone.
cat > "$CRON_FILE" <<CRON
# Nightly APT patching at ${HOUR}:$(printf '%02d' "$MINUTE") local server time.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$MINUTE $HOUR * * * root $PATCH_SCRIPT
CRON
chmod 644 "$CRON_FILE"
chown root:root "$CRON_FILE"

# Avoid a second, independently scheduled Ubuntu APT updater.
cat > "$APT_POLICY" <<'POLICY'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
POLICY
chmod 644 "$APT_POLICY"
chown root:root "$APT_POLICY"

# Stop/disable stock timers so they do not compete with the cron-based job.
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
  systemctl restart cron.service
fi

bash -n "$PATCH_SCRIPT"
logrotate -d "$ROTATE_FILE" >/dev/null 2>&1
printf 'Installed nightly patching for %s at %02d:%02d server-local time.\n' "$(hostname)" "$HOUR" "$MINUTE"
printf 'Patch log: /var/log/nightly-patch.log\n'
printf 'Run now: sudo %s\n' "$PATCH_SCRIPT"
printf 'No automatic reboot. Ubuntu stock APT timers have been disabled.\n'
