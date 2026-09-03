# Router Install And Operation

This is the main operator guide for `QuietWrt`.

QuietWrt is designed around a `GL.iNet GL-MT3000` running stock GL firmware with `AdGuard Home` enabled. There is no uninstall flow. If you want to fully remove QuietWrt from the router, use your normal router reset / rebuild process.

## 1. Router Prerequisites

Before installing QuietWrt, confirm these in the GL.iNet admin UI:

1. the router is in `Router` mode
2. `SSH Local Access` is enabled
3. `WAN Remote Access` stays off
4. `IPv6` is disabled
5. `Override DNS Settings for All Clients` is enabled
6. the router timezone is correct
7. `AdGuard Home` is enabled and protection is on

QuietWrt targets the stock GL-MT3000 topology exactly: wired LAN on `eth1`, WAN on `eth0`, and `eth1` attached to `br-lan`. Install/update checks this topology and the fw3/iptables-legacy firewall before making changes.

## 2. Local Machine Prerequisites

On the Windows machine where you will run the local CLI:

1. install `PowerShell 7`
2. install `Posh-SSH`
3. clone this repo

Install `Posh-SSH` once with:

```powershell
Install-Module -Name Posh-SSH -Scope CurrentUser
```

## 3. Install Or Update QuietWrt

From the repo root:

```powershell
pwsh ./tools/quietwrt.ps1
```

The CLI prompts for:

- router host
  default: `192.168.8.1`
- router username
  default: `root`
- router password

Choose:

```text
1. Install/Update QuietWrt
```

Install/update uploads these router-side files:

- `app/quietwrt.cgi` -> `/www/cgi-bin/quietwrt`
- `app/quietwrtctl.lua` -> `/usr/bin/quietwrtctl`
- `app/quietwrt.init` -> `/etc/init.d/quietwrt`
- `app/quietwrt/*.lua` -> `/usr/lib/lua/quietwrt/`

It then:

- installs the official `kmod-ipt-physdev` and `iptables-mod-physdev` packages if needed
- enables bridge IPv4 firewall visibility at runtime and persists it in `/etc/sysctl.d/99-quietwrt-bridge-netfilter.conf`
- creates or validates the canonical QuietWrt files in `/etc/quietwrt/`
- writes persistent toggle state in UCI under `quietwrt.settings.*`
- installs the managed cron block
- enables the QuietWrt boot check and sync init script
- installs or refreshes the managed firewall sections
- applies the current schedule state immediately

The overnight and Saturday lockouts match routed traffic that entered through wired LAN device `eth1`. Wi-Fi clients on the shared `br-lan` remain online. QuietWrt does not create a second network, subnet, DHCP service, or firewall zone.

Fresh installs currently default to:

- `always`: enabled
- `workday`: enabled
- `after work`: enabled
- `password vault`: enabled
- `overnight`: disabled
- `Saturday blockout`: disabled

This keeps full-internet lockouts off until you explicitly enable them after confirming the rest of the install behaves as expected.

If `AdGuard Home` protection is disabled, installation is rejected instead of reporting a healthy QuietWrt install.

## 4. Daily Control Menu

The local CLI keeps one SSH session plus an SCP-backed file transfer connection open and offers:

```text
1. Install/Update QuietWrt
2. Enable/Disable always-on blocklist
3. Enable/Disable workday blocklist
4. Enable/Disable after-work blocklist
5. Enable/Disable password vault blocklist
6. Enable/Disable overnight blocking
7. Enable/Disable Saturday blockout
8. Set workday window
9. Set after-work window
10. Set password vault window
11. Set overnight window
12. Backup all blocklists and schedule timings to this PC
13. Restore latest backup
```

After any state-changing action, it prints the refreshed router status.

## 5. Backup And Restore

Backups are stored locally in the repo `backups/` directory.

Backup filenames are:

- `quietwrt-always-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-workday-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-after-work-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-password-vault-YYYY-MM-DD-HHMMSS.txt`
- `quietwrt-schedules-YYYY-MM-DD-HHMMSS.txt`

The schedule file is versioned and contains only the start and end times for the workday, after-work, password-vault, and overnight windows. It does not contain enable/disable settings.

The restore option:

