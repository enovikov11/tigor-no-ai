#!/usr/bin/env python3
"""
Data diode — minimal HTTP relay. Fetches artifacts from trusted sources
and streams them back as raw bytes. Zero dependencies (stdlib only).

GET /git?url=...          → git clone --depth=1 → tar.gz
GET /npm?name=...         → npm registry tarball
GET /pypi?name=...        → PyPI sdist
GET /docker?ref=...       → podman pull + save → tar
GET /url?source=...       → direct HTTPS relay
GET /tgproxy?server=&port=&secret= → MTProto JSON config
GET /                    → help
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import tarfile
import io
from urllib.parse import urlparse, parse_qs
from urllib.request import urlopen, Request
from urllib.error import URLError

PORT = int(os.getenv("PORT", "8080"))
MAX_BYTES = int(os.getenv("MAX_BYTES", "100_000_000"))
ALLOWED_URLS = os.getenv("ALLOWED_URLS",
    "https://github.com,"
    "https://gitlab.com,"
    "https://codeload.github.com,"
    "https://registry.npmjs.org,"
    "https://files.pythonhosted.org,"
    "https://pypi.org,"
    "https://cache.nixos.org,"
    "https://docker.io,"
    "https://registry-1.docker.io,"
    "https://ghcr.io,"
    "https://quay.io,"
).split(",")

def check_origin(source_url: str) -> None:
    """Gate: only allow fetches from whitelisted origins."""
    parsed = urlparse(source_url)
    origin = f"{parsed.scheme}://{parsed.netloc}"
    for allowed in ALLOWED_URLS:
        if origin.startswith(allowed.strip()):
            return
    raise ValueError(f"origin not allowed: {origin}")

def safe_fetch(url: str, timeout: int = 120) -> bytes:
    """Fetch a URL with size limit and origin check."""
    check_origin(url)
    req = Request(url, headers={"User-Agent": "data-diode/1.0"})
    with urlopen(req, timeout=timeout) as resp:
        data = resp.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError(f"response exceeds {MAX_BYTES} bytes")
    return data

def handle_git(params: dict) -> tuple:
    """Clone a repo and return it as tar.gz."""
    repo_url = params.get("url", [""])[0]
    if not repo_url:
        return 400, b"url parameter required\n"
    check_origin(repo_url)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["git", "clone", "--depth=1", "--filter=blob:none", repo_url, tmp],
            check=True, timeout=180,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            tar.add(tmp, arcname="repo")
        buf.seek(0)
    return 200, buf.read()

def handle_npm(params: dict) -> tuple:
    """Fetch an npm package tarball from the registry."""
    name = params.get("name", [""])[0]
    if not name or "/" in name:
        return 400, b"name parameter required (no scope slashes for safety)\n"
    # Get latest version from registry
    meta = safe_fetch(f"https://registry.npmjs.org/{name}")
    info = json.loads(meta)
    version = info.get("dist-tags", {}).get("latest", "")
    dist_url = info.get("versions", {}).get(version, {}).get("dist", {}).get("tarball", "")
    if not dist_url:
        return 502, f"no dist tarball found for {name}@{version}\n".encode()
    # Redirect to canonical npm tarball URL
    dist_url = f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz"
    body = safe_fetch(dist_url)
    return 200, body

def handle_pypi(params: dict) -> tuple:
    """Fetch a PyPI sdist tarball."""
    name = params.get("name", [""])[0]
    if not name:
        return 400, b"name parameter required\n"
    meta = safe_fetch(f"https://pypi.org/pypi/{name}/json")
    releases = json.loads(meta)
    # Prefer sdist, fall back to first file
    urls = [u for u in releases.get("urls", []) if u["packagetype"] == "sdist"]
    urls = urls or releases.get("urls", [{}])
    if not urls:
        return 502, f"no files for {name}\n".encode()
    return 200, safe_fetch(urls[0]["url"])

def handle_docker(params: dict) -> tuple:
    """Pull a container image and save it as a tar (podman load compatible)."""
    ref = params.get("ref", ["docker.io/library/alpine:latest"])[0]
    with tempfile.TemporaryDirectory() as tmp:
        out = f"{tmp}/image.tar"
        subprocess.run(["podman", "pull", "--quiet", ref],
                       check=True, timeout=300,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["podman", "save", "-o", out, ref],
                       check=True, timeout=120)
        with open(out, "rb") as f:
            return 200, f.read()

def handle_url(params: dict) -> tuple:
    """Generic relay: fetch any whitelisted URL and return raw bytes."""
    source = params.get("source", [""])[0]
    if not source:
        return 400, b"source parameter required\n"
    return 200, safe_fetch(source)

def handle_tgproxy(params: dict) -> tuple:
    """Generate a Telegram MTProto proxy config JSON."""
    server = params.get("server", [""])[0]
    port = int(params.get("port", ["443"])[0])
    secret = params.get("secret", [""])[0]
    if not server or not secret:
        return 400, b"server and secret parameters required\n"
    config = json.dumps({
        "type": "MTProto",
        "proxy": {
            "server": server,
            "port": port,
            "secret": secret,
        },
        "info": f"tg://proxy?server={server}&port={port}&secret={secret}",
    }, indent=2).encode()
    return 200, config

HANDLERS = {
    "git":       handle_git,
    "npm":       handle_npm,
    "pypi":      handle_pypi,
    "docker":    handle_docker,
    "url":       handle_url,
    "tgproxy":   handle_tgproxy,
}

HELP = """Data diode — one-way artifact relay.

Endpoints:
  /git?url=github_repo_url        Clone and return as tar.gz
  /npm?name=package               Download npm tarball
  /pypi?name=package              Download PyPI sdist
  /docker?ref=repo:tag            Pull image, return podman-loadable tar
  /url?source=https_url           Relay any whitelisted URL
  /tgproxy?server=&port=&secret=  Generate MTProto proxy config

Origin whitelist: GitHub, GitLab, npm, PyPI, Docker Hub, GHCR, Quay, NixOS.
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write(
            f"{self.client_address[0]} - [{self.log_date_time_string()}] "
            f"{args[0] if args else ''}\n"
        )

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.strip("/")

        if not path:
            code, body = 200, HELP.encode()
        elif path in HANDLERS:
            try:
                code, body = HANDLERS[path](parse_qs(parsed.query))
            except subprocess.CalledProcessError as e:
                return self.send_error(500, f"command failed: {e}")
            except ValueError as e:
                return self.send_error(403, str(e))
            except URLError as e:
                return self.send_error(502, f"fetch failed: {e.reason}")
            except Exception as e:
                return self.send_error(500, str(e))
        else:
            code, body = 404, f"unknown endpoint: /{path}\n".encode()

        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    srv = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"data-diode :{PORT}  —  handlers: {', '.join(HANDLERS)}", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
