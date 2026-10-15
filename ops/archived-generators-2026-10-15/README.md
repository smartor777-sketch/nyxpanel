# Archived orchestrator copies — 2026-10-15

These three copies of the orchestrator are retired. **Do not deploy them.**
The canonical copy is `bin/proxy_manager.sh`.

| archived file | was | last touched |
|---|---|---|
| `proxy_manager.root-copy.sh` | `proxy_manager.sh` | 2026-08-25 |
| `proxy_manager.server-copy.sh` | `server/proxy_manager.sh` | 2026-08-25 |
| `proxy_manager.server-dev-copy.sh` | `server/proxy_manager_dev.sh` | 2026-08-25 |

## Why they were retired

All three carried the same broken AmneziaWG peer-stripping rule:

```sh
$0 ~ "^# Peer: " user { skip=1; next }
skip && /^\[Peer\]/ { skip=0 }
!skip { print }
```

It fails three ways, each covered by a case in `tests/test_awg_strip.sh`:

1. **The label becomes a regular expression.** A label holding a metacharacter
   (`beta+x`) matches nothing, so the peer cannot be deleted at all.
2. **The label is matched as a substring.** Removing `gamma` also matches
   `# Peer: gamma2` and deletes a second peer. Not hypothetical here: the
   user `test` already exists, so adding `test2` and then deleting `test`
   would have removed both.
3. **`skip` is cleared on `[Peer]` — the block's own header.** That line has no
   `next`, falls through to the print branch, and a bare `[Peer]` survives. This
   is the failure that took AmneziaWG down on prod: `awg-quick` rejects the file
   and removes the interface, taking every peer offline.

`bin/proxy_manager.sh` was already fixed for defect 3 but still had defects 1
and 2. All copies now use one rule, and all four pass the same test:

```sh
$0 == "# Peer: " user { skip=1; next }
skip && (/^# Peer: / || /^[[:space:]]*$/) { skip=0; print; next }
skip { next }
{ print }
```

Rotated VLESS keypairs were cleared from these copies on the way in. They were
already invalid, but the repository does not hold concrete service values —
`bin/proxy_manager.sh` reads them from `/etc/nyxpanel/proxy.env` and never
stores them.

## What changed for consumers

`server/install.sh` used to install `server/proxy_manager.sh` and fetched that
path from GitHub. Both now point at `bin/proxy_manager.sh`, which is what
`panel/proxy-panel/setup.sh` installs and what `tests/` exercises.

Note that `server/install.sh` fetches from the **public** repository on the
**master** branch:

```sh
REPO_URL="https://raw.githubusercontent.com/smartor777-sketch/nyxpanel/master"
```

The canonical source is the private repository on `main`. The installer
therefore cannot see changes made on `main` until that URL and branch are
repointed. Not changed here — it needs a decision, because it changes where
deployments pull from.