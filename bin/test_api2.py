#!/usr/bin/env python3
import urllib.request
import json

# Check traffic for each user
users = ['test123', 'test99', 'webtest', 'test', '123', 'testpanel']
for user in users:
    for days_label, days in [('Today(4)', 4), ('Week(28)', 28), ('Month(120)', 120), ('All(0)', 0)]:
        url = f'http://127.0.0.1:5000/panel/api/v1/traffic/{user}?days={days}'
        try:
            req = urllib.request.Request(url)
            resp = urllib.request.urlopen(req, timeout=10)
            data = json.loads(resp.read())
            total = sum(r['bytes_up'] + r['bytes_down'] for r in data)
            dates = sorted(set(r['date'] for r in data))
            print(f"  {user} {days_label}: {len(data)} rows, {total} bytes, dates={dates}")
        except Exception as e:
            print(f"  {user} {days_label}: ERROR {e}")
    print()
