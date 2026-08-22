#!/usr/bin/env python3
import os, subprocess, hmac
from http.server import HTTPServer, BaseHTTPRequestHandler

SECRET = os.environ["WEBHOOK_SECRET"]
REPO   = os.environ["REPO_URL"]
PATH   = "/srv/repo"

subprocess.run(["git", "clone", "--depth=1", REPO, PATH], check=True)

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/pull":
            self.send_response(404); return
        body = self.rfile.read()
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if not hmac.compare_digest(token, SECRET):
            self.send_response(401); return
        subprocess.run(["git", "-C", PATH, "pull", "--ff-only"])
        self.send_response(200)
        self.wfile.write(b"pulled")
    def log_message(self, *a): pass

HTTPServer(("0.0.0.0", 8000), H).serve_forever()