- looks in `backups/`
- chooses the newest matching `quietwrt-always-*` file
- chooses the newest matching `quietwrt-workday-*` file
- chooses the newest matching `quietwrt-after-work-*` file
- chooses the newest matching `quietwrt-password-vault-*` file
- chooses the newest matching `quietwrt-schedules-*` file
- shows the selected filenames before restoring
- works with any subset of the files
- leaves unselected router-side lists and timings untouched
- preserves every current blocklist and lockout enable/disable choice
- validates all selected files before making changes, then restores them and reconciles policy as one operation

The ZIP downloaded from the LAN blocklists page also contains `quietwrt-schedules.txt`. Importing an older ZIP without this file still works and leaves current timings unchanged.

## 6. Schedule And Reconciliation

Fresh installs default to these windows:

- `04:00` to `16:30`: `always + workday`
- `16:30` to `19:00`: `always + after work`
- `09:45` to `09:30`: `always + password vault`
- `19:00` to `04:00`: wired internet off when overnight blocking is enabled
- Saturday: wired internet off all day when Saturday blockout is enabled

QuietWrt uses the same locked reconciliation operation whenever an installed policy is applied:

- after list, toggle, or schedule changes
- on boot through `/etc/init.d/quietwrt`
- through cron at each configured window boundary and every `10` minutes as a backstop

Install/update uses a separate transactional bootstrap around the same policy-application engine.

The Saturday blockout relies on the recurring `10` minute backstop instead of adding day-specific cron entries, so start/end changes around midnight can drift by up to about `10` minutes.

State-changing operations are serialized with a router-side lock at `/tmp/quietwrt.lock`. This keeps overlapping cron, boot, web, and CLI actions from applying state at the same time.

Reconciliation validates desired state, repairs the bridge-netfilter runtime it owns, and then applies AdGuard Home and firewall state. If validation or application fails, the safe-open path removes the full-internet curfew before touching AdGuard Home so an unreadable AdGuard config cannot keep a stale Saturday or overnight curfew enabled.

## 7. Boot Failsafe

At boot, the procd-managed QuietWrt one-shot service waits `15` seconds and runs:

```sh
/usr/bin/quietwrtctl boot-check
```

This is the same reconciliation used by `sync`. It first validates persistent state, then reapplies QuietWrt's managed bridge-netfilter sysctl and retries transient platform readiness for up to about `30` seconds before applying policy:

- AdGuard Home config is readable
- QuietWrt UCI settings are valid
- canonical list files exist and parse
- the router is the supported `glinet,mt3000-snand` board with `eth1` attached to `br-lan`
- fw3/iptables legacy, the physdev match, and bridge-netfilter configuration are ready

If validation, platform preparation, or policy application fails, QuietWrt enters failsafe-open mode. It removes the managed firewall sections and clears QuietWrt blocking rules from AdGuard Home when the AdGuard config is readable, but preserves the saved toggle choices so they can be restored after recovery. It writes:

```text
/etc/quietwrt/failsafe-open.txt
```

The marker records the current kernel boot ID. Once failsafe opens, it remains latched for the rest of that boot. Recurring cron syncs idempotently maintain the open state and cannot recreate QuietWrt restrictions, even if the original failure later disappears. This preserves router and internet access long enough for recovery.

On a later boot, the kernel boot ID is different, so boot reconciliation may repair the problem, apply the complete saved policy, and then clear the marker. The marker is cleared only after both AdGuard Home and firewall application succeed. A successful authenticated install/update also clears it.

To deliberately attempt recovery during the same boot over SSH, run:

```sh
/usr/bin/quietwrtctl recover
```

The LAN web page cannot perform same-boot recovery. While failsafe is latched, its mutation operations are rejected. A legacy marker without a boot ID is conservatively latched for the current boot; safe-open maintenance stamps it with the current boot ID so a later boot can recover normally.

## 8. Managed Router State

Canonical QuietWrt data lives here:

- `/etc/quietwrt/always-blocked.txt`
- `/etc/quietwrt/workday-blocked.txt`
- `/etc/quietwrt/after-work-blocked.txt`
- `/etc/quietwrt/password-vault-blocked.txt`
- `/etc/quietwrt/passthrough-rules.txt`
- `/etc/quietwrt/failsafe-open.txt`

QuietWrt-managed firewall sections are:

- `firewall.quietwrt_dns_int`
- `firewall.quietwrt_dot_fwd`
- `firewall.quietwrt_curfew`

The curfew section remains a normal `lan -> wan` fw3 rule, with this wired-ingress match:

```text
-m physdev --physdev-in eth1 ! --physdev-is-bridged
```

