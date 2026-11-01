# NightyNight v2

Automated nightly Linux package patching for Ubuntu, Debian, Fedora, RHEL, Rocky, AlmaLinux, and Oracle Linux. CentOS systems with DNF are also recognized. **Pilot this release on a noncritical machine from each OS family.** Distro support is an implementation target, not evidence of runtime validation on all versions.

## Tested distributions

The following distributions have been **successfully tested on live hosts** with NightyNight v2. These tests establish functionality on the specific OS versions shown, not certification for every release or configuration.

| Distribution | Version | Verified functionality | Result |
| --- | --- | --- | --- |
| Ubuntu | 24.04 LTS | Installation and migration from cron; APT dry run and real update run; reboot status; JSON status; systemd timer; logrotate; timezone selection; replacement of `apt-daily-upgrade.timer` | **Passed** |
| Fedora | 44 (DNF5) | Installation and migration; DNF dry run and real update run; offline transaction detection and recovery after manual cleanup; reboot status; JSON status; systemd timer; logrotate; timezone selection | **Passed** |
| Red Hat Enterprise Linux (RHEL) | 9 (DNF4) | Installation; real DNF package upgrade (verified successful in DNF history); reboot detection via `dnf needs-restarting -r`; JSON status; systemd timer; logrotate; timezone selection | **Passed** |

**Not yet live-tested:** Debian, Rocky Linux, AlmaLinux, Oracle Linux, and CentOS. These remain supported targets, but should be tested on noncritical systems before production deployment.

**RHEL test notes:** An initial run was blocked by Google Chrome's repository signing key; refreshing the applicable Google key resolved RPM verification. The first completed update run then reported a reboot-check failure because the script did not recognize DNF4's `dnf needs-restarting -r`. The corrected NightyNight engine was subsequently tested successfully with exit code `0` and `reboot_required: true`. An SSH connection also dropped during the large package update, so maintenance windows remain important.

## Files

| File | Purpose |
| --- | --- |
| `install-nightynight.sh` | Root installer; installs or upgrades managed files, configures a systemd timer and logrotate |
| `nightynight` | Patching engine and status CLI |
| `nightynight.conf` | Default site configuration; edited at `/etc/nightynight/nightynight.conf` |
| `README.md` | Deployment, configuration, and operations |

## Requirements

- Root access, Bash, systemd, `flock` (util-linux), GNU `timeout` (coreutils), `logrotate`, `df`, and the distribution's APT or DNF package manager.
- Network access to the enabled package repositories and sufficient disk space.
- DNF4 reboot detection uses `dnf needs-restarting -r` (no standalone executable required when the DNF subcommand is available); Fedora DNF5 uses `dnf5 needs-restarting`.
- For optional email notifications, configure a functioning local `mail` command and a mail transport. No SMTP credentials are stored by NightyNight.
- On APT systems, the `APT::Update::Error-Mode=any` behavior requires a suitably recent apt (supported by modern Ubuntu/Debian versions).

## Native updater coordination

The installer offers a choice:

- **Replace**: disables known native *automatic-install* timers (`apt-daily-upgrade.timer` on Ubuntu/Debian; common `dnf-automatic*`/`dnf5-automatic*` timers on DNF systems). Leaves `apt-daily.timer` and `dnf-makecache.timer` enabled. Before changing timers, checks whether corresponding update services are running; if they are, installation stops before modifying the native timers. Records previous timer enabled states in `/var/backups/nightynight/native-updaters.<timestamp>.tsv`. Attempts to restore already-changed timer states if a later disable fails.
- **Preserve**: does not modify native timers. Choose if an external patching workflow owns upgrades.
- **Ask**: prompts on interactive installations and preserves on noninteractive installations.

For noninteractive installs, set `NIGHTYNIGHT_UPDATER_POLICY=replace` or `preserve` explicitly, or set `NATIVE_UPDATER_POLICY` in `/etc/nightynight/nightynight.conf` and rerun the installer. Example:

```bash
sudo env NIGHTYNIGHT_UPDATER_POLICY=replace ./install-nightynight.sh
```

The installer only detects a known list of timer unit names. Review other automated update mechanisms and desktop offline transactions separately. It never stops an already-running package upgrade. Undo changes manually using the saved previous states; native timers are **not** automatically re-enabled on uninstall.

## Install or upgrade

Keep the four files in one directory, then:

```bash
chmod +x install-nightynight.sh
sudo ./install-nightynight.sh
```

