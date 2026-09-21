import http.server
import http.cookiejar
import urllib.request
import json

DOMAIN = "wdtt.kuban-forum.ru"

class AutoLoginHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            cj = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
            data = json.dumps({"username": "admin", "password": "wdtt"}).encode()
            req = urllib.request.Request(
                "http://127.0.0.1:2860/wdtt/login",
                data=data,
                headers={"Content-Type": "application/json"}
            )
            opener.open(req)
            self.send_response(302)
            self.send_header("Location", "/wdtt/")
            for c in cj:
                self.send_header("Set-Cookie", f"{c.name}={c.value}; Path=/wdtt/; Domain={DOMAIN}; HttpOnly")
            self.end_headers()
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, format, *args):
        pass

http.server.HTTPServer(("127.0.0.1", 2862), AutoLoginHandler).serve_forever()
