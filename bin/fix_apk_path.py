#!/usr/bin/env python3
"""Update manual.html APK download route and EXE link on server."""
import re

filepath = '/opt/proxy-panel/app.py'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# Update APK path and download name
old = 'apk_path = "/opt/proxy-panel/static/olcbox-me-release.apk"'
new = 'apk_path = "/opt/proxy-panel/static/OlcboxME-1.0.2.apk"'
if old in content:
    content = content.replace(old, new)
    print('Fixed apk_path')

old = 'download_name="Olcbox-me-1.0.0-android.apk"'
new = 'download_name="OlcboxME-1.0.2.apk"'
if old in content:
    content = content.replace(old, new)
    print('Fixed download_name')

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
print('Done')
