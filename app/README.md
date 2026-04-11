# QuietWrt App

This directory contains the router-side QuietWrt app and shared policy code.

## Files

- `quietwrt.cgi`
  - Lua CGI entrypoint for `uhttpd`
  - renders the LAN-only page
  - handles add-entry submissions
- `quietwrtctl.lua`
  - Lua CLI entrypoint for router-side install, status, toggle, sync, and removal
- `quietwrt/`
  - shared modules for validation, schedule logic, AdGuard config updates, UCI-backed toggle state, storage, and rendering

## Router Layout

The current router-side deployment is a multi-file app:

- copy `quietwrt.cgi` to `/www/cgi-bin/quietwrt`
- copy `quietwrtctl.lua` to `/usr/bin/quietwrtctl`
- copy `quietwrt/` to `/usr/lib/lua/quietwrt/`

## Responsibilities

- keep canonical source lists in `/etc/quietwrt/`
- keep persistent enable and disable flags in `/etc/config/quietwrt`
- compile the active AdGuard rules for the current time window
- install cron-based sync points at `04:00`, `16:30`, and `18:30`
- reconcile QuietWrt-managed firewall hardening for:
  - DNS interception on `53`
  - `DoT` blocking on `853`
  - the nightly internet curfew
- show both blocklists and the current effective mode in the web UI

## Router CLI

The router-side control plane exposes:

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

## Local Testing

Run the local suite with:

```powershell
lua tests\run.lua
```

PowerShell coverage for the local installer and control CLI lives in:

```text
tests/powershell/quietwrt.Tests.ps1
```

## Notes

- the web page is still intentionally small and LAN-only
- source-of-truth data now lives in `/etc/quietwrt/`, not directly in AdGuard `user_rules`
- non-block AdGuard `user_rules` are preserved in `/etc/quietwrt/passthrough-rules.txt`
