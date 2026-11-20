"""patch-webview.py INDEX_HTML: lets the webviews of VS Code for the Web (the preview of models) run from the origin of
the page, for a static host without a subdomain for each webview (GitHub Pages, tailscale serve).

VS Code checks that a webview runs on <hash of the origin of the page>.<host>, a host of its own; this adds: or on the
origin of the page itself. The script of index.html changes, so the hash of it in its Content-Security-Policy changes
too. The only webview of the site is the preview of ALVIE, whose script is that of the extension."""
import base64, hashlib, re, sys

path = sys.argv[1]
html = open(path, encoding="utf-8").read()
old = "if (hostname === parentOriginHash || hostname.startsWith(parentOriginHash + '.')) {"
new = "if (location.origin === parentOrigin || hostname === parentOriginHash || hostname.startsWith(parentOriginHash + '.')) {"
if new not in html:
    if html.count(old) != 1:
        sys.exit(f"{path}: the check of the host of webviews is not there (another version of VS Code?)")
    html = html.replace(old, new)
scripts = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", html, re.S)
if len(scripts) != 1:
    sys.exit(f"{path}: expected one inline script, found {len(scripts)}")
digest = base64.b64encode(hashlib.sha256(scripts[0].encode("utf-8")).digest()).decode()
html, n = re.subn(r"script-src 'sha256-[^']+'", f"script-src 'sha256-{digest}'", html, count=1)
if n != 1:
    sys.exit(f"{path}: no hash of a script in the Content-Security-Policy")
open(path, "w", encoding="utf-8").write(html)
print(f"{path}: webviews may run from the origin of the page")
