#!/usr/bin/env python3
import urllib.request
import json

# App has /panel prefix via ReverseProxied
for days in [4, 28, 120, 0]:
    url = f'http://127.0.0.1:5000/panel/api/v1/traffic/test123?days={days}'
    try:
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        print(f"days={days}: {len(data)} rows")
        for r in data[:3]:
            print(f"  {r}")
    except Exception as e:
        print(f"days={days}: ERROR {e}")
