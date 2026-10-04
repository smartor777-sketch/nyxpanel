#!/usr/bin/env python3
"""Offline tests for the panel — no network, no daemons, no real secrets.

Run: python3 panel/proxy-panel/tests/test_panel.py

Covers the failures found in the 2026-10-04 audit:
  C1  /self/api/v1/* must not answer without a session, and the subscription
      endpoint must not hand out a config without an opaque token.
  C3  toggle/revoke/expiry must reach the orchestrator, not just SQLite.
  H2  the tproxy secret must not be rendered into the page or returned by /info.
  H6  migrations apply once and are recorded.
"""
import base64
import datetime
import importlib
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PANEL_DIR = HERE.parent

_MANAGER_STUB = """#!/bin/bash
echo "CALL $*" >> "{log}"
case "$1" in
  revoke_user)  echo "REVOKED user=$2 ok=[awg vless:api] failed=[]" ;;
  restore_user) echo "RESTORED user=$2 ok=[awg vless:api] failed=[]" ;;
  expire_check) echo "expire_check: revoked=0" ;;
esac
exit 0
"""


class PanelTestBase(unittest.TestCase):
    """Shared fixture: a throwaway state dir, a stubbed orchestrator, 3 users."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls._tmp.name)

        os.environ["PANEL_SECRET"] = "test-secret-not-a-real-value"
        os.environ["NYX_BASE_DIR"] = str(tmp / "users")
        os.environ["NYX_DB_PATH"] = str(tmp / "panel.db")
        os.environ["NYX_MANAGER"] = str(tmp / "fake_manager.sh")
        os.environ["NYX_PORT"] = "5001"
        os.environ["NYX_ENV"] = str(tmp / "no-such.env")

        mgr = tmp / "fake_manager.sh"
        mgr.write_text(_MANAGER_STUB.format(log=tmp / "calls.log"))
        mgr.chmod(0o755)

        sys.path.insert(0, str(PANEL_DIR))
        import app as panel
        # Reload rather than plain import: module-level code reads BASE_DIR and
        # DB_PATH from the environment, and each class gets a fresh temp dir.
        # A cached import would leave the next class holding a deleted path.
        cls.panel = importlib.reload(panel)
        panel.app.config["TESTING"] = True
        panel.app.secret_key = "test-secret-not-a-real-value"
        cls.client = panel.app.test_client()

        panel.init_db()
        db = sqlite3.connect(panel.DB_PATH)
        for u, role in (("alice", "user"), ("bob", "user"), ("root", "admin")):
            db.execute(
                "INSERT INTO users (username, password_hash, role, active) "
                "VALUES (?,?,?,1)",
                (u, panel.generate_password_hash("pw-" + u), role),
            )
        db.commit()
        db.close()

        # Give the non-admin users a config, so the subscription endpoint has
        # something real to leak if the token gate is broken.
        for u in ("alice", "bob"):
            d = Path(panel.BASE_DIR) / u
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{u}_awg.conf").write_text(
                "[Interface]\nPrivateKey = PRIVATEKEYOF%s\nAddress = 10.9.9.5/32\n"
                % u.upper()
            )
            (d / f"{u}_hy2.json").write_text(
                '{"outbounds":[{"password":"PASSWORDFOR%s","server":"x","server_port":1,'
                '"obfs":{"type":"salamander","password":"OBFSPASS"}}]}' % u.upper()
            )
            (d / ".awg_pubkey").write_text("PUBKEYOF%s=" % u.upper())

    @classmethod
    def tearDownClass(cls):
        cls.panel.app.config.pop("TESTING", None)
        if str(PANEL_DIR) in sys.path:
            sys.path.remove(str(PANEL_DIR))
        cls._tmp.cleanup()

    def setUp(self):
        # The test client is shared across methods in a class, and its signed
        # session cookie survives between them. Without this, an admin login in
        # one test silently satisfies the "no session" checks in the next.
        self.client = self.panel.app.test_client()

    # -- helpers --

    def login(self, user, pw):
        return self.client.post(
            "/self/login",
            data={"username": user, "password": pw},
            follow_redirects=False,
        )

    def db(self):
        return sqlite3.connect(self.panel.DB_PATH)

    def set_raw_token(self, username):
        """Only the hash is stored, so install a token the test knows."""
        tok = self.panel.pysecrets.token_urlsafe(32)
        db = self.db()
        db.execute(
            "UPDATE sub_tokens SET token_hash=?, revoked_at=NULL, expires_at=NULL "
            "WHERE username=?",
            (self.panel.hash_sub_token(tok), username),
        )
        db.commit()
        db.close()
        return tok

    def call_log(self):
        return (Path(self.panel.MANAGER).parent / "calls.log").read_text()

    def issue_token(self, username):
        self.login("root", "pw-root")
        self.client.post(f"/self/user/{username}/sub-token")
        db = self.db()
        db.execute(
            "INSERT OR IGNORE INTO sub_tokens (username, token_hash, created_at) "
            "VALUES (?,?,datetime('now'))",
            (username, "placeholder-" + username),
        )
        db.commit()
        db.close()
        return self.set_raw_token(username)


class TestC1ExposureClosed(PanelTestBase):
    """C1 — these endpoints answered 200 from the public internet, unauthenticated."""

    GUARDED = [
        "/self/api/v1/users",
        "/self/api/v1/traffic/totals",
        "/self/api/v1/traffic",
        "/self/api/v1/traffic/alice",
    ]

    def test_stats_require_a_session(self):
        for route in self.GUARDED:
            with self.subTest(route=route):
                r = self.client.get(route)
                self.assertIn(r.status_code, (401, 302),
                              f"{route} answered {r.status_code} with no session")
                self.assertNotIn(b"alice", r.data,
                                 f"{route} leaked a username to an anonymous caller")

    def test_stats_require_admin_not_merely_login(self):
        self.login("alice", "pw-alice")
        for route in self.GUARDED:
            with self.subTest(route=route):
                r = self.client.get(route)
                self.assertIn(r.status_code, (401, 403),
                              f"{route} answered {r.status_code} for a non-admin")

    def test_admin_can_still_read_stats(self):
        self.login("root", "pw-root")
        r = self.client.get("/self/api/v1/users")
        self.assertEqual(r.status_code, 200)
        self.assertIn("alice", r.get_data(as_text=True))

    def test_legacy_sub_route_refuses_a_bare_username(self):
        """The old path was /self/api/v1/sub/<username> with no check at all."""
        r = self.client.get("/self/api/v1/sub/alice")
        self.assertEqual(r.status_code, 404,
                         "subscription still answers for a bare username")
        self.assertNotIn(b"PRIVATEKEYOFALICE", r.data)

    def test_token_serves_only_that_user(self):
        tok = self.issue_token("alice")
        r = self.client.get(f"/sub/{tok}")
        self.assertEqual(r.status_code, 200)
        body = base64.b64decode(r.get_data()).decode()
        self.assertIn("PASSWORDFORALICE", body)
        self.assertNotIn("PASSWORDFORBOB", body,
                         "alice's token returned bob's config")

    def test_garbage_token_is_404(self):
        self.assertEqual(self.client.get("/sub/" + "x" * 43).status_code, 404)

    def test_rotation_kills_the_previous_token(self):
        self.issue_token("bob")
        old = self.set_raw_token("bob")
        self.assertEqual(self.client.get(f"/sub/{old}").status_code, 200)

        self.login("root", "pw-root")
        self.client.post("/self/user/bob/sub-token/rotate")
        self.assertEqual(self.client.get(f"/sub/{old}").status_code, 404,
                         "the old token still works after rotation")

        new = self.set_raw_token("bob")
        self.assertEqual(self.client.get(f"/sub/{new}").status_code, 200)

    def test_revoke_darkens_subscription_and_restore_brings_it_back(self):
        tok = self.issue_token("alice")
        self.assertEqual(self.client.get(f"/sub/{tok}").status_code, 200)

        self.login("root", "pw-root")
        self.client.post("/self/user/alice/revoke")
        r = self.client.get(f"/sub/{tok}")
        self.assertEqual(r.status_code, 410)
        self.assertNotIn(b"PASSWORDFORALICE", r.data)

        self.client.post("/self/user/alice/restore")
        self.assertEqual(self.client.get(f"/sub/{tok}").status_code, 200,
                         "restore did not bring the subscription back")

    def test_disabling_a_token_does_not_revoke_access(self):
        """Disable URL kills the link only; connected clients keep running."""
        tok = self.issue_token("bob")
        self.login("root", "pw-root")
        self.client.post("/self/user/bob/sub-token/revoke")
        self.assertEqual(self.client.get(f"/sub/{tok}").status_code, 404)
        db = self.db()
        self.assertIsNone(
            db.execute("SELECT revoked_at FROM users WHERE username='bob'").fetchone()[0]
        )
        db.close()


class TestC3RealRevocation(PanelTestBase):
    """C3 — toggle used to flip `active` in SQLite and change nothing else."""

    def setUp(self):
        super().setUp()
        db = self.db()
        db.execute("DELETE FROM revocation_state")
        db.execute("DELETE FROM audit_log")
        db.execute("UPDATE users SET revoked_at=NULL, revoked_reason='', active=1")
        db.commit()
        db.close()
        self.client.get("/self/logout")

    def test_revoke_reaches_the_orchestrator(self):
        self.login("root", "pw-root")
        self.client.post("/self/user/alice/revoke", data={"reason": "test"})
        self.assertIn("revoke_user", self.call_log(),
                      "revoke never reached the orchestrator")

    def test_revoke_sets_state_and_records_confirmation(self):
        self.login("root", "pw-root")
        self.client.post("/self/user/alice/revoke", data={"reason": "test"})
        db = self.db()
        row = db.execute(
            "SELECT revoked_at, active, revoked_reason FROM users WHERE username='alice'"
        ).fetchone()
        self.assertTrue(row[0], "revoked_at was not set")
        self.assertEqual(row[1], 0)
        self.assertEqual(row[2], "test")
        states = db.execute(
            "SELECT protocol FROM revocation_state WHERE username='alice' AND confirmed_at IS NOT NULL"
        ).fetchall()
        self.assertTrue(states, "no per-protocol confirmation recorded")
        db.close()

    def test_toggle_off_and_on_both_reach_the_orchestrator(self):
        self.login("root", "pw-root")
        self.client.post("/self/user/alice/toggle")
        db = self.db()
        self.assertIsNotNone(
            db.execute("SELECT revoked_at FROM users WHERE username='alice'").fetchone()[0]
        )
        db.close()

        self.client.post("/self/user/alice/toggle")
        db = self.db()
        self.assertIsNone(
            db.execute("SELECT revoked_at FROM users WHERE username='alice'").fetchone()[0]
        )
        db.close()
        log = self.call_log()
        self.assertIn("revoke_user", log)
        self.assertIn("restore_user", log)

    def test_revoked_user_cannot_log_in(self):
        self.login("root", "pw-root")
        self.client.post("/self/user/alice/revoke")
        self.client.get("/self/logout")
        self.login("alice", "pw-alice")
        r = self.client.get("/self/")
        self.assertIn(r.status_code, (302, 401),
                      "a revoked user still reached the dashboard")

    def test_expiry_revokes_rather_than_only_clearing_a_flag(self):
        """Expiry used to write active=0, so 'expires' was decorative."""
        db = self.db()
        past = (datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(days=1)).isoformat()
        db.execute("UPDATE users SET expires_at=? WHERE username='bob'", (past,))
        db.commit()
        db.close()

        os.environ["CRON_SECRET"] = "cron-secret-for-tests"
        self.panel._require_env = lambda name, why: os.environ.get(name, "")

        r = self.client.post("/self/cron/expire",
                             headers={"X-Cron-Secret": "wrong"})
        self.assertEqual(r.status_code, 403, "expire endpoint accepted a bad secret")

        r = self.client.post("/self/cron/expire",
                             headers={"X-Cron-Secret": "cron-secret-for-tests"})
        self.assertEqual(r.status_code, 200)
        db = self.db()
        self.assertIsNotNone(
            db.execute("SELECT revoked_at FROM users WHERE username='bob'").fetchone()[0],
            "expiry did not revoke access",
        )
        db.close()

    def test_audit_log_records_the_change(self):
        self.login("root", "pw-root")
        self.client.post("/self/user/alice/revoke", data={"reason": "audit-check"})
        db = self.db()
        rows = db.execute(
            "SELECT action, target FROM audit_log WHERE target='alice'"
        ).fetchall()
        db.close()
        self.assertTrue(any(a == "revoke" for a, _ in rows),
                        f"no audit row for the revoke: {rows}")


class TestH2SecretNotLeaked(PanelTestBase):
    def test_info_returns_masked_and_flags_reveal(self):
        secret = "0123456789abcdef0123456789abcdef"
        tp = Path("/etc/tproxy-server/profiles.json")
        try:
            tp.parent.mkdir(parents=True, exist_ok=True)
            tp.write_text(
                '{"profiles":[{"name":"p1","secret":"%s","backend":"127.0.0.1:2398"}]}'
                % secret
            )
            self.login("root", "pw-root")
            r = self.client.get("/self/tproxy/p1/info")
            self.assertEqual(r.status_code, 200)
            self.assertNotIn(secret.encode(), r.data, "/info returned the full secret")
            j = r.get_json()
            self.assertTrue(j.get("reveal_required"))
            self.assertIn("…", j.get("key_masked", ""))
            self.assertNotIn("key", j)
        finally:
            if tp.exists():
                tp.unlink()

    def test_reveal_is_explicit_post_and_audited(self):
        secret = "0123456789abcdef0123456789abcdef"
        tp = Path("/etc/tproxy-server/profiles.json")
        try:
            tp.parent.mkdir(parents=True, exist_ok=True)
            tp.write_text(
                '{"profiles":[{"name":"p1","secret":"%s","backend":"127.0.0.1:2398"}]}'
                % secret
            )
            self.login("root", "pw-root")

            self.assertEqual(self.client.get("/self/tproxy/p1/reveal").status_code, 405,
                             "reveal answered a GET")

            db = self.db()
            before = db.execute("SELECT count(*) FROM audit_log").fetchone()[0]
            db.close()

            r = self.client.post("/self/tproxy/p1/reveal")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.get_json()["key"], secret)

            db = self.db()
            after = db.execute("SELECT count(*) FROM audit_log").fetchone()[0]
            row = db.execute(
                "SELECT action FROM audit_log WHERE action='tproxy_secret_reveal'"
            ).fetchone()
            db.close()
            self.assertGreater(after, before, "revealing a secret wrote no audit row")
            self.assertIsNotNone(row)
        finally:
            if tp.exists():
                tp.unlink()

    def test_reveal_requires_admin(self):
        secret = "0123456789abcdef0123456789abcdef"
        tp = Path("/etc/tproxy-server/profiles.json")
        try:
            tp.parent.mkdir(parents=True, exist_ok=True)
            tp.write_text(
                '{"profiles":[{"name":"p1","secret":"%s","backend":"127.0.0.1:2398"}]}'
                % secret
            )
            self.login("alice", "pw-alice")
            r = self.client.post("/self/tproxy/p1/reveal")
            self.assertNotIn(secret.encode(), r.data,
                             "a non-admin obtained the secret")
        finally:
            if tp.exists():
                tp.unlink()

    def test_template_never_inlines_the_secret(self):
        tpl = (PANEL_DIR / "templates" / "tproxy_profiles.html").read_text()
        self.assertNotIn("{{ p.secret }}", tpl,
                         "the raw secret is still rendered into the page")
        self.assertNotIn("copyKey('{{ p.secret }}')", tpl)
        self.assertIn("revealKey(", tpl, "the reveal helper is missing")


class TestH6Migrations(PanelTestBase):
    def test_migrations_applied_once_each(self):
        db = self.db()
        versions = [r[0] for r in
                    db.execute("SELECT version FROM schema_migrations ORDER BY version")]
        db.close()
        self.assertEqual(versions, sorted(set(versions)), "a migration ran twice")
        self.assertEqual(max(versions), self.panel.SCHEMA_VERSION)
        self.assertIn(2, versions, "revoked_at migration missing")
        self.assertIn(3, versions, "sub_tokens migration missing")

    def test_init_db_is_idempotent(self):
        self.panel.init_db()
        self.panel.init_db()
        db = self.db()
        n = db.execute("SELECT count(*) FROM schema_migrations").fetchone()[0]
        db.close()
        self.assertEqual(n, self.panel.SCHEMA_VERSION)

    def test_schema_has_the_tables_the_code_uses(self):
        db = self.db()
        names = {r[0] for r in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        db.close()
        for t in ("users", "sub_tokens", "revocation_state", "audit_log",
                  "schema_migrations", "daily_traffic", "traffic_log"):
            self.assertIn(t, names)


if __name__ == "__main__":
    unittest.main(verbosity=2)
