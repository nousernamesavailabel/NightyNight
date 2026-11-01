# Universal Nightly Linux Patching

Installs a nightly, logged update job on supported Ubuntu/Debian and Fedora/RHEL-family servers. No unattended reboot. Run on each server using root privileges.

## Supported distributions

- Ubuntu and Debian (APT)
- Fedora, RHEL, Rocky Linux, AlmaLinux, Oracle Linux (`ol`), and CentOS when `dnf` is available

This installer targets conventional systemd hosts. It does not manage rpm-ostree/immutable Fedora variants, transactional systems, container images, or release upgrades. Older yum-only RHEL/CentOS versions are not supported. Test distribution-specific compatibility before fleet-wide use.

## Requirements

- Root access, internet/repository connectivity, enough free disk space, and working package repositories
- Bash, `flock` (util-linux), `logrotate`, a cron implementation (`cron` or `cronie`), and `apt-get` or `dnf`
- For optional RHEL-family reboot checks, `needs-restarting` (`dnf-utils` or `dnf-plugins-core`, as available on your distribution)
- A working backup and a suitable maintenance window, particularly for critical servers

If a prerequisite is missing, install it using the distribution's package manager before running this script. The installer checks prerequisites and stops rather than silently installing them.

## Install

Copy **install-nightly-patching-universal.sh** to each server:

```bash
chmod +x install-nightly-patching-universal.sh
sudo ./install-nightly-patching-universal.sh
```

This installs, but **does not immediately execute**, the patch job. To test it manually:

```bash
sudo /usr/local/sbin/nightly-patch.sh
sudo tail -n 80 /var/log/nightly-patch.log
```

### Change the schedule

Default is **03:00 every day in the server's local timezone**.

```bash
sudo PATCH_HOUR=4 PATCH_MINUTE=30 ./install-nightly-patching-universal.sh
```

The installer can be rerun to update its managed files. It refuses to proceed if root's personal crontab already directly schedules `/usr/local/sbin/nightly-patch.sh` to avoid a duplicated schedule. Remove that conflicting line using `sudo crontab -e` first.

### Retain existing native automatic updaters

By default, the installer attempts to disable distro APT daily timers or DNF automatic timers so they do not independently run during patching. It also installs an APT periodic-update policy on Debian/Ubuntu. To leave these existing updaters alone:

```bash
sudo DISABLE_NATIVE_UPDATERS=0 ./install-nightly-patching-universal.sh
```

**Caution:** Keeping native updaters active can lead to competing package-manager processes. Setting `DISABLE_NATIVE_UPDATERS=0` on a subsequent installation does not undo APT policy files or re-enable timers previously disabled by this installer.

## Behavior

| Item | APT distributions | DNF distributions |
| --- | --- | --- |
| Refresh repositories | `apt-get update` (fails on inaccessible repos) | `dnf --refresh ... upgrade` |
| Install updates | `apt-get upgrade --with-new-pkgs --no-remove` | `dnf upgrade --refresh` with `obsoletes=False` |
| Kernel updates | Installs new dependencies when APT permits | Installs package-manager-selected kernel updates |
| Remove unneeded packages | No automatic autoremove | No automatic autoremove |
| Automatic reboot | Never | Never |
| Reboot reporting | Checks `/run/reboot-required` | Uses `needs-restarting -r` when installed |
| OS release upgrades | Not performed | Not performed |
| Snap/Flatpak | Not explicitly managed | Not explicitly managed |

**Package-removal policy differs by distribution.** APT explicitly uses `--no-remove`. On DNF, `obsoletes=False` limits obsolete-package replacements, but **does not absolutely prohibit removals** or guarantee that every transaction is safe. Review updates and transaction plans on critical hosts before enabling unattended operation. No automation can guarantee that package upgrades will not interrupt services; package scripts can restart daemons.

The installer does not modify APT/DNF repository URLs, subscription status, proxy rules, firewall rules, or package exclusions. DNF security-only update behavior is **not** enabled: the script installs normal available updates, including security updates.

## Installed files

| Path | Purpose |
| --- | --- |
| `/usr/local/sbin/nightly-patch.sh` | Scheduled patch execution |
| `/etc/cron.d/nightly-patch` | Cron schedule (root) |
| `/etc/logrotate.d/nightly-patch` | Daily rotation, 14 retained, compressed |
| `/etc/default/nightly-patch` | Installer schedule record |
| `/var/log/nightly-patch.log` | Execution log |
| `/run/nightly-patch.lock` | Prevent concurrent runs of this script |
| `/etc/apt/apt.conf.d/99-nightly-patch-schedule` | APT automatic-updater policy when enabled |

`flock` prevents simultaneous copies of this script; it does **not** block all other APT/DNF jobs. The logrotate configuration runs as root and retains 14 daily rotated files, rather than guaranteeing exactly 14 days in every case.

## Verify

```bash
cat /etc/cron.d/nightly-patch
sudo logrotate -d /etc/logrotate.d/nightly-patch
sudo tail -n 80 /var/log/nightly-patch.log
```

Service status:

```bash
# Ubuntu / Debian
systemctl status cron.service
# Fedora / RHEL family
systemctl status crond.service
```

Check updates manually:

```bash
# Ubuntu / Debian
apt list --upgradable
# Fedora / RHEL family (returns exit 100 if updates exist)
sudo dnf check-update
```

A reboot notice is informational. Schedule and perform necessary reboots separately.

## Troubleshooting

- Repository errors: verify DNS, routing, firewall/proxy connectivity, and configured package mirrors.
- No log: verify cron daemon, `/etc/cron.d/nightly-patch`, and execution permissions; or run the script manually.
- Package lock: check other native updater processes; ensure native updater coordination is enabled or schedule around them.
- DNF reboot status unavailable: install the distribution's `needs-restarting` utility, or assess updates through your maintenance process.
- Logrotate issues: verify `sudo logrotate -d /etc/logrotate.d/nightly-patch` and permissions.

## Rollback / uninstall

There is no automatic uninstall. To remove the scheduled job, delete `/etc/cron.d/nightly-patch` and `/usr/local/sbin/nightly-patch.sh` after checking no run is active. Optionally remove `/etc/logrotate.d/nightly-patch` and `/etc/default/nightly-patch`. On APT hosts, remove `/etc/apt/apt.conf.d/99-nightly-patch-schedule` if installed and restore your desired native timer settings. On DNF hosts, re-enable any native automatic-update timers that you intentionally used before installation. The installer does not record pre-installation timer states, so restore them from your system configuration records rather than enabling all timers indiscriminately.

## Deployment guidance

Pilot on a noncritical machine of each OS/version. Verify cron, package transaction behavior, kernel installation, application availability, backup restore readiness, and reboot handling before rolling out broadly. Consider different schedules per server to avoid concurrent bandwidth and application impact. For strict no-removal guarantees on DNF, use reviewed or staged update transactions rather than fully unattended installation.
