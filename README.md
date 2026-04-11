# QuietWrt

This repo documents `QuietWrt`, a distraction-blocking setup built around a `GL.iNet GL-MT3000`.

## Goal

- keep two router-side blocklists:
  - `always blocked`
  - `workday blocked`
- make bypass harder than device-side blocking
- preserve narrow exceptions for required services such as a work VPN
- fully disable internet access each day from `18:30` to `04:00`
- provide a small LAN-only page that shows status and lets new entries be appended
- provide a Windows-first local CLI that can install, update, toggle, remove, and back up QuietWrt over SSH

## Current Design

- `policy manager`
  - validates input
  - stores canonical lists on the router
  - compiles the active AdGuard rules for the current time window
  - applies updates safely and restores the previous config on restart failure
- `local control CLI`
  - PowerShell 7 + `Posh-SSH`
  - prompts for router host, username, and password
  - uploads QuietWrt, runs router-side install/update/remove commands, and downloads list backups
- `router enforcement`
  - `AdGuard Home` for domain blocking
  - firewall rules to reduce DNS bypass
  - a scheduled LAN-to-WAN curfew rule
  - `IPv6` disabled
- `local management app`
  - LAN-only
  - shows current mode and both blocklists
  - lets a new host be added to either `always` or `workday`

## Schedule

- `04:00` to `16:30`: `always + workday`
- `16:30` to `18:30`: `always` only
- `18:30` to `04:00`: internet off

## Local CLI

Run the interactive installer and control menu with:

```powershell
pwsh ./tools/quietwrt.ps1
```

The CLI:

- prompts for router host, username, and password
- checks whether QuietWrt is already installed
- shows the current status of:
  - `always`
  - `workday`
  - `overnight`
- offers:
  - `Install/Update QuietWrt`
  - `Enable/Disable always-on blocklist`
  - `Enable/Disable workday blocklist`
  - `Enable/Disable overnight blocking`
  - `Remove QuietWrt`
  - `Backup both blocklists to this PC`

## Local Testing

Run the Lua suite with:

```powershell
lua tests\run.lua
```

Run the PowerShell suite with:

```powershell
powershell -NoProfile -Command "Invoke-Pester -Path .\tests\powershell\quietwrt.Tests.ps1 -EnableExit"
```

## Docs

- `docs/router-install.md`
- `docs/technical-architecture.md`
- `docs/router-enforcement-design.md`
- `docs/blocklist-maintenance-design.md`
- `docs/local-management-app-design.md`