The installer preserves the existing configuration, if any, and saves timestamped copies of existing managed files in `/var/backups/nightynight/`. It migrates the known legacy NightyNight cron entry and legacy logrotate rule to a systemd timer and a single logrotate policy. **It does not run a package update at installation time.** To modify the schedule, edit the config and rerun the installer from the same directory.

### Timezone selection

When run from an interactive terminal (`sudo ./install-nightynight.sh`), the installer displays the current server timezone and offers **Keep existing** as the default. It also offers common US zones (Eastern, Central, Mountain, Arizona, Pacific, Alaska, Hawaii), UTC, and **Search all installed IANA timezones**. The search reads the host's live list from `timedatectl list-timezones`, matches city/region names case-insensitively, shows up to 30 results at a time, and accepts a numbered selection or an exact timezone name. Refine the search for larger result sets.

For unattended installs the existing timezone is retained unless explicitly set:

```bash
sudo env NIGHTYNIGHT_TIMEZONE=America/Anchorage ./install-nightynight.sh
# Keep existing timezone explicitly:
sudo env NIGHTYNIGHT_TIMEZONE=keep ./install-nightynight.sh
```

Timezone selections are validated against `timedatectl list-timezones` before applying. This changes the **whole server timezone**, including other local-time scheduled jobs and log timestamps—not only NightyNight. It does not alter the underlying clock or require a reboot. The systemd timer uses local server time and automatically accounts for DST. Running the installer again defaults to retaining the then-current timezone.

**Important:** This installer changes the scheduling mechanism from cron to systemd. It removes only known NightyNight cron references; review custom cron entries separately. The installer now offers **native updater coordination**. With `NATIVE_UPDATER_POLICY=ask` (default), interactive installation asks whether to replace native automatic-install timers (option 1) or preserve them (default option 2). Noninteractive installation preserves them unless explicitly configured. This is an installer-time action, not a per-night enforcement policy. It does not disable metadata-refresh timers, such as `apt-daily.timer` or `dnf-makecache.timer`, and it does not control desktop graphical/offline update schedulers.

### First-time test

```bash
sudo /usr/local/sbin/nightynight check-config
sudo /usr/local/sbin/nightynight dry-run
sudo /usr/local/sbin/nightynight run
sudo tail -n 80 /var/log/nightly-patch.log
sudo /usr/local/sbin/nightynight status
systemctl list-timers nightynight.timer
systemctl status nightynight.timer --no-pager
sudo logrotate -d /etc/logrotate.d/nightynight
```

For compatibility with the original release, `sudo /usr/local/sbin/nightly-patch.sh` also works. The patcher is intentionally quiet at the terminal and writes to `/var/log/nightly-patch.log`.

## Configuration

Edit `/etc/nightynight/nightynight.conf` (root-only), then rerun `sudo ./install-nightynight.sh` to apply **timer or log retention settings**. Other settings are read on each run.

| Setting | Default | Notes |
| --- | --- | --- |
| `PATCH_HOUR`, `PATCH_MINUTE` | `3`, `0` | Server-local scheduled time |
| `RANDOM_DELAY_MINUTES` | `30` | Stagger hosts within 0–30 minutes |
| `PERSISTENT_TIMER` | `true` | Catch up after missed schedule; a catch-up run may occur outside the usual window |
| `MIN_FREE_SPACE_MB` | `2048` | Free space check of `/` only; does not check `/boot`, `/var`, or separate package cache filesystems |
| `MAX_RUNTIME_MINUTES` | `120` | Per package command timeout; service has a separate total timeout |
| `UPDATE_MODE` | `all` | `security` is explicitly rejected because repository/advisory coverage varies |
| `EXCLUDE_PACKAGES` | empty | Space-separated APT/DNF patterns, e.g. `postgresql* nginx*` |
| `EXCLUDE_KERNEL` | `false` | Excludes `linux-*` on APT and `kernel* linux-firmware*` on DNF; broad and not exhaustive |
| `ALLOW_PACKAGE_REMOVALS` | `false` | `true` is rejected; DNF still performs ordinary package replacement within upgrades |
| `CHECK_OFFLINE_UPDATES` | `true` | Check DNF5 offline transaction state before normal update |
| `AUTO_REBOOT` | `false` | `true` rejected; always manual reboots |
| `LOG_RETENTION_DAYS` | `14` | Number of daily rotated log files |
| `NOTIFY_ON_FAILURE`, `NOTIFY_ON_REBOOT` | `false` | Optional emails, if `mail` is configured |
| `NOTIFY_EMAIL` | empty | Recipient (one address recommended) |
| `NATIVE_UPDATER_POLICY` | `ask` | `ask`, `preserve`, or `replace` for competing native automatic-install timers; applied when installing |
| `DISABLE_NATIVE_UPDATERS` | `false` | Legacy setting; use `NATIVE_UPDATER_POLICY` for new installs |

