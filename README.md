# QuietWrt

QuietWrt is a router-side distraction blocking setup for a `GL.iNet GL-MT3000` running stock GL firmware with `AdGuard Home`.

It keeps four canonical blocklists on the router:

- `always blocked`
- `workday blocked`
- `after work blocked`
- `password vault blocked`

It can also enforce wired-client internet lockouts during the nightly curfew, and optionally all day Saturday. Wi-Fi clients remain online during these lockouts.

## Schedule

- `04:00` to `16:30`: `always + workday`
- `16:30` to `19:00`: `always + after work`
- `09:45` to `09:30`: `always + password vault`
- `19:00` to `04:00`: wired internet off when overnight blocking is enabled
- Saturday: wired internet off all day when Saturday blockout is enabled

You can change the `workday`, `after work`, `password vault`, and `overnight` windows later from the PowerShell CLI or with `quietwrtctl schedule ...`.

## How It Works

- `AdGuard Home` handles domain blocking
- QuietWrt treats disabled `AdGuard Home` protection as unhealthy and will not report policy as applied
- QuietWrt stores canonical list files in `/etc/quietwrt/`
- firewall rules reduce DNS bypass and enforce the nightly wired-client curfew
- the curfew uses the MT3000's `eth1` ingress identity on the shared `br-lan`, so wireless clients are not included
- the same wired-client curfew firewall rule is reused for the optional Saturday blockout
- one reconciliation operation is used at boot, by recurring sync jobs, and after state changes
- state-changing operations use a router-side lock and safe file replacement so overlapping cron, boot, web, or CLI actions do not corrupt managed state
- at boot, QuietWrt validates persistent state, repairs its managed bridge-netfilter setting, and applies policy
- if reconciliation fails, QuietWrt removes its restrictions without changing desired policy and latches failsafe-open for the rest of that boot
- a later boot can recover automatically; authenticated operators can explicitly attempt same-boot recovery with `quietwrtctl recover`
- a small LAN page can append new entries to any scheduled blocklist and enable disabled restrictions
- a Windows PowerShell CLI installs, updates, toggles, edits schedule windows, backs up, and restores QuietWrt over SSH

Fresh installs default to:

- `always`: enabled
- `workday`: enabled
- `after work`: enabled
- `password vault`: enabled
- `overnight`: disabled
- `Saturday blockout`: disabled

## Run It

From the repo root:

```powershell
pwsh ./tools/quietwrt.ps1
```

The local CLI can:

- install or update QuietWrt
- enable or disable the `always`, `workday`, `after work`, `password vault`, `overnight`, and `Saturday blockout` toggles
- change the `workday`, `after work`, `password vault`, and `overnight` schedule windows
- save router blocklist and schedule-timing backups into `backups/`
- restore the newest matching blocklist and `quietwrt-schedules-*` backups without changing enable/disable choices

To clean up old local backups, run:

```powershell
.\tools\prune-backups.ps1
```

The script shows which backup files will remain, which old backup files will be deleted, and asks for confirmation before deleting anything.

Detailed setup and operating instructions live in `docs/router-install.md`.

## Tests

Lua:

```powershell
lua tests\run.lua
```

PowerShell:

```powershell
powershell -NoProfile -Command "Invoke-Pester -Path .\tests\powershell\quietwrt.Tests.ps1 -EnableExit"
```
