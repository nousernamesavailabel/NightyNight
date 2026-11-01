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
# Timezone selection is optional and changes the HOST timezone, not just NightyNight.
# Non-interactive: NIGHTYNIGHT_TIMEZONE=keep (default) or an exact IANA timezone.
# Interactive: current timezone, common US zones, and searchable system timezone list.
choose_timezone() {
  local current requested choice search answer i limit
  local -a zones matches
  current=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  current=${current:-unknown}
  requested=${NIGHTYNIGHT_TIMEZONE:-keep}
  if [[ ! -v NIGHTYNIGHT_TIMEZONE && -t 0 ]]; then
    command -v timedatectl >/dev/null || { echo 'timedatectl is required for timezone selection.' >&2; exit 1; }
    mapfile -t zones < <(timedatectl list-timezones --no-pager 2>/dev/null)
    ((${#zones[@]} > 0)) || { echo 'Could not load available timezones.' >&2; exit 1; }
    while true; do
      printf '\nCurrent server timezone: %s\n' "$current"
      printf 'Timezone selection (changes timezone for the entire server):\n'
      printf '  1) Keep current timezone [default]\n'
      printf '  2) America/New_York (Eastern)\n'
      printf '  3) America/Chicago (Central)\n'
      printf '  4) America/Denver (Mountain)\n'
      printf '  5) America/Phoenix (Arizona)\n'
      printf '  6) America/Los_Angeles (Pacific)\n'
      printf '  7) America/Anchorage (Alaska)\n'
      printf '  8) Pacific/Honolulu (Hawaii)\n'
      printf '  9) UTC\n'
      printf ' 10) Search all installed IANA timezones\n'
      read -r -p 'Choose [1-10, default 1]: ' choice || choice=1
      case "${choice:-1}" in
        1) requested=keep; break ;;
        2) requested=America/New_York; break ;;
        3) requested=America/Chicago; break ;;
        4) requested=America/Denver; break ;;
        5) requested=America/Phoenix; break ;;
        6) requested=America/Los_Angeles; break ;;
        7) requested=America/Anchorage; break ;;
        8) requested=Pacific/Honolulu; break ;;
        9) requested=UTC; break ;;
        10)
          while true; do
            read -r -p 'Search by city/region (or enter exact timezone, blank to return): ' search || search=''
            [[ -n $search ]] || break
            matches=()
            for answer in "${zones[@]}"; do
              if [[ ${answer,,} == *${search,,}* ]]; then
                matches+=("$answer")
              fi
            done
            if ((${#matches[@]} == 0)); then
              echo 'No matching timezones. Try another search.'
              continue
            fi
            limit=${#matches[@]}
            (( limit > 30 )) && limit=30
            printf '%s matches (showing %s; refine search for more):\n' "${#matches[@]}" "$limit"
            for ((i=0; i<limit; i++)); do
              printf ' %2d) %s\n' "$((i+1))" "${matches[i]}"
            done
            read -r -p 'Enter number, exact IANA name, or R to search again: ' answer || answer=R
            if [[ $answer =~ ^[0-9]+$ ]] && ((10#$answer >= 1 && 10#$answer <= limit)); then
              requested=${matches[10#$answer-1]}
              break 2
            elif [[ $answer == [Rr] || -z $answer ]]; then
              continue
            elif printf '%s\n' "${zones[@]}" | grep -Fx -- "$answer" >/dev/null; then
              requested=$answer
              break 2
            else
              echo 'Invalid selection. Search again.'
            fi
          done
          ;;
        *) echo 'Invalid selection. Try again.' ;;
      esac
    done
  fi
  if [[ "$requested" == keep ]]; then
    echo "Keeping server timezone: $current"
    return 0
  fi
  command -v timedatectl >/dev/null || { echo 'timedatectl is required to change timezone.' >&2; exit 1; }
  if ! timedatectl list-timezones --no-pager | grep -Fx -- "$requested" >/dev/null; then
    echo "Invalid timezone: $requested (see timedatectl list-timezones)" >&2
    exit 1
  fi
  if [[ "$requested" == "$current" ]]; then
    echo "Server timezone already set to: $requested"
  else
    timedatectl set-timezone "$requested"
    echo "Server timezone changed: $current -> $requested"
  fi
}
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
choose_timezone
systemctl daemon-reload
systemctl enable --now nightynight.timer
systemctl is-enabled --quiet nightynight.timer
logrotate -d /etc/logrotate.d/nightynight >/dev/null 2>&1 || { echo 'WARNING: logrotate validation failed' >&2; }
echo "NightyNight v2 installed on $ID. Timer: $(printf '%02d:%02d' "$H" "$M") local time + 0-${J}m stagger."
echo 'Run: sudo nightynight run | sudo nightynight dry-run | sudo nightynight status'
echo 'Timer: systemctl list-timers nightynight.timer'
echo 'Backups: /var/backups/nightynight/'