Settings are plain `KEY=value` lines; **do not use shell quotes, variable expansions, or inline comments**. Configuration is parsed as data. Keep the file root-owned with mode `0600`.

## Safety decisions

- **APT:** `apt-get update` treats source errors as fatal; `upgrade --with-new-pkgs --no-remove` installs needed new dependencies but disallows package removals. Existing local package configuration files are preserved where dpkg prompts for a choice. Release upgrades are not attempted.
- **DNF4/DNF5:** `dnf upgrade --refresh` without `--allowerasing` avoids enabling dependency-resolution erasures. The package manager may replace old package versions normally. Exclusions use `--exclude` patterns.
- **Offline Fedora updates:** a DNF5 offline transaction that is present, invalid or cannot be confidently classified causes a **skip**, never an automatic clean. Run `sudo dnf offline status` and address it manually (`sudo dnf offline clean` only after deciding it is safe).
- **Concurrency:** NightyNight uses `/run/nightynight.lock` to prevent overlapping NightyNight executions. Native package manager locks still protect against unrelated tools; consider disabling competing automation only after reviewing the host.
- **Reboots:** no automatic reboot. APT uses `/run/reboot-required`; DNF5 uses `dnf5 needs-restarting`; DNF4 uses `dnf needs-restarting -r`. An unavailable or failed reboot check is treated as an error even if package installation succeeded.
- **Service restarts:** package maintainer scripts may restart services during installation. NightyNight reports how to inspect services needing restart; it does not separately restart them.
- **Dry run:** APT uses `apt-get -s`; DNF uses `--assumeno`. No packages are installed by these modes, but repository metadata or caches may be updated. Dry-run exit status does not guarantee the next real transaction will behave identically.
- **Disk check:** current disk preflight is deliberately basic and not a guarantee of sufficient space for a large transaction.

## Exit codes

| Code | Interpretation |
| --- | --- |
| `0` | Run completed, or dry-run command completed |
| `2` | Run intentionally skipped (DNF offline transaction) |
| `3` | Configuration, OS, or preflight error |
| `4` | Package manager command failed |
| `5` | Another NightyNight process holds the lock |
| `7` | Reboot assessment unavailable or failed |
| `8` | Package operation timed out |
| `64` | Invalid CLI usage / insufficient privilege |

The structured status file `/var/lib/nightynight/status.json` records timestamps, mode, result, exit code, and reboot state. It is replaced on each run, including a dry run. The file does **not** claim a package-upgrade count. `nightynight status` prints this file; it does not perform a live package audit.

### Reboot and service checks

```bash
# Fedora / DNF5
sudo dnf5 needs-restarting
sudo dnf5 needs-restarting --services

# RHEL-family / DNF4
sudo dnf needs-restarting -r
sudo dnf needs-restarting -s

# Debian/Ubuntu
test -f /run/reboot-required && echo 'Reboot required' || echo 'No reboot required'
```

### Log rotation and service logs

```bash
sudo tail -n 100 /var/log/nightly-patch.log
sudo journalctl -u nightynight.service -n 100 --no-pager
sudo logrotate -d /etc/logrotate.d/nightynight
```

### Notifications

Set `NOTIFY_ON_FAILURE=true` and/or `NOTIFY_ON_REBOOT=true`, plus `NOTIFY_EMAIL=admin@example.org`. You must configure a working `mail` executable separately. A failed attempt to send email is logged; it does not override the patch outcome. There is no direct SMTP, webhook, or central monitoring integration in v2.

## Rollback and removal

Backups are stored under `/var/backups/nightynight/` and can be used to manually restore the previous files. To disable new scheduled patching:

```bash
sudo systemctl disable --now nightynight.timer
```

For complete removal, review and remove `/etc/systemd/system/nightynight.{timer,service}`, `/usr/local/sbin/nightynight`, `/usr/local/sbin/nightly-patch.sh`, `/etc/logrotate.d/nightynight` and `/etc/nightynight/`, then `sudo systemctl daemon-reload`. Keep logs and status until no longer needed. **The installer does not automatically re-enable native updater timers** if you previously disabled them.

## Known limitations

The current release is not an update orchestration service: no central reporting, no transactional rollback of package upgrades, no automatic snapshot, no verified secure per-repository package pin policy, no strict maintenance window, and no live validation of all distributions. APT and DNF exclusion globs differ in matching semantics. Changes to package tools or OS major releases can require testing. Use snapshots/backups and staged rollout for production systems.
