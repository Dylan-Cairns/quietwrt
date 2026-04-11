# Router Install

This document describes the current end-to-end setup for `QuietWrt` on a `GL.iNet GL-MT3000` running stock GL firmware.

The preferred flow is now:

1. complete the router UI prerequisites once
2. run the local PowerShell CLI
3. let the router-side Lua control plane handle install, update, toggles, and removal

## 1. Router UI Prerequisites

Before running the local CLI, confirm these in the GL.iNet admin UI:

1. the router is in `Router` mode
2. `SSH Local Access` is enabled
3. `WAN Remote Access` stays off
4. `IPv6` is disabled
5. `Override DNS Settings for All Clients` is enabled
6. the router timezone is correct
7. `AdGuard Home` is enabled

QuietWrt will check some of these over SSH, but a few GL.iNet-specific settings are still safest to confirm in the UI.

## 2. Local Machine Prerequisites

On the Windows PC where you will run QuietWrt:

1. install `PowerShell 7`
2. install `Posh-SSH`
3. clone this repo

Install `Posh-SSH` once with:

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser
```

## 3. Install Or Update QuietWrt

From the repo root, run:

```powershell
pwsh ./tools/quietwrt.ps1
```

The CLI prompts for:

- router host
  - default: `192.168.8.1`
- router username
  - default: `root`
- router password

After connecting, it:

- checks whether QuietWrt is installed
- fetches the current router status
- shows a numbered menu

Choose:

```text
1. Install/Update QuietWrt
```

The installer:

- uploads:
  - `app/quietwrt.cgi` to `/www/cgi-bin/quietwrt`
  - `app/quietwrtctl.lua` to `/usr/bin/quietwrtctl`
  - `app/quietwrt/*.lua` to `/usr/lib/lua/quietwrt/`
- ensures executable permissions
- ensures a one-time AdGuard backup exists
- creates or refreshes UCI state in `/etc/config/quietwrt`
- installs or refreshes the managed cron block
- installs or refreshes these QuietWrt-managed firewall sections:
  - `firewall.quietwrt_dns_int`
  - `firewall.quietwrt_dot_fwd`
  - `firewall.quietwrt_curfew`
- applies the current schedule immediately

## 4. Daily Control Menu

The local CLI keeps one SSH and SFTP session open and offers:

```text
1. Install/Update QuietWrt
2. Enable/Disable always-on blocklist
3. Enable/Disable workday blocklist
4. Enable/Disable overnight blocking
5. Remove QuietWrt
6. Backup both blocklists to this PC
```

After any state-changing action, it prints the refreshed router status.

The backup option downloads:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`

and saves them in the current local directory with timestamped names such as:

- `quietwrt-always-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-workday-YYYY-MM-DD-HHMMSS.txt`

## 5. Router-Side Defaults

QuietWrt stores persistent toggle state in UCI:

- `quietwrt.settings.always_enabled`
- `quietwrt.settings.workday_enabled`
- `quietwrt.settings.overnight_enabled`

Canonical source data lives in:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`

Schedule windows remain:

- `04:00` to `16:30`
  - `always + workday`
- `16:30` to `18:30`
  - `always` only
- `18:30` to `04:00`
  - internet off

## 6. Verify The Final State

After install, confirm:

1. a site added to `Always blocked` is blocked at `10:00`
2. a site added to `Workday blocked` is blocked at `10:00`
3. a `Workday blocked` site is no longer blocked between `16:30` and `18:30`
4. internet access is fully unavailable between `18:30` and `04:00` when overnight blocking is enabled
5. router-local access to `https://<router-ip>:8443/cgi-bin/quietwrt` still works during the curfew window
6. direct client DNS on `53` is intercepted
7. direct `DoT` on `853` is blocked

## 7. Router Commands

The local CLI uses this router-side surface:

```sh
/usr/bin/quietwrtctl install
/usr/bin/quietwrtctl sync
/usr/bin/quietwrtctl status --json
/usr/bin/quietwrtctl set always on
/usr/bin/quietwrtctl set always off
/usr/bin/quietwrtctl set workday on
/usr/bin/quietwrtctl set workday off
/usr/bin/quietwrtctl set overnight on
/usr/bin/quietwrtctl set overnight off
/usr/bin/quietwrtctl remove
```

Useful direct checks:

```sh
/usr/bin/quietwrtctl status
/usr/bin/quietwrtctl status --json
/usr/bin/quietwrtctl sync
cat /tmp/quietwrt-adguard-restart.log
```
