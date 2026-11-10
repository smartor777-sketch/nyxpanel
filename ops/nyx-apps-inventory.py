#!/usr/bin/env python3
"""nyx-apps-inventory — месячный инвентарь нативных приложений.

Слой, который не видит Docker: бинарники под systemd и python-venv.
Скрипт ничего не устанавливает и не перезапускает: собирает версии,
sha256 и даты, сравнивает с прошлым снимком и с последними GitHub-релизами,
пишет JSON в /var/lib/nyx-updates/apps.json и письмо.

Запуск: systemd-таймер nyx-apps-inventory.timer (1-й вторник 03:30 UTC).
Вручную:
  nyx-apps-inventory.py --dry-run    # отчёт в stdout, снимок не пишется
  nyx-apps-inventory.py --no-mail    # записать снимок без письма

Список приложений: /etc/nyx-updates/apps-inventory.tsv (см. ops/apps-inventory.tsv).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

CONF = "/etc/nyx-updates/apps-inventory.tsv"
STATE = "/var/lib/nyx-updates/apps.json"
LOG = "/var/log/nyx-updates/apps.log"
SENDMAIL = "/usr/sbin/sendmail"
TOKEN_FILE = "/etc/nyx-updates/github.token"
MAIL_TO = os.environ.get("MAIL_TO", "furi_wave@mail.ru")
USER_AGENT = "nyx-apps-inventory/1.0"

# первое «версиеподобное» число: 26.3.27, v2.11.4, 1.5.73
VER_RE = re.compile(r"(?<![0-9.])(\d+\.\d+(?:\.\d+)*)(?![0-9.])")


def log(message: str) -> None:
    line = f"{datetime.now(timezone.utc).strftime('%F %T UTC')} {message}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def run(cmd: str, timeout: int = 10) -> str:
    """Выполнить команду, вернуть stdout+stderr; ошибки и таймаут не бросают."""
    if not cmd.strip():
        return ""
    try:
        proc = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            errors="replace",
        )
        return (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.TimeoutExpired):
        return ""


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def extract_version(output: str) -> str:
    match = VER_RE.search(output)
    return match.group(1) if match else "unknown"


def norm_tag(tag: str | None) -> str:
    """Привести GitHub-тег к сравнимой версии.

    Возвращает "" если тег не версионный: `latest`, `1`, `v1`, `release-2026`.
    Понимает монорепо-префиксы: `app/v2.13.0` -> `2.13.0`.
    """
    if not tag:
        return ""
    value = tag.strip()
    if "/" in value:
        value = value.rsplit("/", 1)[-1]
    value = value.lstrip("vV")
    return value if VER_RE.fullmatch(value) else ""


def unit_state(unit: str) -> str:
    if not unit:
        return "-"
    proc = run(f"systemctl is-active {shlex.quote(unit)}", timeout=5)
    return proc.strip() or "unknown"


def unit_exists(unit: str) -> bool:
    if not unit:
        return False
    proc = subprocess.run(
        ["systemctl", "cat", unit],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return proc.returncode == 0


def venv_meta(path: str) -> str:
    """Версия venv-приложения: python + хэш набора зависимостей."""
    venv = os.path.dirname(os.path.dirname(path))
    python = os.path.join(venv, "bin", "python")
    pip = os.path.join(venv, "bin", "pip")
    pyver = extract_version(run(f"{shlex.quote(python)} --version"))
    freeze = run(f"{shlex.quote(pip)} list --format=freeze")
    packages = [line for line in freeze.splitlines() if line.strip()]
    deps = hashlib.sha256("\n".join(sorted(packages)).encode()).hexdigest()[:8]
    return f"py{pyver} deps={deps} n={len(packages)}"


def github_token() -> str:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        return token
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def github_tag(repo: str, token: str, cache: dict[str, str | None]) -> str | None:
    if not repo:
        return None
    if repo in cache:
        return cache[repo]
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    tag: str | None = None
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.load(response)
        tag = (payload.get("tag_name") or "").strip() or None
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        tag = None
    cache[repo] = tag
    return tag


def read_conf(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [part.strip() for part in line.split("|")]
            if len(parts) < 6:
                raise SystemExit(f"{path}:{lineno}: нужно 6 полей, получено {len(parts)}")
            rows.append(
                dict(zip(("name", "kind", "unit", "path", "check_cmd", "repo"), parts[:6]))
            )
    if not rows:
        raise SystemExit(f"{path}: пустой список приложений")
    return rows


def load_prev(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def send_mail(subject: str, body: str) -> bool:
    host = socket.gethostname()
    message = (
        f"To: {MAIL_TO}\n"
        f"From: root@{host}\n"
        f"Subject: {subject}\n"
        f"Date: {datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')}\n"
        "MIME-Version: 1.0\n"
        "Content-Type: text/plain; charset=UTF-8\n\n"
        f"{body}\n"
    )
    try:
        proc = subprocess.run(
            [SENDMAIL, "-oi", "-t"],
            input=message,
            text=True,
            capture_output=True,
            timeout=60,
        )
        if proc.returncode != 0:
            log(f"WARN: sendmail rc={proc.returncode}: {(proc.stderr or '').strip()[:200]}")
            return False
        return True
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN: sendmail failed: {exc}")
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Инвентарь нативных приложений")
    parser.add_argument("--conf", default=CONF)
    parser.add_argument("--state", default=STATE)
    parser.add_argument("--dry-run", action="store_true", help="отчёт в stdout, снимок не писать")
    parser.add_argument("--no-mail", action="store_true", help="не отправлять письмо")
    args = parser.parse_args()

    host = socket.gethostname()
    now = datetime.now(timezone.utc)
    log(f"=== start (dry_run={int(args.dry_run)}) ===")

    rows = read_conf(args.conf)
    token = github_token()
    cache: dict[str, str | None] = {}
    apps: dict[str, dict] = {}
    missing: list[str] = []
    not_applicable: list[str] = []

    for row in rows:
        name, kind, path = row["name"], row["kind"], row["path"]
        if not path or not os.path.exists(path):
            # нет файла и нет юнита — этого приложения на хосте просто не бывает
            if unit_exists(row["unit"]):
                missing.append(name)
            else:
                not_applicable.append(name)
            continue
        stat = os.stat(path)
        if kind == "venv":
            version = venv_meta(path)
        else:
            version = extract_version(run(row["check_cmd"]))
        tag = github_tag(row["repo"], token, cache)
        upstream = norm_tag(tag)
        tracked_version = version.split()[0] if kind == "venv" else version
        status = "?"
        if upstream and tracked_version != "unknown":
            status = "ok" if tracked_version == upstream else "update"
        apps[name] = {
            "kind": kind,
            "path": path,
            "unit": row["unit"],
            "state": unit_state(row["unit"]),
            "version": version,
            "sha256": sha256_file(path),
            "size": stat.st_size,
            "mtime": datetime.fromtimestamp(stat.st_mtime, timezone.utc).strftime("%F"),
            "repo": row["repo"],
            "upstream": upstream,
            "upstream_raw": tag or "",
            "status": status,
        }
        log(f"{name}: {version} (unit {apps[name]['state']}, upstream {tag or '-'}, {status})")

    prev = load_prev(args.state)
    prev_apps: dict = prev.get("apps", {})

    changes: list[str] = []
    for name in sorted(apps):
        cur, old = apps[name], prev_apps.get(name)
        if old is None:
            changes.append(f"новое: {name} {cur['version']}")
            continue
        if old.get("version") != cur["version"] or old.get("sha256") != cur["sha256"]:
            changes.append(
                f"{name}: {old.get('version', '?')} -> {cur['version']}"
                f" (sha {(old.get('sha256') or '????????')[:8]} -> {(cur['sha256'] or '????????')[:8]})"
            )
    removed = sorted(set(prev_apps) - set(apps))

    updates = [
        f"{name} {apps[name]['version']} -> {apps[name]['upstream']}"
        for name in sorted(apps)
        if apps[name]["status"] == "update"
    ]
    broken = [
        f"{name}: юнит {apps[name]['unit']} = {apps[name]['state']}"
        for name in sorted(apps)
        if apps[name]["state"] not in ("active", "-")
    ]
    uncomparable = [name for name in sorted(apps) if not apps[name]["upstream"]]

    width = max([len(name) for name in apps] + [3])
    lines = [
        "nyx: инвентарь приложений",
        f"Хост: {host}",
        f"Снимок: {now.strftime('%F %H:%M UTC')}",
        f"Приложений на хосте: {len(apps)}; нет файла: {len(missing)}; не применимо: {len(not_applicable)}",
        "",
        f"  {'app'.ljust(width)}  {'installed':<22} {'unit':<10} upstream",
    ]
    for name in sorted(apps):
        app = apps[name]
        if app["status"] == "update":
            upstream = f"{app['upstream']}  UPDATE"
        elif app["repo"] and app["upstream"]:
            upstream = f"{app['upstream']}  ok"
        elif app["repo"] and app["upstream_raw"]:
            upstream = f"tag {app['upstream_raw']} (не версия)"
        elif app["repo"]:
            upstream = "нет релизов"
        else:
            upstream = "—"
        lines.append(
            f"  {name.ljust(width)}  {app['version'][:22]:<22} {app['state']:<10} {upstream}"
        )

    lines += ["", f"Доступны обновления: {len(updates)}"]
    lines += [f"  - {item}" for item in updates] or ["  - нет"]

    lines += ["", f"Изменения с прошлого снимка: {len(changes) + len(removed)}"]
    if not prev_apps:
        lines += ["  - первый снимок, сравнивать не с чем"]
    else:
        lines += [f"  * {item}" for item in changes]
        lines += [f"  - пропал из списка: {name}" for name in removed]
        if not changes and not removed:
            lines += ["  - нет"]

    lines += ["", f"Внимание: {len(broken) + len(missing)}"]
    lines += [f"  ! {item}" for item in broken]
    lines += [f"  ! нет файла: {name}" for name in missing]
    if not (broken or missing):
        lines += ["  - нет"]
    if uncomparable:
        lines += [f"  ? без сравнения с upstream: {', '.join(uncomparable)}"]

    lines += [
        "",
        f"Состояние: {args.state}",
        "Ничего не обновлялось: это инвентарь, а не автообновление.",
    ]
    report = "\n".join(lines)

    if args.dry_run:
        print()
        print(report)
        log("dry-run: state and mail skipped")
        log("=== done ===")
        return 0

    snapshot = {
        "generated_at": now.strftime("%FT%TZ"),
        "host": host,
        "apps": apps,
    }
    os.makedirs(os.path.dirname(args.state), exist_ok=True)
    tmp = args.state + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, args.state)
    log(f"state written: {args.state}")

    if args.no_mail:
        log("mail skipped (--no-mail)")
    else:
        subject = f"nyx: apps inventory on {host}"
        if updates:
            subject += f" ({len(updates)} updates)"
        elif changes or broken:
            subject += " (changes)"
        else:
            subject += " (no changes)"
        if send_mail(subject, report):
            log(f"mail sent: {subject}")
        else:
            log("WARN: mail not sent")

    log(f"apps={len(apps)} updates={len(updates)} changes={len(changes)} broken={len(broken)}")
    log("=== done ===")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
