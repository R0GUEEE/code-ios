#!/usr/bin/env python3
"""Minimal VS Code web workbench host.

Serves the official `vscode-web` static build and fills in the workbench template
placeholders that VS Code's own server (or code-server) would normally fill.

Usage:
  server.py --root <dist> --port 8913 [--folder file:///path] [--gallery openvsx|none]
"""
import argparse
import http.server
import json
import mimetypes
import os
import socketserver
import sys
import urllib.parse

WORKBENCH = "out/vs/code/browser/workbench/workbench.html"

MIME = {
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".json": "application/json",
    ".html": "text/html",
    ".wasm": "application/wasm",
    ".svg": "image/svg+xml",
    ".ttf": "font/ttf",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".map": "application/json",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".webmanifest": "application/manifest+json",
}

GALLERY = {
    "openvsx": {
        "serviceUrl": "https://open-vsx.org/vscode/gallery",
        "itemUrl": "https://open-vsx.org/vscode/item",
        "resourceUrlTemplate": "https://open-vsx.org/vscode/asset/{publisher}/{name}/{version}/{path}",
        "controlUrl": "",
        "recommendationsUrl": "",
    }
}

PRODUCT = {
    "nameShort": "Code iOS",
    "nameLong": "Code for iOS",
    "applicationName": "code-ios",
    "dataFolderName": ".code-ios",
    "version": "1.91.1",
    "commit": "e170252f762678d22cb17edbaa5b7c6e77a1e0a6",
    "date": "2026-10-27T00:00:00.000Z",
    "quality": "stable",
    "serverLicense": "",
    "serverLicenseUrl": "",
    "extensionsGallery": {},
    "nlsBaseUrl": "",
    "extensionsEnabledWithApiProposalVersion": [],
    "linkProtectionTrustedDomains": ["https://open-vsx.org"],
}

