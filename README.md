# Ubuntu Nightly Patching Installer

Deploy a consistent nightly APT patching schedule and rotating log on Ubuntu servers using `install-nightly-patching.sh`.

**Default schedule:** 03:00 every day, in each server's **local system timezone**. **Automatic rebooting is disabled.**

## What the installer does

Running the installer as root:

1. Checks that it is on Ubuntu and that `apt-get`, `flock`, `logrotate`, and `crontab` are present.
2. Rejects a pre-existing root crontab entry calling `/usr/local/sbin/nightly-patch.sh`, to avoid a duplicate schedule.
3. Creates or **overwrites** `/usr/local/sbin/nightly-patch.sh`.
4. Creates or **overwrites** `/etc/cron.d/nightly-patch` with a daily schedule.
5. Creates or **overwrites** `/etc/logrotate.d/nightly-patch` for daily rotation, 14 archives, and compression.
6. Creates or **overwrites** `/etc/apt/apt.conf.d/99-nightly-patch-schedule`, setting APT periodic update, download, unattended-upgrade, and autoclean intervals to zero.
7. Disables and stops the systemd timers `apt-daily.timer` and `apt-daily-upgrade.timer`, then restarts `cron.service`.
8. Performs shell-syntax and logrotate dry-run checks. **It does not install patches immediately.**

The installer does not modify the APT repository URLs, network/firewall settings, Snap update policies, or reboot configuration.

## Requirements

- Ubuntu server with working APT repositories and outbound access to their package mirrors.
- Root/sudo access.
- `apt-get`, `flock` (typically from `util-linux`), `logrotate`, `cron`/`crontab`, and systemd available.
- Sufficient disk space for downloaded packages, new kernel versions, and retained logs.
- A current backup or VM snapshot and a maintenance/recovery plan, particularly for production systems.

> **Important:** Package upgrades may restart services while the machine stays online. Use an appropriate maintenance window for critical applications.

## Install

Copy `install-nightly-patching.sh` to the target server and run:

```bash
chmod +x install-nightly-patching.sh
sudo ./install-nightly-patching.sh
```

To use a different time, pass the hour (0–23) and minute (0–59):

```bash
sudo PATCH_HOUR=4 PATCH_MINUTE=30 ./install-nightly-patching.sh
```

This example schedules updates for **04:30 server-local time**. If `sudo` on your system does not accept variable assignments this way, use:

```bash
sudo env PATCH_HOUR=4 PATCH_MINUTE=30 bash ./install-nightly-patching.sh
```

**Note:** Re-running the installer replaces its managed files. It is not a safe way to retain manual edits to those files. The script refuses to install if a root crontab entry already invokes the same patch script; remove the duplicate entry intentionally before installing.

## What happens nightly

The generated `/usr/local/sbin/nightly-patch.sh`:

1. Acquires a nonblocking lock at `/run/nightly-patch.lock` so two instances of this script cannot run at once.
2. Writes command output to `/var/log/nightly-patch.log`.
3. Runs `apt-get update` with three acquisition retries and treats repository update errors as failures.
4. Runs `apt-get upgrade --with-new-pkgs --no-remove` in noninteractive mode, preserving existing configuration files when applicable. This permits new dependencies (often needed for kernel updates) but disallows package removals.
5. Runs `apt-get clean` to clear the downloaded APT package cache.
6. Reports whether `/run/reboot-required` exists, then lists any remaining upgradable packages.
7. Logs its completion time and exit status, including if an earlier command failed.

This is **not** `dist-upgrade`/`full-upgrade`: updates requiring package removal will remain pending for manual review. It also **does not run `apt autoremove`**, perform distribution-release upgrades, or reboot the server.

## Verify installation

Check the managed cron schedule:

```bash
sudo cat /etc/cron.d/nightly-patch
```

Run a patch cycle manually:

```bash
sudo /usr/local/sbin/nightly-patch.sh
echo "Exit status: $?"
```

Review the log:

```bash
sudo tail -n 80 /var/log/nightly-patch.log
```

Check for updates still pending:

```bash
apt list --upgradable
```

Check for a required reboot:

```bash
if [ -e /run/reboot-required ]; then echo 'Reboot required'; else echo 'No reboot currently flagged'; fi
```

Validate log rotation without changing files:

```bash
sudo logrotate -d /etc/logrotate.d/nightly-patch
```

The logrotate configuration uses `su root root` to avoid failures when the parent directory has permissions logrotate considers insecure. A message indicating rotation is not currently needed is normal.

## Paths and schedule

| File/path | Purpose |
| --- | --- |
| `install-nightly-patching.sh` | One-time setup installer |
| `/usr/local/sbin/nightly-patch.sh` | Nightly patch runner |
| `/etc/cron.d/nightly-patch` | Cron schedule (includes `root` user field) |
| `/var/log/nightly-patch.log` | Patch output and status |
| `/etc/logrotate.d/nightly-patch` | Log rotation: daily, 14 archives, compression |
| `/etc/apt/apt.conf.d/99-nightly-patch-schedule` | Disable Ubuntu's periodic APT scheduling |
| `/run/nightly-patch.lock` | Per-boot lock file |

**Timezone:** Cron uses the server's configured timezone; this installer does not set it. Check with `timedatectl`.

## Operations and troubleshooting

**APT update fails or package downloads time out**

Check the log for the failing hostname/repository, then test connectivity. For example:

```bash
sudo apt-get update
curl -4 -I --connect-timeout 5 http://archive.ubuntu.com/ubuntu/
```

Do not change an APT mirror unless you have confirmed the replacement works and is suitable for that server.

**Patches remain available after a successful run**

Review `apt list --upgradable`. Packages may be held or require removals, which this automation explicitly disallows. Inspect before taking manual action:

```bash
sudo apt-get -s dist-upgrade
```

A simulation does not change the system. Consider package impact and backup status before using a full upgrade manually.

**Cron did not run**

```bash
systemctl status cron.service --no-pager
sudo cat /etc/cron.d/nightly-patch
sudo tail -n 80 /var/log/nightly-patch.log
```

No patch log exists until the first execution. Check syslog/journal for cron execution if necessary.

**Reboot required**

The script logs the requirement but never reboots. Arrange a maintenance window and verify services after a controlled reboot.

**Snap-based applications**

This script handles APT packages only. Snap packages (including a Nextcloud Snap deployment) follow their separate snapd refresh mechanism; coordinate those updates and backups independently.

**Existing unattended-upgrades automation**

The installer intentionally disables stock APT timers and sets periodic APT intervals to zero. This changes the host's existing security-update workflow. Reassess before deploying to hosts with centrally managed patching or compliance policies.

## Change or remove the setup

To change the schedule, re-run the installer with the new `PATCH_HOUR` and `PATCH_MINUTE` values. To stop the scheduled job without removing the files, comment out the job line in `/etc/cron.d/nightly-patch` (or remove that cron file).

**Removing the cron entry alone does not restore Ubuntu's previous APT update policy.** If retiring this setup, separately restore your original APT periodic policy and re-enable the appropriate systemd APT timers based on your site's desired update policy. Avoid blindly restoring defaults on centrally managed hosts.

## Security and deployment notes

- Run only a copy of the installer you have reviewed and trust; it creates root-owned scripts and scheduled root execution.
- Prefer staggered maintenance windows across servers rather than patching every server simultaneously.
- Keep backups and tested recovery procedures, especially for services with persistent data.
- Monitor logs and reboot-required status externally if patch compliance or alerts are necessary; this tool does not send notifications.
- Use a configuration-management solution if you need centralized deployment, inventory, drift detection, or reporting at scale.
