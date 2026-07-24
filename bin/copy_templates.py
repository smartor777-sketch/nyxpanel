#!/usr/bin/env python3
"""Download templates from dev server to prod, preserving UTF-8."""
import urllib.request
import os

DEV = "http://2.26.51.8:5000"
TEMPLATES = ["self.html", "self_admin.html", "index.html"]
DEST = "/opt/proxy-panel/templates"

for t in TEMPLATES:
    url = f"{DEV}/panel/static/{t}"  # fallback
    # Use direct file copy via SSH-like method instead
    # Actually we'll read from /opt/proxy-panel/templates on dev via a simple route
    pass

# Alternative: just copy files using subprocess scp
import subprocess
for t in TEMPLATES:
    src = f"root@2.26.51.8:/opt/proxy-panel/templates/{t}"
    dst = f"{DEST}/{t}"
    print(f"Copying {t}...")
    result = subprocess.run(
        ["scp", "-o", "StrictHostKeyChecking=no", src, dst],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        print(f"  Error: {result.stderr}")
    else:
        print(f"  OK")

print("Done")
