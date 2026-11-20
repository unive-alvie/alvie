#!/usr/bin/env python3
"""test.py DIST [OUT_DIR]: the self-test of the IDE in headless Chromium (or Firefox, ALVIE_SMOKE_BROWSER=firefox).

Serves DIST (npm run build) on localhost, opens index.html?selftest=1, waits for the result that the page posts (see
src/selftest.js), and takes a screenshot of the IDE after it. Writes OUT_DIR/result.json and OUT_DIR/ide.png.
Exit 0 if every check passed."""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading

dist = os.path.abspath(sys.argv[1]); out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else ".")
os.makedirs(out, exist_ok=True)
result, done, ready = {}, threading.Event(), threading.Event()

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=dist, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.split("?")[0] == "/hold":  # held until the IDE posts /ready (index.html?demo=1)
            ready.wait(60)
            self.send_response(200); self.send_header("Content-Type", "image/gif"); self.end_headers()
            self.wfile.write(bytes.fromhex("47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b"))
        else: super().do_GET()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(204); self.end_headers()
        if self.path == "/ready": ready.set()
        else: result.update(json.loads(body)); done.set()

Handler.extensions_map[".wasm"] = "application/wasm"
Handler.extensions_map[".js"] = "text/javascript"
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}/index.html"
browser = os.environ.get("ALVIE_SMOKE_BROWSER") or shutil.which("chromium") or shutil.which("chromium-browser")
firefox = "firefox" in os.path.basename(browser)

def run(url, extra, wait=None):
    profile = tempfile.mkdtemp(prefix="alvie-ide-browser-", dir=os.path.expanduser("~"))
    cmd = ([browser, "--headless", "--no-remote", "--profile", profile] if firefox
           else [browser, "--headless=new", "--disable-gpu", f"--user-data-dir={profile}", "--window-size=1440,900"]) + extra + [url]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if wait: ok = wait()
        else: proc.wait(timeout=180); ok = True
    finally:
        proc.terminate(); proc.wait(); shutil.rmtree(profile, ignore_errors=True)
    return ok

ok = run(base + "?selftest=1", [], wait=lambda: done.wait(900))
if not ok:
    print("no result from the IDE within 15 minutes"); sys.exit(1)
json.dump(result, open(os.path.join(out, "result.json"), "w"), indent=1)
print(result.get("userAgent"))
for c in result["checks"]:
    print(("PASS " if c["ok"] else "FAIL ") + c["name"])
print(f"{result['ms']} ms")
if not firefox:
        # The IDE with an example model (index.html?demo=1). Chromium of snap cannot write in /tmp: the home directory
    shot = os.path.join(os.path.expanduser("~"), "alvie-ide-shot.png")
    for demo, name in (("1", "ide.png"), ("vault", "ide-vaultlink.png")):
        ready.clear()
        run(base + f"?demo={demo}", [f"--screenshot={shot}", "--virtual-time-budget=20000"])
        if os.path.exists(shot): shutil.move(shot, os.path.join(out, name))
server.shutdown()
sys.exit(0 if all(c["ok"] for c in result["checks"]) else 1)
