# Dev stand — actual state, captured 2026-10-04

Read-only capture of `stand.example.com` (203.0.113.20). No services were
stopped, restarted or reconfigured.

## Identity

| | |
|---|---|
| Host | stand.example.com |
| IP | 203.0.113.20/32 on ens3 |
| OS | Debian GNU/Linux 13 (trixie), kernel 6.12.96 |
| Uptime | 65 days |
| CPU / RAM / Disk | 2 cores / 3.9 GB / 60 GB (39 GB free) |
| Not a container | no `/.dockerenv` |

## What runs here

This box is **not a dedicated dev stand** — it carries four separate projects:

| Project | Units | Public entry |
|---|---|---|
| nyxpanel proxy stack | `panel`, `xray`, `hysteria2`, `sing-box-naive`, `trojan-go`, `olcrtc`, `tproxy-server`, `mtproxy`, `mtproxy-public` | `vpn.example.com` (443), xray 4433, sing-box 8443, mtproto 2398/2399 |
| **qeli 0.8.1** | `qeli server --config /etc/qeli/server.conf` | 10443/tcp (reality-tls), 8449/udp (udp-quic) |
| monitoring | netdata, grafana, prometheus, node-exporter, uptime-kuma, monit | **rules present in UFW, nothing listening** |
| misc | `mita run` (\*:444-448), `microbin` (paste.example.com → 8088), `sleep-test.example.com`, `web.example.com`, postgres, redis, 3× uvicorn, innercore-celery | see UFW list |

qeli is **not mentioned anywhere in nyxpanel or its docs**, yet it is the project
`docs/NYTUNNEL_SPEC.md` §19 proposes to borrow Reality TLS / traffic shaping from.
It has its own `users.conf`, `identity/`, `client-links/` and `panel-secret.key`.

## Version drift: server vs git

Neither running file matches **any** commit in the repository. Both are uncommitted
server-local edits.

| File | server | git `master` | closest commit | distance |
|---|---|---|---|---|
| `app.py` | 633 lines, 24939 B, Aug 24 | 926 lines, 35765 B, Sep 26 | `9b80787` (v1.10, Aug 25) | **+7 lines** |
| `proxy_manager.sh` | 1167 lines, 50014 B, Aug 24 | `bin/` 1165 lines, 45024 B | `bin/` @ HEAD | **+18 lines** |
| `collector.py` | 8658 B | 8658 B | — | **byte-identical** |

So the panel runs **v1.10 while master is v1.12**. Everything added after Aug 25 is
absent from this host: the tproxy web panel, the Telegram bot, mobile layout.
Correspondingly `templates/tproxy_profiles.html` is not deployed (the running
`app.py` has no tproxy routes, so this is consistent, not broken).

Patches for the two deltas are in this directory.

## Reconciliation direction

**`bin/proxy_manager.sh` in git is correct; the server copy is a regression of it.**
The server's local delta contains two defects that git does not have:

1. **Corrupted VLESS URI line** (`proxy_manager.running.sh:929`, 1508 chars).
   `bash -n` passes — the damage is logical, not syntactic: the repeated
   `local link=…` assignments leave `$link` empty, so `…_vless.uri` is written blank.
   Live evidence: `/root/proxy_users/test/test_vless.uri` is **1 byte**.
   `hardtest` and `user01` have 239/236 B files dated Aug 21, i.e. before the damage.
2. **Dropped `email` from Xray clients**:
   `clients = [{'id': uid, 'flow': ''} …]` instead of `… 'email': uname …`.
   Live Xray config confirms `clients: 3, with email: 0`, and `stats: null`,
   `policy: null` — Xray cannot attribute traffic to anyone.

**Therefore: deploy from git, do not commit the server copy back.** The only
server-local values worth keeping are the environment-specific ones, listed below.

## Environment-specific values on this host (not bugs)

| git `bin/proxy_manager.sh` | server | why |
|---|---|---|
| `HY2_CONFIG="/etc/hysteria/config.yaml"` | `/etc/hysteria/config.json` | this host's hysteria uses JSON |
| Trojan certs under `/var/lib/caddy/…` | `/root/.local/share/caddy/…` | Caddy runs as root here |
| `VLESS_SNI="1.1.1.1"` | `"www.roblox.com"` | chosen whitelist SNI |
| `reality_status` echoes a fixed `REALITY_NORMAL_SNI` | derives `sni` from `target` | better behaviour, worth porting |

These belong in a config layer, not hardcoded — see `ops/ENVIRONMENT.md`.

## Data reality

`panel.db`: 4 users (`admin`, `test`, `user01`, `hardtest`), all `active=1`, none
expiring. `daily_traffic` = **0 rows**, `traffic_log` = **0 rows**.

Traffic accounting has never produced data on this host:

- `collector.py` is deployed but **not scheduled** — no cron entry, no systemd timer,
  no process.
- `*_last.json` all contain `{"other": 67890}` — not the format `collector.py` writes,
  i.e. placeholder files.
- Xray has `stats: null` / `policy: null` and no client emails (above), so the
  primary source is blind too.

## Panel exposure

`Caddyfile` routes `/panel/*`, `/user/*`, `/self/*`, `/samples/*`, `/static/*` to
`127.0.0.1:5000` with **no authentication at the Caddy layer** (the `basic_auth`
in that block belongs to `forward_proxy` only).

Verified from outside this host:

```
GET https://vpn.example.com/self/api/v1/users          -> 200, full user list
GET https://vpn.example.com/self/api/v1/traffic/totals -> 200
GET https://vpn.example.com/self/api/v1/sub/<name>      -> 404 "User not found"
```

`api_subscription` (`app.py:586` on the running copy) performs **no session check**:
it resolves `BASE_DIR / name` and returns hy2/naive/trojan/vless/awg material for
any existing username. The username list is served by the endpoint above.

**This is an open credential-disclosure path and is treated as the top item in
`nyx-analysis.md`.** No real user config was downloaded during this audit.

## Not changed

Nothing on this host was modified. The only write performed was adding one
ssh-ed25519 public key to `/root/.ssh/authorized_keys` to replace password auth.
