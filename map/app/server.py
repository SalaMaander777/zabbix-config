"""Карта устройств: HTTP-сервер на стандартной библиотеке (+ openpyxl для Excel)."""
import json
import mimetypes
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
from zoneinfo import ZoneInfo

from . import xlsx
from .zbx import ZabbixClient, ZabbixError, collect

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATIC = os.path.join(BASE, "static")
TILES = os.environ.get("MAP_TILES", "/data/moscow.pmtiles")
CACHE_TTL = 10.0


def _tz():
    try:
        return ZoneInfo(os.environ.get("TZ") or "Europe/Moscow")
    except Exception:
        return ZoneInfo("Europe/Moscow")


class Cache:
    """Снимок Zabbix на 10 секунд; при ошибке отдаём прошлый снимок с пометкой."""

    def __init__(self, client):
        self.client = client
        self.lock = threading.Lock()
        self.snap = None
        self.at = 0.0
        self.error = ""

    def get(self):
        with self.lock:
            now = time.time()
            if self.snap is None or now - self.at > CACHE_TTL:
                try:
                    self.snap = collect(self.client)
                    self.error = ""
                except ZabbixError as e:
                    self.error = e.message
                    print("zabbix error:", e.message, e.detail, flush=True)
                    if self.snap is None:
                        raise
                self.at = now
            return self.snap, self.error


def make_handler(cache, frontend_url):
    class H(BaseHTTPRequestHandler):
        server_version = "zabbix-map"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            if not self.path.startswith(("/healthz", "/tiles")):
                super().log_message(fmt, *args)

        def _send(self, code, body, ctype, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, code, obj):
            self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                       "application/json; charset=utf-8", {"Cache-Control": "no-store"})

        do_HEAD = lambda self: self.do_GET()

        def do_GET(self):
            path = unquote(urlsplit(self.path).path)
            if path == "/healthz":
                return self._send(200, b"ok\n", "text/plain")
            if path == "/api/hosts":
                return self.hosts()
            if path == "/export.xlsx":
                return self.export()
            if path == "/tiles.pmtiles":
                return self.tiles()
            if path == "/":
                path = "/index.html"
            if path.startswith("/static/"):
                path = path[len("/static"):]
            return self.static(path)

        def hosts(self):
            try:
                snap, err = cache.get()
            except ZabbixError as e:
                return self._json(502, {"error": e.message})
            out = dict(snap)
            out["stale_error"] = err
            out["frontend_url"] = frontend_url
            out["has_tiles"] = os.path.isfile(TILES)
            # Список проблем в карточке не нужен целиком - но оставляем: это данные Zabbix, не секреты.
            self._json(200, out)

        def export(self):
            try:
                snap, err = cache.get()
                body = xlsx.build_workbook(snap, _tz(), err)
            except ZabbixError as e:
                return self._json(502, {"error": e.message})
            name = "devices-%s.xlsx" % time.strftime("%Y%m%d-%H%M")
            self._send(200, body,
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                       {"Content-Disposition": 'attachment; filename="%s"' % name,
                        "Cache-Control": "no-store"})

        def static(self, rel):
            full = os.path.normpath(os.path.join(STATIC, rel.lstrip("/")))
            if not full.startswith(STATIC + os.sep) or not os.path.isfile(full):
                return self._send(404, b"not found\n", "text/plain")
            ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript",):
                ctype += "; charset=utf-8"
            with open(full, "rb") as f:
                self._send(200, f.read(), ctype)

        def tiles(self):
            if not os.path.isfile(TILES):
                return self._send(404, b"tiles not installed\n", "text/plain")
            size = os.path.getsize(TILES)
            start, end, code = 0, size - 1, 200
            m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", "").strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:
                    start = max(size - int(m.group(2)), 0)
                end = min(end, size - 1)
                if start > end or start >= size:
                    return self._send(416, b"", "text/plain", {"Content-Range": "bytes */%d" % size})
                code = 206
            length = end - start + 1
            self.send_response(code)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if code == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(TILES, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
    return H


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        import sys, traceback
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            traceback.print_exc()


def main():
    client = ZabbixClient(
        os.environ.get("ZBX_API_URL", "http://zabbix-web:8080/api_jsonrpc.php"),
        os.environ.get("ZBX_API_USER", "Admin"), os.environ.get("ZBX_API_PASSWORD", ""),
        os.environ.get("ZBX_API_TOKEN", ""), timeout=15)
    handler = make_handler(Cache(client), os.environ.get("ZBX_FRONTEND_URL", "").rstrip("/"))
    port = int(os.environ.get("MAP_LISTEN_PORT", "8081"))
    srv = Server(("0.0.0.0", port), handler)
    print("zabbix-map слушает порт", port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
