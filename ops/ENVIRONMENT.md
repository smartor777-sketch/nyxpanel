# Environment — what is actually different per host

Derived from the 2026-10-04 audit of the dev stand. Every item here is
host-specific and currently hardcoded in the body of `bin/proxy_manager.sh`,
which is why the orchestrator drifts.

Move all of these into a config layer (`/etc/nyxpanel/proxy.env`, read with
`: "${VAR:?}"` so a missing value fails loudly instead of silently expanding empty).

| Variable | git `bin/` | dev stand | Note |
|---|---|---|---|
| `HY2_CONFIG` | `/etc/hysteria/config.yaml` | `/etc/hysteria/config.json` | this host's hysteria stores JSON |
| `TROJAN_CERT` / `TROJAN_KEY` | `/var/lib/caddy/caddy/certificates/…` | `/root/.local/share/caddy/certificates/…` | Caddy runs as root here, so its data dir differs |
| `VLESS_SNI` | `1.1.1.1` | `www.roblox.com` | chosen whitelist SNI — also the value embedded in generated `vless://` links |
| `VLESS_PORT` | 4433 | 4433 | same |
| `SERVER_DOMAIN` | — | `vpn.example.com` | |

## Secrets — must not live in the repository

These are present in `bin/proxy_manager.sh` at the lines shown and are **live
values**, not placeholders:

| Line | Variable | Must |
|---|---|---|
| 21 | `MIERU_IP` | move to `.env`; rotate if the host is meaningful |
| 47 | `VLESS_PUBLIC_KEY` | move to `.env`; **rotate** — it is the server's REALITY identity |
| 48 | `VLESS_SHORT_ID` | move to `.env`; **rotate** |

Rotating matters because the values are in git history, so removing them from the
working tree does not remove them from the repository. `docs/MIGRATION_CADDY_TO_ANGIE.md`
also carries a literal password in an example.

## Paths and layout to normalise

| Thing | Now | Should be |
|---|---|---|
| user configs | `BASE_DIR = /root/proxy_users` | `/var/lib/nyxpanel/users`, group-readable, so the panel need not run as root |
| panel DB | `/opt/proxy-panel/panel.db` | `/var/lib/nyxpanel/panel.db` |
| tproxy state | `/etc/tproxy-server/{profiles,modes,tg_mappings}.json` | same state dir |
| traffic deltas | `/opt/proxy-panel/*_last.json` | same state dir |
| panel secrets | none — falls back to `os.urandom(16)` | `.env`, fail-fast if absent |
| Caddy cert dir | differs per user | ask Caddy, don't hardcode |

## Ports — verified in use on the dev stand

Do not reuse these:

```
22  53  80  443  444  445  446  447  448  2019
2398  2399  4433  5000  5432  6379
8000  8001  8002  8080  8088  8090  8091  8443  8449  9443  10000  10443  10806
30000  39743  56000  56001
```

Free on that host, verified: 5001, 5002, 8081, 8092, 8444, 9444, 10444, 10445,
14433, 3100, 51821.

## Subnets and interfaces — verified in use

```
ens3    203.0.113.20/32
awg0    10.9.9.1/24
vpn0    10.9.0.1/24      (qeli reality-tls)
vpn7    10.9.7.1/24      (qeli udp-quic)
wdtt0   10.66.66.1/24
docker0 172.17.0.1/16
```

Free, non-overlapping: `10.77.0.0/24` (reserved in the dev plan for `awgtest0`),
`10.78.0.0/24`.

`10.9.7.1:53` and `10.9.0.1:53` are **qeli's DNS**, opened in UFW only from their own
tunnel subnets. Any change there belongs to the qeli project, not to nyxpanel.

## Not nyxpanel — do not touch during nyxpanel work

| Service | Where |
|---|---|
| qeli 0.8.1 | `/etc/qeli/`, `qeli.service`, ports 10443, 8449/udp, `10.9.x:53` |
| `mita` | `/usr/bin/mita`, ports 444-448 |
| `microbin` | `/opt/microbin/`, `paste.example.com` → 8088 |
| `sleep-test` | `sleep-test.example.com` → 127.0.0.1:8000 |
| `web` | `web.example.com` → 127.0.0.1:8090 |
| monitoring | grafana/prometheus/node-exporter/netdata/uptime-kuma/monit — UFW rules exist, **nothing listening**; the rules are dead and may be pruned |
