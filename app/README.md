# Focus App

This directory contains the first router-side implementation of the local management app.

## Files

- `focus.cgi`
  - Lua CGI script for `uhttpd`
  - reads AdGuard Home custom rules
  - appends one new block rule at a time
  - writes changes by updating `/etc/AdGuardHome/config.yaml`
  - restarts AdGuard Home after each successful append

## Assumptions

This version assumes:

- `uhttpd` serves `/www` and `/www/cgi-bin`
- AdGuard Home uses `/etc/AdGuardHome/config.yaml`
- the router has `/etc/init.d/adguardhome`

## Router Install

Copy the CGI script to the router and make it executable:

```sh
scp -O app/focus.cgi root@192.168.8.1:/www/cgi-bin/focus
ssh root@192.168.8.1 "chmod 755 /www/cgi-bin/focus"
```

Then open the page:

- `https://192.168.8.1:8443/cgi-bin/focus`

Use your router's actual LAN IP if it is different.

## Notes

- This script only appends block rules.
- It does not delete rules, edit rules, or manage exceptions.
- It treats AdGuard Home `user_rules` as the source of truth.