QuietWrt also manages:

- `/etc/sysctl.d/99-quietwrt-bridge-netfilter.conf`
- runtime sysctl `net.bridge.bridge-nf-call-iptables=1`
- package prerequisites `kmod-ipt-physdev` and `iptables-mod-physdev`

QuietWrt UCI state lives under:

- `quietwrt.settings.always_enabled`
- `quietwrt.settings.workday_enabled`
- `quietwrt.settings.after_work_enabled`
- `quietwrt.settings.password_vault_enabled`
- `quietwrt.settings.overnight_enabled`
- `quietwrt.settings.saturday_blockout_enabled`
- `quietwrt.settings.workday_start`
- `quietwrt.settings.workday_end`
- `quietwrt.settings.after_work_start`
- `quietwrt.settings.after_work_end`
- `quietwrt.settings.password_vault_start`
- `quietwrt.settings.password_vault_end`
- `quietwrt.settings.overnight_start`
- `quietwrt.settings.overnight_end`
- `quietwrt.settings.schema_version`

## 9. Manual List Editing

You can edit the canonical files directly on the router, then run:

```sh
/usr/bin/quietwrtctl sync
```

Rules to keep in mind:

- `always-blocked.txt`, `workday-blocked.txt`, `after-work-blocked.txt`, and `password-vault-blocked.txt` must contain canonical lowercase hostnames
- `passthrough-rules.txt` is for non-block AdGuard rules that should be preserved
- bad manual edits are reported and trigger failsafe-open instead of silently rebuilding lossy state

The local web page is append-only by design:

- it can add entries to `always`, `workday`, `after work`, or `password vault`
- it can enable disabled blocklists and lockouts
- it cannot delete entries
- it cannot edit passthrough rules
- it cannot disable enforcement
- it cannot disable blocklists or lockouts

## 10. Verify A Working Install

After install, confirm:

1. a site added to `Always blocked` is blocked during daytime hours
2. a site added to `Workday blocked` is blocked before `16:30`
3. a site added to `After work blocked` is blocked between `16:30` and `19:00`
4. a site added to `Password vault blocked` is blocked except during the daily `09:30` to `09:45` opening
5. wired internet access is unavailable between `19:00` and `04:00` when overnight blocking is enabled
6. wired internet access is unavailable on Saturday when Saturday blockout is enabled
7. a Wi-Fi phone remains online during both wired lockouts
8. router-local access to `https://<router-ip>:8443/cgi-bin/quietwrt` still works during lockout windows
9. direct client DNS on `53` is intercepted
10. direct `DoT` on `853` is blocked

## 11. Direct Router Commands

Useful direct commands:

```sh
/usr/bin/quietwrtctl install
/usr/bin/quietwrtctl boot-check
/usr/bin/quietwrtctl sync
/usr/bin/quietwrtctl recover
/usr/bin/quietwrtctl status
/usr/bin/quietwrtctl status --json
/usr/bin/quietwrtctl set always on
/usr/bin/quietwrtctl set always off
/usr/bin/quietwrtctl set workday on
/usr/bin/quietwrtctl set workday off
/usr/bin/quietwrtctl set after_work on
/usr/bin/quietwrtctl set after_work off
/usr/bin/quietwrtctl set password_vault on
/usr/bin/quietwrtctl set password_vault off
/usr/bin/quietwrtctl set overnight on
/usr/bin/quietwrtctl set overnight off
/usr/bin/quietwrtctl set saturday_blockout on
/usr/bin/quietwrtctl set saturday_blockout off
/usr/bin/quietwrtctl schedule workday 0400 1630
/usr/bin/quietwrtctl schedule after_work 1630 1900
/usr/bin/quietwrtctl schedule password_vault 0945 0930
/usr/bin/quietwrtctl schedule overnight 1900 0400
/usr/bin/quietwrtctl export-schedules
/usr/bin/quietwrtctl restore --always /path/to/quietwrt-always-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --workday /path/to/quietwrt-workday-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --after-work /path/to/quietwrt-after-work-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --password-vault /path/to/quietwrt-password-vault-YYYY-MM-DD-HHMMSS.txt
/usr/bin/quietwrtctl restore --schedules /path/to/quietwrt-schedules-YYYY-MM-DD-HHMMSS.txt
cat /tmp/quietwrt-adguard-restart.log
cat /tmp/quietwrt-boot-reconcile.log
```
