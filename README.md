# VS Code for iOS

A real VS Code workbench (not a Monaco clone) running natively on iOS: the official web
workbench served from a loopback HTTP server inside the app, a `FileSystemProvider` bridge to
the device's files, and Open VSX as the extension marketplace.

```
WKWebView ── http://127.0.0.1:<port> ── HTTPServer (Network.framework)
                │                              │
                │                              ├── /                workbench template
                │                              ├── /product.json     product + gallery config
                │                              ├── /ext/ios-fs       extension store
                │                              └── /_api/fs/*        FSBridge → FileManager
                └── extension host (web worker) → iosfs://local/<abs path>
```

## What works

- Full VS Code web workbench (1.91.1) in WKWebView, custom product identity, dark theme.
- Marketplace browsing against **Open VSX** with VS Code's own web-compatibility filter.
- Workspace = `Documents/Workspace`, exposed to the workbench through `iosfs://` — Explorer,
  open, save, rename, delete all hit real files.
- Files app access (`UIFileSharingEnabled`), so projects can be dropped in from Finder/iCloud.

## What does not work yet

- **Installing from the marketplace UI hangs** — the browser extension-management pipeline
  stalls in the extension host (manifest fetched, VSIX never requested). `tools/install_ext.py`
  is the working install path: resolve → sha256 pin → policy gates → unpack → ledger.
- No file watching: changes made outside VS Code need a reload (⚠ badge on the folder).
- Extensions that need `child_process`, native `.node` binaries, or a Node-only entrypoint
  cannot run in the web extension host.
- Unsigned IPA: re-sign (zsign/SideStore/AltStore) or install via TrollStore/jailbreak.

## Install

Download `CodeIOS-0.1.0-unsigned.ipa` from
[Releases](https://github.com/R0GUEEE/code-ios/releases/tag/v0.1.0) and re-sign it
(zsign / SideStore / AltStore), or install it via TrollStore or a jailbroken device.
It is **unsigned** — iOS will refuse it as-is.

sha256 `cca2da8bba6f84bf056c2979e5a28767af7781a18fc20e3cc91c7149df0f96d6`

## Build

CI only — there is no Xcode on the phone.

```sh
git push                # .github/workflows/ios.yml builds CodeIOS-unsigned.ipa
```

Locally on a Mac: `npm i vscode-web@1.91.1`, copy `node_modules/vscode-web/dist` to
`Sources/CodeIOS/Resources/Web`, copy `extensions/` to `Sources/CodeIOS/Resources/Extensions`,
then `xcodegen generate && xcodebuild ...`.

## Prototype

`tools/server.py` + `run.sh` host the same workbench from the Linux sandbox — that is where the
bridge was developed and where `--selftest` verifies the round trip without a device.

Design notes and the traps that cost days: [ARCHITECTURE.md](ARCHITECTURE.md).
