#!/usr/bin/env python3
import urllib.request
import json

# Test API on prod
users = ['test123', 'test99', 'webtest']
for user in users:
    for days_label, days in [('All(0)', 0), ('Today(4)', 4)]:
        url = f'http://127.0.0.1:5000/panel/api/v1/traffic/{user}?days={days}'
        try:
            req = urllib.request.Request(url)
            resp = urllib.request.urlopen(req, timeout=10)
            data = json.loads(resp.read())
            total = sum(r['bytes_up'] + r['bytes_down'] for r in data)
            print(f'  {user} {days_label}: {len(data)} rows, {total} bytes')
        except Exception as e:
            print(f'  {user} {days_label}: ERROR {e}')
    print()

# Test APK download
url = 'http://127.0.0.1:5000/panel/self/download/apk'
try:
    req = urllib.request.Request(url, method='HEAD')
    resp = urllib.request.urlopen(req, timeout=10)
    print(f'APK download: {resp.status}, Content-Type: {resp.headers.get("Content-Type")}')
except Exception as e:
    print(f'APK download: ERROR {e}')

# Test panel page
url = 'http://127.0.0.1:5000/panel/'
try:
    req = urllib.request.Request(url)
    resp = urllib.request.urlopen(req, timeout=10)
    print(f'Panel root: {resp.status}')
except Exception as e:
    print(f'Panel root: {e}')
