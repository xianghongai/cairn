#!/usr/bin/env python3
# 测试用的 Mock Gist 服务。GET /gists/<id> 返回 <根目录>/<id>.json 的内容；
# 缺少或错误的 Authorization 头返回 401，未知的 ID 返回 404。
#
# 用法：fake_gist.py <根目录> <端口> <token>
import http.server
import os
import sys

ROOT, PORT, TOKEN = sys.argv[1], int(sys.argv[2]), sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "gists" or not parts[1].isalnum():
            return self._send(404, b'{"message":"Not Found"}')
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self._send(401, b'{"message":"Bad credentials"}')
        path = os.path.join(ROOT, parts[1] + ".json")
        if not os.path.isfile(path):
            return self._send(404, b'{"message":"Not Found"}')
        with open(path, "rb") as f:
            return self._send(200, f.read())

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
