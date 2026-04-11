# Focus App

This directory contains the router-side Focus app and shared policy code.

## Files

- `focus.cgi`
  - Lua CGI entrypoint for `uhttpd`
  - renders the LAN-only page
  - handles add-entry submissions
- `focusctl.lua`
  - Lua CLI entrypoint for router-side install and scheduled sync
- `focuslib/`
  - shared modules for validation, schedule logic, AdGuard config updates, storage, and rendering

## Router Layout

The current app is a multi-file deployment:

- copy `focus.cgi` to `/www/cgi-bin/focus`
- copy `focusctl.lua` to `/usr/bin/focusctl`
- copy `focuslib/` to `/usr/lib/lua/focuslib/`

## Responsibilities

- keep canonical source lists in `/etc/focus/`
- compile the active AdGuard rules for the current time window
- install cron-based sync points at `04:00`, `16:30`, and `18:30`
- enforce the nightly internet curfew with a firewall rule
- show both blocklists and the current effective mode in the web UI

## Local Testing

Run the local suite with:

```powershell
lua tests\run.lua
```

## Notes

- the web page is still intentionally small and LAN-only
- source-of-truth data now lives in `/etc/focus/`, not directly in AdGuard `user_rules`
- non-block AdGuard `user_rules` are preserved in `/etc/focus/passthrough-rules.txt`