ARGS = None


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ARGS.root, **kw)

    def log_message(self, fmt, *a):
        sys.stderr.write("  %s\n" % (fmt % a))

    # ---- helpers -------------------------------------------------------
    def _send(self, body: bytes, ctype: str, code: int = 200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if ARGS.coi:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Service-Worker-Allowed", "/")
        api = self.path.startswith("/_api/") or self.path.startswith("/product.json")
        if ctype.startswith("text/html") or api:
            self.send_header("Cache-Control", "no-store")
        else:
            self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def translate_path(self, path):
        # collapse '//' and strip query so the AMD loader's double slashes work
        path = urllib.parse.urlparse(path).path
        while "//" in path:
            path = path.replace("//", "/")
        return super().translate_path(path)

    # ---- routes --------------------------------------------------------
    def do_GET(self):
        raw = urllib.parse.urlparse(self.path).path
        norm = raw
        while "//" in norm:
            norm = norm.replace("//", "/")

        if norm == "/product.json":
            cfg = self.build_config()
            return self._send(json.dumps(cfg).encode(), "application/json")
        if norm in ("/", "/index.html", "/workbench"):
            return self.serve_workbench()
        if norm == "/healthz":
            return self._send(b"ok", "text/plain")
        if norm.startswith("/resources/server/"):
            self.path = "/" + norm[len("/resources/server/"):]
            return self.serve_static()
        if norm.startswith("/ext/"):
            sub = norm[len("/ext/"):]
            self.path = norm
            fs = os.path.realpath(os.path.join(ARGS.ext, sub))
            if not fs.startswith(os.path.realpath(ARGS.ext)):
                return self._send(b"403", "text/plain", 403)
            if os.path.isdir(fs):
                fs = os.path.join(fs, "index.html")
            if not os.path.isfile(fs):
                return self._send(b"404", "text/plain", 404)
            with open(fs, "rb") as f:
                body = f.read()
            ext = os.path.splitext(fs)[1].lower()
            ct = MIME.get(ext)
            if ct is None:
                ct = ("text/javascript" if ext == ".js"
                      else "application/json" if ext == ".json"
                      else "text/markdown" if ext in (".md", ".markdown")
                      else "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        # /static/<abs fs path>  -> used by the ios-fs bridge later
        if norm.startswith("/_api/fs/"):
            return self.api_fs(norm[len("/_api/fs/"):])
        if norm == "/_api/workspace":
            return self._json({"folder": ARGS.folder or None, "autoOpen": ARGS.auto_open,
                               "selftest": ARGS.selftest, "compact": True})
        self.path = norm
        return self.serve_static()

    def serve_static(self):
        fs = self.translate_path(self.path)
        if os.path.isdir(fs):
            fs = os.path.join(fs, "index.html")
        if not os.path.isfile(fs):
            return self._send(b"404", "text/plain", 404)
        ext = os.path.splitext(fs)[1].lower()
        with open(fs, "rb") as f:
            body = f.read()
        self._send(body, MIME.get(ext, "application/octet-stream"))

    def build_config(self):
        """The object workbench.js hands to create() — also served as /product.json."""
        product = dict(PRODUCT)
        if ARGS.gallery != "none":
            product["extensionsGallery"] = GALLERY[ARGS.gallery]

        cfg = dict(product)  # this build reads the flat object, not {productConfiguration}
        cfg["productConfiguration"] = product
        cfg["folderUri"] = ({"scheme": "iosfs", "authority": "local", "path": ARGS.folder}
                            if ARGS.folder else None)
        cfg["workspaceUri"] = None
        cfg["configurationDefaults"] = {
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.activityBar.location": "top",
            "workbench.layoutControl.enabled": False,
            "breadcrumbs.enabled": False,
            "explorer.compactFolders": False,
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "workbench.editor.tabSizing": "shrink",
            "workbench.startupEditor": "none",
            "workbench.tips.enabled": False,
            "workbench.tree.indent": 10,
            "editor.fontSize": 12,
            "editor.minimap.enabled": False,
            "editor.scrollbar.vertical": "hidden",
        }
        exts = list(ARGS.builtin_ext)
        if not exts and os.path.isdir(ARGS.ext):
            for name in sorted(os.listdir(ARGS.ext)):
                if os.path.isfile(os.path.join(ARGS.ext, name, "package.json")):
                    exts.append(name)
        cfg["additionalBuiltinExtensions"] = [
            {"scheme": "http", "authority": "127.0.0.1:%d" % ARGS.port,
             "path": e if e.startswith("/") else "/ext/" + e}
            for e in exts
        ]
        return cfg

    def serve_workbench(self):
        fs = os.path.join(ARGS.root, WORKBENCH)
        with open(fs, "r", encoding="utf-8") as f:
            html = f.read()
        config = self.build_config()

        repl = {
            "{{WORKBENCH_WEB_BASE_URL}}": "",
            "{{WORKBENCH_WEB_CONFIGURATION}}": json.dumps(config).replace('"', "&quot;"),
            "{{WORKBENCH_AUTH_SESSION}}": "{}",
            "{{WORKBENCH_BUILTIN_EXTENSIONS}}": "[]",
            "{{WORKBENCH_NLS_BASE_URL}}": "",
            "{{NLS_BASE_URL}}": "",
        }
        for k, v in repl.items():
            html = html.replace(k, v)
        html = html.replace("width=device-width, initial-scale=1.0",
                            "width=device-width, initial-scale=1.0, viewport-fit=cover")
        phone = """<style id="codeios-phone">
.monaco-workbench .part.statusbar { padding-bottom: env(safe-area-inset-bottom, 0px); font-size: 10px; }
@media (max-width: 640px) {
  /* single-window app: navigation history arrows are dead weight */
  .monaco-workbench .part.titlebar .titlebar-left { display: none !important; }
  /* the settings editor's own navigation pane forces a 500px split view;
     on a phone the content should have the whole width instead */
  .monaco-workbench .settings-editor .settings-editor-tree { display: none !important; }

  .monaco-workbench .titlebar-center .action-item:has(.codicon-arrow-left),
  .monaco-workbench .titlebar-center .action-item:has(.codicon-arrow-right) { display: none !important; }
  /* host keyboard layout, meaningless on iOS */
  #status\\.workbench\\.keyboardLayout { display: none !important; }
}
</style>"""
        html = html.replace("</head>", phone + "</head>")
        self._send(html.encode(), "text/html; charset=utf-8")

    # ---- filesystem bridge ---------------------------------------------
    def _allowed(self, target):
        t = os.path.realpath(target)
        for r in ARGS.allow:
            rr = os.path.realpath(r)
            if t == rr or t.startswith(rr + os.sep):
                return t
        raise PermissionError("path outside allowed roots: %s" % target)

    def _q(self):
        q = urllib.parse.urlparse(self.path)
        return {k: v[0] for k, v in urllib.parse.parse_qs(q.query).items()}

    def _json(self, obj, code=200):
        self._send(json.dumps(obj).encode(), "application/json", code)

    def api_fs(self, op):
        p = self._q()
        try:
            if op == "stat":
                st = os.stat(self._allowed(p["path"]))
                return self._json({
                    "type": 2 if os.path.isdir(p["path"]) else 1,
                    "size": st.st_size,
                    "mtime": int(st.st_mtime * 1000),
                })
            if op == "list":
                d = self._allowed(p["path"])
                out = []
                with os.scandir(d) as it:
                    for e in it:
                        try:
                            st = e.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        out.append({"name": e.name, "dir": e.is_dir(), "size": st.st_size,
                                    "mtime": int(st.st_mtime * 1000)})
                return self._json(out)
            if op == "read":
                with open(self._allowed(p["path"]), "rb") as f:
                    return self._send(f.read(), "application/octet-stream")
            if op == "write":
                data = self._body()
                target = self._allowed(p["path"])
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as f:
                    f.write(data)
                return self._json({"ok": True, "bytes": len(data)})
            if op == "mkdir":
                os.makedirs(self._allowed(p["path"]), exist_ok=True)
                return self._json({"ok": True})
            if op == "delete":
                target = self._allowed(p["path"])
                if os.path.isdir(target):
                    import shutil as _sh
                    _sh.rmtree(target)
                elif os.path.exists(target):
                    os.remove(target)
                return self._json({"ok": True})
            if op == "rename":
                src = self._allowed(p["from"])
                dst = self._allowed(p["to"])
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.replace(src, dst)
                return self._json({"ok": True})
        except PermissionError as e:
            return self._json({"error": str(e)}, 403)
        except FileNotFoundError as e:
            return self._json({"error": "%s: %s" % (type(e).__name__, e)}, 404)
        except (OSError, KeyError) as e:
            return self._json({"error": "%s: %s" % (type(e).__name__, e)}, 400)
        return self._json({"error": "unknown op"}, 404)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_PUT(self):
        norm = urllib.parse.urlparse(self.path).path
        if norm.startswith("/_api/fs/"):
            return self.api_fs(norm[len("/_api/fs/"):])
        return self._send(b"404", "text/plain", 404)

    def do_POST(self):
        norm = urllib.parse.urlparse(self.path).path
        if norm.startswith("/_api/fs/"):
            return self.api_fs(norm[len("/_api/fs/"):])
        if norm == "/_api/log":
            data = self._body()
            try:
                with open("/tmp/ext.log", "ab") as f:
                    f.write(data + b"\n")
            except OSError:
                pass
            return self._json({"ok": True})
        return self._send(b"404", "text/plain", 404)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=8913)
    ap.add_argument("--folder", default="")
    ap.add_argument("--allow", action="append", default=[])
    ap.add_argument("--gallery", default="openvsx", choices=["openvsx", "none"])
    ap.add_argument("--ext", default="extensions", help="extension store directory")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--auto-open", action="store_true", help="let ios-fs open the folder itself")
    ap.add_argument("--no-coi", dest="coi", action="store_false", default=True)
    ap.add_argument("--builtin-ext", action="append", default=[],
                    help="path (relative to web root) of a builtin extension to preload")
    ARGS = ap.parse_args()
    if not ARGS.allow:
        ARGS.allow = [os.getcwd()]
    srv = Server(("127.0.0.1", ARGS.port), Handler)
    print("workbench on http://127.0.0.1:%d/  root=%s" % (ARGS.port, ARGS.root), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
