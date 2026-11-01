#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
[[ $EUID -eq 0 ]] || { echo 'ERROR: run installer as root (sudo)' >&2; exit 1; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f $HERE/nightynight && -f $HERE/nightynight.conf ]] || { echo 'Place installer, nightynight and nightynight.conf in the same directory.' >&2; exit 1; }
for cmd in systemctl install flock timeout logrotate; do
  if [[ $cmd == logrotate ]]; then continue; fi
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[[ -r /etc/os-release ]] || exit 1
source /etc/os-release
case "$ID" in ubuntu|debian|fedora|rhel|rocky|almalinux|ol|centos) :;; *) echo "Unsupported OS: $ID" >&2; exit 1;; esac
# Require locally installed logrotate rather than silently invoking a package manager.
command -v logrotate >/dev/null || { echo 'Install logrotate before proceeding.' >&2; exit 1; }
CFG_DIR=/etc/nightynight
install -d -m 700 "$CFG_DIR" /var/lib/nightynight
install -d -m 750 /var/backups/nightynight
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
for f in "$CFG_DIR/nightynight.conf" /usr/local/sbin/nightynight /usr/local/sbin/nightly-patch.sh /etc/systemd/system/nightynight.service /etc/systemd/system/nightynight.timer /etc/logrotate.d/nightynight /etc/logrotate.d/nightly-patch /etc/cron.d/nightly-patch; do
  [[ ! -f $f ]] || cp -p "$f" "/var/backups/nightynight/$(basename "$f").$STAMP.bak"
done
if [[ ! -f $CFG_DIR/nightynight.conf ]]; then
  install -m 600 "$HERE/nightynight.conf" "$CFG_DIR/nightynight.conf"
  echo 'Installed default configuration.'
else
  echo 'Preserved existing configuration. Compare against bundled nightynight.conf for new options.'
fi
install -m 750 "$HERE/nightynight" /usr/local/sbin/nightynight
# Legacy compatibility entry point; avoid maintaining two copies of patching logic.
cat > /usr/local/sbin/nightly-patch.sh <<'WRAPPER'
#!/usr/bin/env bash
exec /usr/local/sbin/nightynight run "$@"
WRAPPER
chmod 750 /usr/local/sbin/nightly-patch.sh
/usr/local/sbin/nightynight check-config
# Read validated configuration keys as data, never source shell text from this config.
get_conf() { sed -n "s/^$1=//p" "$CFG_DIR/nightynight.conf" | tail -n 1; }
H=$(get_conf PATCH_HOUR); M=$(get_conf PATCH_MINUTE); J=$(get_conf RANDOM_DELAY_MINUTES)
H=${H:-3}; M=${M:-0}; J=${J:-30}
P=$(get_conf PERSISTENT_TIMER); P=${P:-true}
DISABLE=$(get_conf DISABLE_NATIVE_UPDATERS); DISABLE=${DISABLE:-false}
MAX=$(get_conf MAX_RUNTIME_MINUTES); MAX=${MAX:-120}
# Normalize to integer to avoid leading zero parsing and systemd unit injection.
H=$((10#$H)); M=$((10#$M)); J=$((10#$J)); MAX=$((10#$MAX))
cat > /etc/systemd/system/nightynight.service <<UNIT
[Unit]
Description=NightyNight automated package patching
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nightynight run
TimeoutStartSec=$((MAX*60+120))
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT
cat > /etc/systemd/system/nightynight.timer <<UNIT
[Unit]
Description=NightyNight nightly patch timer

[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d' "$H" "$M"):00
Persistent=$P
RandomizedDelaySec=$((J*60))
AccuracySec=1min
Unit=nightynight.service

[Install]
WantedBy=timers.target
UNIT
RET=$(get_conf LOG_RETENTION_DAYS); RET=${RET:-14}
[[ $RET =~ ^[0-9]+$ ]] || { echo 'Invalid retention setting' >&2; exit 1; }
cat > /etc/logrotate.d/nightynight <<UNIT
/var/log/nightly-patch.log {
    su root root
    daily
    rotate $RET
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
UNIT
# Remove duplicate v1 logrotate policy only when it targets the same NightyNight log.
if [[ -f /etc/logrotate.d/nightly-patch ]] && grep -q '^/var/log/nightly-patch.log' /etc/logrotate.d/nightly-patch; then
  rm -f /etc/logrotate.d/nightly-patch
fi
# Remove only our known legacy cron entry, leave other crontabs unchanged.
if [[ -f /etc/cron.d/nightly-patch ]] && grep -q '/usr/local/sbin/nightly-patch.sh\|/usr/local/sbin/nightynight' /etc/cron.d/nightly-patch; then
  rm -f /etc/cron.d/nightly-patch
fi
# Remove old root crontab line only if referencing the known legacy path.
if command -v crontab >/dev/null 2>&1; then
  current=$(mktemp)
  crontab -l > "$current" 2>/dev/null || :
  if grep -q '/usr/local/sbin/nightly-patch.sh' "$current"; then
    sed -i '\|/usr/local/sbin/nightly-patch.sh|d' "$current"
    crontab "$current"
  fi
  rm -f "$current"
fi
if [[ $DISABLE == true ]]; then
  echo 'Explicitly disabling known native updater timers.'
  for unit in apt-daily.timer apt-daily-upgrade.timer dnf-automatic.timer dnf-automatic-install.timer dnf5-automatic.timer; do
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit" && systemctl disable --now "$unit" || :
  done
else
  echo 'Native updater timers preserved (default). They may run independently of NightyNight.'
fi
systemctl daemon-reload
systemctl enable --now nightynight.timer
systemctl is-enabled --quiet nightynight.timer
logrotate -d /etc/logrotate.d/nightynight >/dev/null 2>&1 || { echo 'WARNING: logrotate validation failed' >&2; }
echo "NightyNight v2 installed on $ID. Timer: $(printf '%02d:%02d' "$H" "$M") local time + 0-${J}m stagger."
echo 'Run: sudo nightynight run | sudo nightynight dry-run | sudo nightynight status'
echo 'Timer: systemctl list-timers nightynight.timer'
echo 'Backups: /var/backups/nightynight/'
