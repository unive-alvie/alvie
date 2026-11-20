#!/usr/bin/env python3
"""serve.py SITE_DIR [PORT] [--bind ADDR]: serves the site of make-site.sh, compressed.

A first visit downloads about 40 MB, most of it JavaScript, which gzip makes about 9 MB. Python's http.server sends
files as they are; this server sends them with gzip when the browser accepts it (compressed once, then kept in memory),
and with caching headers: VS Code for the Web (vscode/) does not change for a site, so the browser keeps it for a day;
the rest is checked at each visit. Static hosts such as GitHub Pages compress on their own and do not need it."""
import argparse, gzip, http.server, os, threading

COMPRESSED = {".js", ".mjs", ".css", ".html", ".json", ".wasm", ".svg", ".txt", ".dot", ".atdl", ".etdl", ".spec",
              ".vtdl", ".alvienb", ".map", ".ttf"}


class Handler(http.server.SimpleHTTPRequestHandler):
    cache = {}  # path -> (mtime, gzipped bytes)
    lock = threading.Lock()

    def end_headers(self):
        if not getattr(self, "_cache_header_sent", False):
            self.send_header("Cache-Control", "public, max-age=86400" if self.path.startswith("/vscode/") else "no-cache")
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        if (os.path.isdir(path) or os.path.splitext(path)[1] not in COMPRESSED or "gzip" not in self.headers.get("Accept-Encoding", "")
                or not os.path.isfile(path) or os.path.getsize(path) < 1024):
            return super().send_head()
        mtime = os.path.getmtime(path)
        with self.lock:
            hit = self.cache.get(path)
        if not hit or hit[0] != mtime:
            with open(path, "rb") as f:
                hit = (mtime, gzip.compress(f.read(), 6))
            with self.lock:
                self.cache[path] = hit
        if self.headers.get("If-Modified-Since") == self.date_time_string(int(mtime)):
            self.send_response(304); self.end_headers(); return None
        self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(hit[1])))
        self.send_header("Last-Modified", self.date_time_string(int(mtime)))
        self.send_header("Vary", "Accept-Encoding")
        self.end_headers()
        import io
        return io.BytesIO(hit[1])

    def log_message(self, *args):
        pass


Handler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm",
                          ".mjs": "text/javascript", ".js": "text/javascript"}

if __name__ == "__main__":
    a = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    a.add_argument("site"); a.add_argument("port", nargs="?", type=int, default=8766); a.add_argument("--bind", default="127.0.0.1")
    args = a.parse_args()
    handler = lambda *h, **k: Handler(*h, directory=args.site, **k)
    print(f"Serving {args.site} on http://{args.bind}:{args.port}/ (gzip)")
    http.server.ThreadingHTTPServer((args.bind, args.port), handler).serve_forever()
