#!/usr/bin/env python3
"""smoke.py WEB_DIR SIM_DIR SPEC_DIR [OUT.json [QUERY]]: runs alvie-web in a Web Worker of headless Chromium.

Serves web/browser with WEB_DIR (the output of web/build.sh), SIM_DIR (web/sim/build-sim.sh; bf89c0b is needed) and
SPEC_DIR (spec-lib/example) on localhost, opens smoke.html in headless Chromium, and waits for the result that the page
posts: what alvie-web printed and the model it learned. QUERY chooses the specs (files of SPEC_DIR) and the commit,
e.g. att=a.atdl&encl=enclave-complete.etdl&commit=bf89c0b. Exit 0 if it learned a model, 1 otherwise."""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading

web, sim, spec = (os.path.abspath(a) for a in sys.argv[1:4])
out = sys.argv[4] if len(sys.argv) > 4 else None
query = sys.argv[5] if len(sys.argv) > 5 else ""
here = os.path.dirname(os.path.abspath(__file__))
root = tempfile.mkdtemp(prefix="alvie-web-smoke-")
for f in ("smoke.html", "worker.js", "node-shim.js"):
    shutil.copy(os.path.join(here, f), root)
shutil.copy(os.path.join(web, "alvie-web.js"), root)
shutil.copytree(os.path.join(web, "alvie-web.assets"), os.path.join(root, "alvie-web.assets"))
shutil.copytree(sim, os.path.join(root, "sim"))
shutil.copytree(spec, os.path.join(root, "spec"))
result, done = {}, threading.Event()

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        result.update(json.loads(body)); self.send_response(204); self.end_headers(); done.set()

Handler.extensions_map[".wasm"] = "application/wasm"
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}/smoke.html" + (f"?{query}" if query else "")
# ALVIE_SMOKE_BROWSER=firefox for Firefox; Chromium by default. The profile is in the home directory: the browsers of
# snap cannot write in /tmp.
browser = os.environ.get("ALVIE_SMOKE_BROWSER") or shutil.which("chromium") or shutil.which("chromium-browser") or shutil.which("google-chrome")
profile = tempfile.mkdtemp(prefix="alvie-web-browser-", dir=os.path.expanduser("~"))
if "firefox" in os.path.basename(browser):
    command = [browser, "--headless", "--no-remote", "--profile", profile, url]
else:
    command = [browser, "--headless=new", "--disable-gpu", f"--user-data-dir={profile}", url]
proc = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
ok = done.wait(600)
proc.terminate(); proc.wait(); server.shutdown(); shutil.rmtree(profile, ignore_errors=True); shutil.rmtree(root)
if not ok:
    print("no result from the page within 10 minutes"); sys.exit(1)
print(result.get("userAgent", "")); print("\n".join(result.get("lines", [])))
print(f"{result.get('ms')} ms in the browser, exit {result.get('exit')}")
model = result.get("files", {}).get("/w/model.dot")
if out:
    json.dump(result, open(out, "w"))
print("model:", "learned" if model else "missing")
sys.exit(0 if model else 1)
