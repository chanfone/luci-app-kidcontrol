# luci-app-kidcontrol

OpenWrt/ImmortalWrt LuCI parental control helper backed by AdGuard Home.

## What It Installs

- `服务 -> 儿童上网管控` LuCI page
- MAC-based child device DNS enforcement
- DNS hijack for managed child devices to AdGuard Home
- DoT `853` blocking for managed child devices
- Category switches for short video, game platforms, proxy DNS, and common apps
- Custom domain blocklist import/export
- Device lookup by name, IP, or MAC from DHCP static leases, current leases, and neighbor table
- Sysupgrade preserve entries for plugin files and configuration

## Install

```sh
opkg install luci-app-kidcontrol_1.0.0-1_all.ipk
```

After installing, open LuCI and go to:

```text
服务 -> 儿童上网管控
```

## Notes

This package does not include private child devices, MAC addresses, or custom adult-domain rules.
Those should live in `/etc/config/kidcontrol` or be imported from the LuCI page.

AdGuard Home must already be installed and listening on the configured DNS port, usually `3053`.
