#!/usr/bin/env python3
import urllib.request

url = 'http://127.0.0.1:5000/panel/self/download/apk'
req = urllib.request.Request(url, method='HEAD')
try:
    r = urllib.request.urlopen(req, timeout=10)
    print(f'Status: {r.status}')
    print(f'Content-Type: {r.headers.get("Content-Type")}')
    print(f'Content-Disposition: {r.headers.get("Content-Disposition")}')
    print(f'Content-Length: {r.headers.get("Content-Length")}')
except Exception as e:
    print(f'Error: {e}')
