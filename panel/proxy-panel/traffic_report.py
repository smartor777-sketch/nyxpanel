"""Calendar-anchored traffic reporting.

The problem this solves: `daily_traffic` only has a row for a day in which
something was counted. Reading "the last day with data" as "the current state"
means a counter that broke three weeks ago looks identical to a user who simply
stopped generating traffic. On prod, trojan's last row was 21 days old and hy2's
22 — both were presented as normal.

So every figure here is anchored to real calendar days generated from today's
date, never from the last row that happens to exist. Each day carries one of
three states:

    data    — the collector ran and counted something
    zero    — the collector ran and there was no traffic
    missing — the collector did not run, or the source was unreadable

A day's state comes from collector_health, which the collector writes whether or
not it managed to read anything. That is what makes "no traffic" distinguishable
from "no data", and it is the difference between a useful counter and a counter
that lies quietly.
"""
import datetime

# Protocols in display order. The key is what daily_traffic.protocol holds.
PROTOCOLS = [
    ("awg", "AmneziaWG"),
    ("vless", "VLESS"),
    ("troy", "Trojan"),
    ("hy2", "Hysteria2"),
]

# Health status -> what the operator should be told.
#
# "idle" is deliberately grouped with "ok": a counter that is up, reachable and
# reporting zero means the protocol is unused, which is not a fault. Painting it
# red trained everyone to ignore the red.
STATUS_LABEL = {
    "ok": ("ok", "считает"),
    "idle": ("ok", "считает, трафика не было"),
    "unavailable": ("bad", "источник недоступен"),
    "not_configured": ("bad", "счётчики не включены"),
    "unsupported": ("bad", "счётчики недоступны"),
    "unattributable": ("bad", "нет сопоставления с пользователями"),
    "error": ("bad", "ошибка сбора"),
    # No row at all: the collector has never reported on this protocol.
    "absent": ("bad", "нет данных ни разу"),
}


def date_range(days, today=None):
    """The last `days` calendar dates, oldest first, ending on today."""
    today = today or datetime.date.today()
    return [(today - datetime.timedelta(days=i)) for i in range(days - 1, -1, -1)]


def build(db, days=30, today=None):
    """Assemble the calendar-anchored report.

    Returns a dict with, per user, per-protocol daily values; and a global
    `health` block naming each source that is not counting.
    """
    today = today or datetime.date.today()
    start = (today - datetime.timedelta(days=days - 1)).isoformat()

    # --- per-user, per-protocol, per-day ---
    cells = {}
    for username, proto, d, up, down in db.execute(
        "SELECT username, protocol, date, bytes_up, bytes_down FROM daily_traffic "
        "WHERE date >= ?", (start,)
    ):
        key = (username, proto)
        cells.setdefault(key, {})[d] = (up or 0) + (down or 0)

    # --- source health ---
    health = {}
    try:
        for proto, status, detail, last_ok, checked, peers in db.execute(
            "SELECT protocol, status, detail, last_ok_at, checked_at, peers_seen "
            "FROM collector_health"
        ):
            health[proto] = {
                "status": status,
                "detail": detail or "",
                "last_ok_at": last_ok,
                "checked_at": checked,
                "peers": peers,
            }
    except Exception:
        # Table absent means the collector predates it. Report every source as
        # unknown rather than silently treating it as healthy.
        health = {}

    calendar = date_range(days, today)

    # --- users ---
    # Traffic rows can outlive the account they belonged to (renames, a deleted
    # test account, the legacy `loadtest` row). Those are still real traffic, so
    # they are shown — but flagged, because a name with no account behind it
    # otherwise reads as a current user who merely moved no data.
    users = {}
    for (username,) in db.execute("SELECT username FROM users ORDER BY username"):
        users[username] = {"username": username, "protocols": {}, "orphan": False}

    for (username, proto) in list(cells):
        if username not in users:
            users[username] = {"username": username, "protocols": {}, "orphan": True}

    for username, u in users.items():
        total_all = 0
        for proto_key, proto_name in PROTOCOLS:
            byday = cells.get((username, proto_key), {})
            series = []
            for d in calendar:
                ds = d.isoformat()
                if ds in byday:
                    state = "data" if byday[ds] > 0 else "zero"
                    value = byday[ds]
                else:
                    # A day with no row is only "missing" if the source was not
                    # counting on that day. If it was, the absence means the user
                    # generated no traffic and the collector said so.
                    state = "missing"
                    value = 0
                series.append({"date": ds, "value": value, "state": state})
            total = sum(s["value"] for s in series)
            total_all += total
            u["protocols"][proto_key] = {
                "name": proto_name,
                "series": series,
                "today": next((s["value"] for s in series if s["date"] == today.isoformat()), 0),
                "d7": sum(s["value"] for s in series[-7:]),
                "d30": sum(s["value"] for s in series[-30:]),
                "total": total,
                "has_data": any(s["value"] > 0 for s in series),
            }
        u["today"] = sum(p["today"] for p in u["protocols"].values())
        u["d7"] = sum(p["d7"] for p in u["protocols"].values())
        u["d30"] = sum(p["d30"] for p in u["protocols"].values())
        u["total"] = total_all

    # --- which sources are not counting ---
    broken = []
    for proto_key, proto_name in PROTOCOLS:
        h = health.get(proto_key)
        if not h:
            broken.append({
                "protocol": proto_key, "name": proto_name,
                "status": "absent", "level": "bad",
                "label": STATUS_LABEL["absent"][1],
                "detail": "коллектор ни разу не отчитался об этом источнике",
                "last_ok_at": None,
            })
            continue
        level, label = STATUS_LABEL.get(h["status"], ("bad", h["status"]))
        if level == "bad":
            broken.append({
                "protocol": proto_key, "name": proto_name,
                "status": h["status"], "level": level, "label": label,
                "detail": h["detail"], "last_ok_at": h["last_ok_at"],
            })

    # --- day-level totals across everyone, for the chart ---
    daily_total = []
    for d in calendar:
        ds = d.isoformat()
        value = 0
        seen = False
        for (u, p), byday in cells.items():
            if ds in byday:
                seen = True
                value += byday[ds]
        daily_total.append({
            "date": ds,
            "value": value,
            "state": "data" if seen else "missing",
        })

    return {
        "calendar": [d.isoformat() for d in calendar],
        "users": list(users.values()),
        "health": health,
        "broken": broken,
        "daily_total": daily_total,
        "today": today.isoformat(),
        "days": days,
    }


def csv_rows(report):
    """Flatten the report for export. One row per user per protocol."""
    out = [["username", "protocol", "today", "last_7_days", "last_30_days", "window_total"]]
    for u in report["users"]:
        for key, _name in PROTOCOLS:
            p = u["protocols"].get(key)
            if not p:
                continue
            if p["today"] == 0 and p["d7"] == 0 and p["total"] == 0 and not p["has_data"]:
                # Keep protocols with no data: the absence is information.
                out.append([u["username"], key, 0, 0, 0, 0])
                continue
            out.append([u["username"], key, p["today"], p["d7"], p["d30"], p["total"]])
    return out