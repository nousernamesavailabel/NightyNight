#!/usr/bin/env bash
# Cross-distribution nightly patching installer. Run as root.
set -Eeuo pipefail

SCRIPT=/usr/local/sbin/nightly-patch.sh
CRON=/etc/cron.d/nightly-patch
ROTATE=/etc/logrotate.d/nightly-patch
CONFIG=/etc/default/nightly-patch
APT_POLICY=/etc/apt/apt.conf.d/99-nightly-patch-schedule
HOUR=${PATCH_HOUR:-3}
MINUTE=${PATCH_MINUTE:-0}
DISABLE_NATIVE_UPDATERS=${DISABLE_NATIVE_UPDATERS:-1}

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run with sudo/root.'
[[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
# shellcheck disable=SC1091
source /etc/os-release
case ${ID,,} in
  ubuntu|debian) FAMILY=apt ;;
  fedora|rhel|rocky|almalinux|ol|centos) FAMILY=dnf ;;
  *) fail "Unsupported distribution: ${ID:-unknown}" ;;
esac
[[ $HOUR =~ ^([0-9]|1[0-9]|2[0-3])$ && $MINUTE =~ ^([0-9]|[1-9]|[1-5][0-9])$ ]] || fail 'PATCH_HOUR must be 0-23 and PATCH_MINUTE 0-59.'
[[ $DISABLE_NATIVE_UPDATERS =~ ^[01]$ ]] || fail 'DISABLE_NATIVE_UPDATERS must be 0 or 1.'
for command_name in flock logrotate crontab; do
  command -v "$command_name" >/dev/null || fail "Missing prerequisite: $command_name (install util-linux, logrotate, and cron/cronie first)."
done
if [[ $FAMILY == apt ]]; then
  command -v apt-get >/dev/null || fail 'apt-get missing.'
else
  command -v dnf >/dev/null || fail 'dnf missing.'
fi
if crontab -u root -l 2>/dev/null | grep -Eq '^[[:space:]]*[^#].*/usr/local/sbin/nightly-patch\.sh([[:space:]]|$)'; then
  fail "Existing root crontab runs $SCRIPT; remove its entry with sudo crontab -e to avoid duplicate scheduling."
fi

# Keep runtime OS detection in the patcher so a copy cannot silently patch a wrong OS.
cat > "$SCRIPT" <<'PATCHER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
[[ $EUID -eq 0 ]] || { echo 'Must run as root' >&2; exit 1; }
source /etc/os-release
case ${ID,,} in
  ubuntu|debian) FAMILY=apt ;;
  fedora|rhel|rocky|almalinux|ol|centos) FAMILY=dnf ;;
  *) echo "Unsupported distribution: $ID" >&2; exit 1 ;;
esac
exec 9>/run/nightly-patch.lock
flock -n 9 || { echo 'Another nightly-patch run is active' >&2; exit 0; }
LOG=/var/log/nightly-patch.log
exec >>"$LOG" 2>&1
printf '\n========== Started %s on %s (%s) ==========\n' "$(date -Is)" "$(hostname)" "$ID"
trap 'rc=$?; printf "Finished %s; exit code %s\n" "$(date -Is)" "$rc"; exit "$rc"' EXIT
if [[ $FAMILY == apt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update
  apt-get -y -o DPkg::Lock::Timeout=600 \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      --no-remove --with-new-pkgs upgrade
  apt-get clean
  if [[ -e /run/reboot-required ]]; then
    echo 'REBOOT REQUIRED (no automatic reboot)'
  else
    echo 'No reboot flag detected'
  fi
  apt list --upgradable 2>/dev/null || true
else
  # DNF 4/5: refresh metadata and install available packages. Do not run autoremove.
  # obsoletes=False reduces automatic replacement/removal, but does not guarantee
  # an upgrade will never remove an RPM. Review transactions on critical hosts.
  dnf --refresh -y --setopt=obsoletes=False upgrade
  if command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r; then
      echo 'No reboot indicated by needs-restarting'
    else
      echo 'REBOOT MAY BE REQUIRED (no automatic reboot)'
    fi
  else
    echo 'Reboot status unavailable: needs-restarting not installed'
  fi
  # Exit codes from check-update are 0 (none), 100 (available), or errors.
  dnf check-update || status=$?
  if [[ ${status:-0} -ne 0 && ${status:-0} -ne 100 ]]; then
    echo "WARNING: dnf check-update returned ${status}" >&2
  fi
fi
PATCHER
chown root:root "$SCRIPT"
chmod 0750 "$SCRIPT"
bash -n "$SCRIPT"

# Shared logrotate config. Debian and RHEL may have different admin groups.
cat > "$ROTATE" <<'LOGROTATE'
/var/log/nightly-patch.log {
    su root root
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGROTATE
chown root:root "$ROTATE"
chmod 0644 "$ROTATE"
logrotate -d "$ROTATE" >/dev/null 2>&1 || fail 'Logrotate configuration invalid.'

# Record configuration and deploy an /etc/cron.d entry, without editing root's crontab.
printf 'PATCH_HOUR=%s\nPATCH_MINUTE=%s\n' "$HOUR" "$MINUTE" > "$CONFIG"
chown root:root "$CONFIG"
chmod 0644 "$CONFIG"
cat > "$CRON" <<EOFCRON
# Managed by install-nightly-patching-universal.sh; server-local timezone.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$MINUTE $HOUR * * * root $SCRIPT
EOFCRON
chown root:root "$CRON"
chmod 0644 "$CRON"

if [[ $DISABLE_NATIVE_UPDATERS == 1 ]]; then
  if [[ $FAMILY == apt ]]; then
    cat > "$APT_POLICY" <<'POLICY'
// Managed by install-nightly-patching-universal.sh.
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::AutocleanInterval "0";
POLICY
    chmod 0644 "$APT_POLICY"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if [[ $FAMILY == apt ]]; then
      units=(apt-daily.timer apt-daily-upgrade.timer)
    else
      units=(dnf-automatic.timer dnf-automatic-install.timer dnf-automatic-download.timer dnf-automatic-notifyonly.timer dnf5-automatic.timer dnf5-automatic-install.timer dnf5-automatic-download.timer dnf5-automatic-notifyonly.timer)
    fi
    for unit in "${units[@]}"; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit "; then
        if systemctl is-enabled --quiet "$unit" || systemctl is-active --quiet "$unit"; then
          systemctl disable --now "$unit" || echo "WARNING: could not stop $unit" >&2
        fi
      fi
    done
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files cron.service --no-legend 2>/dev/null | grep -q '^cron.service '; then
    systemctl enable --now cron.service
  elif systemctl list-unit-files crond.service --no-legend 2>/dev/null | grep -q '^crond.service '; then
    systemctl enable --now crond.service
  else
    echo 'WARNING: Cannot find cron.service or crond.service; start cron manually.' >&2
  fi
fi
printf 'Installed nightly patching on %s (%s) at %02d:%02d server-local time.\n' "$(hostname)" "$ID" "$HOUR" "$MINUTE"
printf 'Cron: %s\nPatcher: %s\nLog: /var/log/nightly-patch.log\n' "$CRON" "$SCRIPT"
printf 'Automatic reboot: OFF. Native updater coordination requested: %s\n' "$DISABLE_NATIVE_UPDATERS"
printf 'To run now: sudo %s\n' "$SCRIPT"
