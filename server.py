#!/usr/bin/env python3
"""Captive portal prank server.

Serves the HTML page named by the "active_page" value in config.json.

Design notes:
- stdlib only (http.server) -- no Flask/pip install needed.
- config.json is re-read on EVERY request, so editing "active_page" (or
  dropping a new file into pages/) takes effect immediately, no restart.
- Every URL a client requests gets the joke page. That is deliberate:
  Android/iOS/Windows captive-portal detection probes URLs like
  /generate_204 or /hotspot-detect.html, and answering them with the joke
  page is what makes the phone pop the portal sheet up.
- Visits are counted in memory and injected into the page at the
  <!-- VISIT_COUNTER_PLACEHOLDER --> marker. Nothing is written to disk
  and no user input is ever logged or stored (there is no login form).
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
PAGES_DIR = os.path.join(BASE_DIR, "pages")

DEFAULT_ACTIVE_PAGE = "6g-joke.html"
DEFAULT_PORT = 8080

# The HTML pages contain this marker; we replace it with "You are visitor #N today".
COUNTER_MARKER = "<!-- VISIT_COUNTER_PLACEHOLDER -->"

PAGE_NOT_FOUND = (
    "<!DOCTYPE html><html><body><h1>404</h1>"
    "<p>No page configured. Put an HTML file in pages/ and set "
    "<code>active_page</code> in config.json.</p></body></html>"
)

_counter_lock = threading.Lock()
_visit_count = 0


def load_config():
    """Read config.json; fall back to defaults if missing or malformed."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        if not isinstance(cfg, dict):
            raise ValueError("config.json must contain a JSON object")
        return cfg
    except (OSError, ValueError) as exc:
        print(f"[server] warning: cannot read {CONFIG_PATH} ({exc}); using defaults",
              file=sys.stderr)
        return {"active_page": DEFAULT_ACTIVE_PAGE, "port": DEFAULT_PORT}


def active_page_path():
    """Absolute path of the page named by config.json (re-read per request)."""
    cfg = load_config()
    # basename() blocks path traversal: only plain file names are allowed.
    name = os.path.basename(str(cfg.get("active_page", DEFAULT_ACTIVE_PAGE)))
    return os.path.join(PAGES_DIR, name)


class CaptivePortalHandler(BaseHTTPRequestHandler):
    """Serves the active joke page for every request path."""

    server_version = "PrankPortal/1.0"

    # ---- request entry points -------------------------------------------
    def do_GET(self):
        self._handle()

    def do_POST(self):  # some portal probes POST; answer the same way
        self._handle()

    def do_HEAD(self):
        self._handle(send_body=False)

    # ---- core ------------------------------------------------------------
    def _handle(self, send_body=True):
        global _visit_count

        path = urlparse(self.path).path

        # Browsers always ask for a favicon; a 204 keeps the log clean.
        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        page_path = active_page_path()
        if not os.path.isfile(page_path):
            self._respond_html(404, PAGE_NOT_FOUND, send_body)
            self._log_line(f"GET {path} -> no page configured")
            return

        try:
            with open(page_path, "r", encoding="utf-8") as f:
                content = f.read()
        except OSError as exc:
            self._respond_html(500, f"<h1>500</h1><pre>{exc}</pre>", send_body)
            return

        # Inject the cosmetic visit counter where the page asks for it.
        with _counter_lock:
            _visit_count += 1
            count = _visit_count
        if COUNTER_MARKER in content:
            # Replace only the FIRST marker (the real element); pages may
            # also mention the marker inside explanatory comments.
            content = content.replace(COUNTER_MARKER,
                                      f"You are visitor #{count} today", 1)

        self._respond_html(200, content, send_body)
        self._log_line(f"GET {path} -> {os.path.basename(page_path)} "
                       f"(visitor #{count})")

    def _respond_html(self, code, body, send_body=True):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        # Stop Android/Chrome from caching the page between portal probes.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _log_line(self, msg):
        from datetime import datetime
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

    def log_message(self, format, *args):
        """Suppress the default per-request stderr logging (we log ourselves)."""
        pass


def main():
    cfg = load_config()
    port = cfg.get("port", DEFAULT_PORT)
    try:
        port = int(port)
    except (TypeError, ValueError):
        print(f"[server] warning: bad port {port!r} in config.json; "
              f"using {DEFAULT_PORT}", file=sys.stderr)
        port = DEFAULT_PORT

    httpd = ThreadingHTTPServer(("0.0.0.0", port), CaptivePortalHandler)

    print("=== Captive Portal Prank Server ===")
    print(f"Listening on  : 0.0.0.0:{port} (all interfaces)")
    print(f"Active page   : {os.path.basename(active_page_path())} "
          f"(re-read from config.json on every request)")
    print(f"Pages dir     : {PAGES_DIR}")
    print("Reminder      : this server only serves joke pages; "
          "it shares NO internet access.")
    print("===================================", flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[server] shutting down...")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
