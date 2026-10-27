#!/usr/bin/env python3
"""Registry-side extension installer (the path the app should own).

Resolves an extension on Open VSX, downloads the VSIX, enforces integrity and
policy, unpacks it into ./extensions/<publisher>.<name>-<version>, and prints the
path to register as a builtin extension.

Deliberately does NOT run npm, does NOT execute postinstall, and refuses
VSIX members that escape the target directory.

Usage:
  install_ext.py esbenp.prettier-vscode [--version 12.4.0] [--root extensions]
                 [--require-web] [--pin sha256]
"""
import argparse
import hashlib
import io
import json
import os
import shutil
import sys
import urllib.request
import zipfile

API = "https://open-vsx.org/api"


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "code-ios-installer/0.1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_extract(zf, dest):
    """Extract 'extension/*' with zip-slip and symlink protection."""
    prefix = None
    names = zf.namelist()
    if any(n.startswith("extension/") for n in names):
        prefix = "extension/"
    count = 0
    for info in zf.infolist():
        name = info.filename
        if prefix:
            if not name.startswith(prefix):
                continue
            name = name[len(prefix):]
        if not name or name.endswith("/"):
            continue
        if name.startswith("__MACOSX/"):
            continue
        # symlink / special file protection (unix mode in high bits)
        mode = (info.external_attr >> 16) & 0xF000
        if mode == 0xA000:
            raise SystemExit("refusing symlink member: %s" % name)
        target = os.path.realpath(os.path.join(dest, name))
        if not target.startswith(os.path.realpath(dest) + os.sep):
            raise SystemExit("zip-slip member: %s" % name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(info) as src, open(target, "wb") as out:
            shutil.copyfileobj(src, out)
        count += 1
    return count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("extension")
    ap.add_argument("--version", default="latest")
    ap.add_argument("--root", default="extensions")
    ap.add_argument("--require-web", action="store_true",
                    help="refuse extensions with no browser entrypoint")
    ap.add_argument("--pin", default="", help="expected sha256 of the VSIX")
    a = ap.parse_args()

    ns, _, name = a.extension.partition(".")
    if not ns or not name:
        raise SystemExit("expected <publisher>.<name>")

    meta = http_json("%s/%s/%s/%s" % (API, ns, name, a.version))
    ver = meta["version"]
    dl = meta.get("files", {}).get("download")
    if not dl:
        raise SystemExit("no download URL in metadata")

    print("resolved   %s.%s %s" % (ns, name, ver))
    print("download   %s" % dl)

    req = urllib.request.Request(dl, headers={"User-Agent": "code-ios-installer/0.1"})
    with urllib.request.urlopen(req, timeout=180) as r:
        blob = r.read()
    digest = hashlib.sha256(blob).hexdigest()
    print("sha256     %s  (%d bytes)" % (digest, len(blob)))

    if a.pin and a.pin.lower() != digest:
        raise SystemExit("INTEGRITY FAILURE: pinned %s != %s" % (a.pin, digest))

    zf = zipfile.ZipFile(io.BytesIO(blob))
    pkg = next((n for n in zf.namelist()
                if n in ("extension/package.json", "package.json")), None)
    if not pkg:
        raise SystemExit("VSIX has no package.json")
    manifest = json.loads(zf.read(pkg))

    # ---- policy gates -------------------------------------------------
    lifecycle = {"preinstall", "install", "postinstall", "prepare"}
    scripts = sorted(set(manifest.get("scripts") or {}) & lifecycle)
    browser = manifest.get("browser")
    main = manifest.get("main")
    if scripts:
        raise SystemExit("refusing: package.json declares lifecycle scripts %s" % scripts)
    if a.require_web and not browser:
        raise SystemExit("refusing: no 'browser' entrypoint (desktop-only, needs node host)")
    incompatible = (manifest.get("extensionKind") or []) == ["workspace"] and not browser
    if incompatible:
        raise SystemExit("refusing: workspace-only extension")

    dest = os.path.join(a.root, "%s.%s-%s" % (ns, name, ver))
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest, exist_ok=True)
    n = safe_extract(zf, dest)
    print("unpacked   %d files -> %s" % (n, dest))
    print("host       %s" % ("web worker (browser entrypoint)" if browser else "NODE REQUIRED (main only)"))

    rec = {
        "id": "%s.%s" % (ns, name),
        "version": ver,
        "sha256": digest,
        "host": "web" if browser else "node",
        "entrypoint": browser or main,
        "installedAt": __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime()),
        "path": dest,
    }
    ledger = os.path.join(a.root, "installed.json")
    db = {}
    if os.path.exists(ledger):
        with open(ledger) as f:
            db = json.load(f)
    db[rec["id"]] = rec
    with open(ledger, "w") as f:
        json.dump(db, f, indent=1, sort_keys=True)
    print("ledger     %s" % ledger)
    print("register   %s" % dest)


if __name__ == "__main__":
    main()
