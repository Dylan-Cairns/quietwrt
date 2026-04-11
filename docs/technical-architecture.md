# Technical Architecture

## Summary

The current QuietWrt system has four parts:

- `Local Control CLI`
- `Policy Manager`
- `Router Enforcement`
- `Local Management App`

The local control CLI runs on Windows, while enforcement remains on the `GL.iNet GL-MT3000`.

## Components

### Local Control CLI

The local control CLI is `tools/quietwrt.ps1`.

It:

- runs in `PowerShell 7`
- uses `Posh-SSH` to keep one SSH and SFTP session open
- prompts for router host, username, and password
- uploads QuietWrt files to the router
- calls the router-side install, status, toggle, sync, and remove commands
- downloads canonical blocklist backups to the local PC

### Policy Manager

The policy manager lives in shared Lua modules plus the `quietwrtctl` CLI entrypoint.

It:

- reads the canonical source lists
- validates and normalizes input
- compiles the active AdGuard rules for the current time window
- updates AdGuard Home safely
- restores the previous AdGuard config if restart fails
- installs the schedule that keeps policy and firewall state in sync
- stores persistent toggle state in UCI
- owns install, status, toggle, sync, and removal behavior

### Router Enforcement

Router enforcement uses:

- `AdGuard Home` for DNS blocking
- firewall rules to reduce DNS bypass
- a scheduled firewall curfew that blocks `LAN -> WAN` traffic from `18:30` to `04:00`
- `IPv6` disabled

### Local Management App

The local app is a LAN-only CGI page.

It:

- shows current mode and protection status
- shows the `always` and `workday` blocklists separately
- accepts one new domain or URL at a time
- lets the user choose which list to append to
- triggers a policy apply after successful submission

## Persistent State

The router stores:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`
- `/etc/config/quietwrt`
- `/etc/AdGuardHome/config.yaml`
- `/etc/crontabs/root`

The UCI package stores:

- `quietwrt.settings.always_enabled`
- `quietwrt.settings.workday_enabled`
- `quietwrt.settings.overnight_enabled`

## Active Modes

- `04:00` to `16:30`
  - `always + workday`
- `16:30` to `18:30`
  - `always` only
- `18:30` to `04:00`
  - internet off

Weekend behavior currently matches weekdays.

## Main Flows

### Manual Edit

1. Update one of the files in `/etc/quietwrt/`.
2. Run `quietwrtctl sync`.
3. Keep the previous config if apply or restart fails.

### App Addition

1. Submit a domain or URL in the local app.
2. Normalize and validate the hostname.
3. Update `always` or `workday`.
4. Rebuild the active AdGuard rules for the current mode.
5. Reload the page with the result.

### Local CLI Install Or Update

1. Run `pwsh ./tools/quietwrt.ps1`.
2. Open one SSH and SFTP session to the router.
3. Run preflight checks and show any remaining UI checklist items.
4. Upload `quietwrt.cgi`, `quietwrtctl`, and shared Lua modules.
5. Run `quietwrtctl install`.
6. Print refreshed router status.

### Scheduled Sync

1. `cron` runs `quietwrtctl sync`.
2. The policy manager computes the current mode from router local time.
3. It writes the correct AdGuard rule set.
4. It enables or disables the firewall curfew rule as needed.
5. It honors the persistent `always`, `workday`, and `overnight` UCI flags.

### Local Backup

1. Choose `Backup both blocklists to this PC` in the local CLI.
2. Download `/etc/quietwrt/always-blocked.txt`.
3. Download `/etc/quietwrt/workday-blocked.txt`.
4. Save both in the current local working directory with timestamped names.

## Boundaries

- the router is the trust boundary
- client devices are not trusted
- the local app is not an admin console
- the local app cannot delete entries, edit passthrough rules, or disable enforcement
- the local CLI is a transport and UX layer, not the source of policy truth
