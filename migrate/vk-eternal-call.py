#!/usr/bin/env python3
"""
VK Eternal Call — headless browser keeps VK call alive for WDTT hash renewal.

Usage:
  /opt/pw-venv/bin/python3 /opt/vk-eternal-call.py call https://vk.com/call/HASH
  /opt/pw-venv/bin/python3 /opt/vk-eternal-call.py stop
"""
import sys, os, asyncio, signal
from pathlib import Path
from playwright.async_api import async_playwright
from datetime import datetime

SESSION_DIR = Path("/opt/vk-session")
SESSION_FILE = SESSION_DIR / "state.json"
PID_FILE = Path("/opt/vk-call.pid")
LOG_FILE = Path("/opt/vk-call.log")
CHECK_INTERVAL = 60
RESTART_INTERVAL = 6 * 3600  # 6 hours

def log(msg):
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")

async def run_browser(call_url):
    log(f"Launching Chromium...")
    pw = await async_playwright().start()
    browser = await pw.chromium.launch(
        headless=True,
        args=["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"]
    )
    context = await browser.new_context(
        storage_state=str(SESSION_FILE),
        viewport={"width": 1280, "height": 720},
        user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36",
        permissions=["microphone", "camera"]
    )
    page = await context.new_page()
    return pw, browser, context, page

async def call_mode(call_url):
    if not SESSION_FILE.exists():
        log("ERROR: No session at " + str(SESSION_FILE))
        sys.exit(1)

    PID_FILE.write_text(str(os.getpid()))
    log(f"Starting call keeper: {call_url}")
    log(f"Restart interval: {RESTART_INTERVAL // 3600}h, check interval: {CHECK_INTERVAL}s")

    running = True
    def handle_stop(sig, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    restart_at = asyncio.get_event_loop().time() + RESTART_INTERVAL

    while running:
        pw, browser, context, page = await run_browser(call_url)
        try:
            attempt = 0
            while running:
                now = asyncio.get_event_loop().time()
                if now >= restart_at:
                    log("Scheduled restart — closing Chromium")
                    break

                try:
                    current = page.url
                    if call_url not in current:
                        log(f"Navigating to call (attempt {attempt})")
                        await page.goto(call_url, wait_until="networkidle", timeout=30000)
                        await asyncio.sleep(3)
                        title = await page.title()
                        log(f"Page title: {title}")

                        if "login" in page.url.lower() or "act.login" in page.url.lower():
                            log("ERROR: Session expired! Re-upload cookies.")
                            running = False
                            break

                    await context.storage_state(path=str(SESSION_FILE))
                    log(f"Call alive. Sleeping {CHECK_INTERVAL}s...")
                    attempt = 0
                except Exception as e:
                    attempt += 1
                    log(f"Error (attempt {attempt}): {e}")
                    if attempt > 5:
                        log("Too many errors, restarting browser")
                        break
                    await asyncio.sleep(10)
                    continue

                await asyncio.sleep(CHECK_INTERVAL)
        finally:
            try:
                await browser.close()
                await pw.stop()
            except:
                pass
            log("Chromium closed")
            restart_at = asyncio.get_event_loop().time() + RESTART_INTERVAL

    log("Stopping call keeper")
    PID_FILE.unlink(missing_ok=True)

def stop_mode():
    if PID_FILE.exists():
        pid = int(PID_FILE.read_text().strip())
        try:
            os.kill(pid, signal.SIGTERM)
            log(f"Sent SIGTERM to PID {pid}")
        except ProcessLookupError:
            log(f"PID {pid} not found")
        PID_FILE.unlink(missing_ok=True)
    else:
        log("No running call keeper found")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "call":
        if len(sys.argv) < 3:
            print("Usage: vk-eternal-call.py call <vk_call_url>")
            sys.exit(1)
        asyncio.run(call_mode(sys.argv[2]))
    elif cmd == "stop":
        stop_mode()
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)
