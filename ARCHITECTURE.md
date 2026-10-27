# VS Code for iOS — architecture & extension-host design

Status: drafting · 2026-10-27

## 0. What the reference app actually is (evidence, not vibes)

`thebaselab/codeapp` tree, `main` @ `9b8475e`:

| Path | Reality |
|---|---|
| `Extensions/MonacoEditor` | Monaco **editor**, not the VS Code **workbench** |
| `NodeExtension/{Node,NodeRunner,LSPFrameAdaptor}` | nodejs-mobile **18.19.0** (`1Conan/nodejs-mobile` xcframework) used for LSP servers + npm |
| `Dependencies/npm.bundle/node_modules/npm` | bundled npm, so user projects can `npm i` (pure-JS deps only) |
| `Extensions/{ImageEditor,ImageViewer,MarkdownViewer,PDFViewer,VideoViewer,SimpleWebPreview,…}` | **native Swift** out-of-process-ish modules; their own ABI |
| `Dependencies/terminal.bundle` | holzschu `ios_system` (70+ commands), `llvm` xcframeworks, cpython 3.9, OpenJDK 8 |
| `SwiftGit2`, `SwiftWS` | libgit2 and websockets |
| `README.md` | "Use VS Code as a design template … with monaco-editor and native code" |

Consequence: **there is no `vscode` extension API, no extension host, no VSIX loader, no
marketplace client in codeapp.** Its plugin model is "native module + Monaco language service."
Forking it does not move us toward marketplace support; it moves us toward a nicer Monaco.

## 1. What "extension support" actually requires

A VS Code extension is *not* a sandboxed plugin. It is a Node.js module whose `activate()`
receives a `vscode` object with ~2000 API members, and which may `require('fs')`,
`require('child_process')`, or a native `.node` binary. What the marketplace really is:

1. **Metadata service** — search/versions/deps (`open-vsx.org/api/-/search`, `microsoft marketplace`
   `/_apis/public/gallery/extensionquery`).
2. **VSIX** — a zip: `extension/package.json` (the `contributes` manifest), JS entry, assets.
3. **Host** — `extHostExtensionService` runs in a **separate process** (desktop) or a
   **Worker / iframe** (`extensionKind: ["web"]`, vscode.dev). It speaks a RPC protocol
   (`MainContext`/`ExtHostContext`) of ~120 proxy pairs.
4. **Contribution registry** — grammars, themes, snippets, commands, menus, views, debug
   adapters, task providers, formatters, etc. Mostly *declarative*, resolved by the workbench.

So the design question is never "can we show a marketplace UI" — it is **"where does the
JavaScript actually execute, and how does it reach the filesystem?"**

## 2. Three architectures

### Track A — Workbench-in-WebView + node extension host (Lean)
- Workbench: official static build (`vscode-web` npm dist 1.9x, ~59 MB unpacked) served from the
  app bundle over `http://127.0.0.1:<rand>` (needed: service worker + COOP/COEP for SAB).
- FS: a built-in **web extension** `ios-local-fs` registers a `FileSystemProvider`
  (`FileSystemProviderCapabilities.FileReadWrite | Trash`) that RPCs to Swift via
  `WKScriptMessageHandler` → `FileManager` / `UIDocument` / security-scoped bookmarks.
- Hosts:
  - **web worker host** — extensions with a `browser` entrypoint. Runs in WebKit JS. No JIT needed,
    fully App-Store-arguable. Covers a large slice: themes, icon themes, grammars, snippets,
    Prettier, ESLint(web), markdown-lint, TODO, GitLens-lite, REST client, etc.
  - **node host** — nodejs-mobile V8 (no JIT on iOS → interpreted, ~3-8× slower) or a
    Linux VM (iSH/PRoot) speaking the same `ExtensionHostProtocol` over a socket.
- Library prior art to lean on hard: **`@codingame/monaco-vscode-api`** (v38.x) — it exposes the
  workbench + ext-host plumbing for embedding, supports browser and node extension hosts, and is
  the only serious implementation of "VS Code UI outside VS Code". Do not hand-roll RPC.

### Track B — Embedded code-server (Sledgehammer)
- Real VS Code server (Node 22/24, real `child_process`, node-pty, debug adapters) inside an
  embedded Linux rootfs; iOS app = WKWebView onto `localhost:8080` + native chrome.
- Fastest path to *everything works* (tasks, debug, terminals, full ext host). Cost: 250-400 MB
  rootfs, ~200-400 MB RSS, boot time, no App Store viability without care.
- `code-server` 4.117.0 is the last release supporting Node 22; 4.133+ requires Node 24.
  Native modules (`@vscode/native-watchdog`, `node-pty`, `@parcel/watcher`) need a musl rebuild
  → `build-base`, node-gyp, ~20-40 min under emulation.

### Track C — Fork codeapp (dead end for this goal)
Only reachable if the definition of "plugin" is relaxed to "curated native module". Rejected.

**Recommendation: A for product, B as the escape hatch / power mode, sharing one UI contract
(a localhost workbench URL + a workspace path).** Ship A; when an extension needs `child_process`
or a native binary, offer "run this workspace in the VM" instead of failing.

## 3. Marketplace: the part people get wrong

- **MS Marketplace is contractually off-limits.** Terms of use restrict `extensionquery` /
  VSIX download to VS Code and derivative *Microsoft-licensed* products. VSCodium, Theia,
  code-server, vscode.dev-forks all use **Open VSX** for this reason. Do not ship an MS-market
  scraper in a distributed app — that is the one legal landmine here.
- **Open VSX (`open-vsx.org`)** — Eclipse Foundation, open API, no key needed for read:
  `GET /api/-/search?query=…&targetPlatform=universal`, `GET /api/{ns}/{name}/{version}`,
  VSIX at `/api/{ns}/{name}/{version}/file/{ns}.{name}-{version}.vsix`. ~6-7k extensions,
  near-complete coverage of popular OSS ones. Gaps: **Pylance, Copilot, C#/OmniSharp, Cursor-family,
  any closed-source MS extension** — those cannot be shipped, full stop. Provide a
  "not available" explanation instead of a broken install.
- Marketplace must additionally be filtered by **`extensionKind`** and by `main` vs `browser`:
  an extension with only `main` + Node builtins can only go to Track B / node host. Surface this
  as a compatibility badge per result (exactly like vscode.dev's "available in browser" filter).
- Signing/integrity: pin to a registry you control (proxy Open VSX), verify VSIX sha256 + publisher
  signature if present, and refuse `preinstall`/`postinstall` scripts (never `npm i` a VSIX).

## 4. Filesystem bridge (the part that makes or breaks it)

```
WKWebView  ── postMessage ──►  Swift bridge  ──► FileManager / UIDocument / bookmark
   ▲                                                  │
   └── FileSystemProvider (watch events back) ◄────────┘
```
- Implement `stat / readFile / writeFile / readDirectory / createDirectory / delete / rename /
  copy` + `watch` (FSEvents → coalesced `onDidChangeFile`). Chunked reads (>2 MB) to avoid
  message-size limits; base64 or a shared `URLSession` streaming channel for big files.
- Workspace roots: app container (default), iCloud Drive, "On My iPhone", or any folder via
  **security-scoped bookmark** persisted in keychain-adjacent storage — this is what makes it
  beat codeapp for real projects.
- Do **not** mount the whole filesystem. Scope per-workspace, deny `..` escapes, canonicalize.

## 5. Threat model / hardening (this is the part most iOS editors skip)

An extension is unsandboxed code with your filesystem, your network, and your GitHub tokens.

- **Capability-scoped shim**: don't hand out a full `vscode` + `require`. Wrap: `fs` scoped to the
  workspace root, `child_process` → policy table (default deny; allow-list of binaries with arg
  validation), `net` → per-extension egress allow-list, `env` scrubbed of tokens.
- **Permission manifest** surfaced at install: FS scope, network domains, shell commands, "reads
  other extensions' data". Consent stored per-extension, revocable, and *shown on every update*
  if the permission set grew (silent privilege escalation via update is the classic attack).
- **Token custody**: never put GitHub/SSH creds in extension-process env. Route git through the
  native libgit2 (SwiftGit2) so tokens never enter JS.
- **Registry pinning**: extension id + version + hash recorded on install; runtime refuses shadowed
  ids (typosquat: `ms-python.python` vs `ms-python.python3`), and refuses UI-impersonating
  `publisher`/`displayName` deltas.
- **Supply chain**: VSIX is a zip → validate member paths (zip-slip), reject symlinks, size caps,
  no `postinstall`. Extensions are a code-execution vector onto *user projects*; treat like npm.
- **Web host trust boundary**: in the web-worker host, `eval`/`Function` is available and WebKit JIT
  is present — the worker is *not* a sandbox for JS. It only isolates the DOM. Say so in the UI.

## 6. iOS-specific constraints (state these up front, they decide the roadmap)

| Constraint | Impact |
|---|---|
| No `fork`/`exec`, no arbitrary dylib load | node host must be in-process (nodejs-mobile) or in a VM |
| No JIT for third-party code (App Store) | nodejs-mobile V8 runs interpreted; Lua/JS heavy work is slow |
| Native `.node` addons are darwin-arm64 → load fails in-app | extension compatibility filter must be *honest*; VM fallback |
| BG execution | long `npm i` / build tasks die on suspension → run in a `BGProcessingTask` + resume journal |
| Memory (jetsam ~1.5-3 GB on modern iPad) | workbench + V8 + projects: budget RSS, evict language servers |
| App Store 2.5.2 | apps may not download/install code that changes app features. Shipping arbitrary marketplace install is a rejection risk. See §7 |

## 7. Distribution strategy (decide before writing the installer)

- **Sideload / TestFlight / AltStore / Enterprise / EU DMA marketplaces**: no restriction. Full
  marketplace.
- **App Store**: must present a defensible model. Two workable ones:
  1. *Interpreted-script model* — extensions are JS executed in **WebKit** (Apple explicitly permits
     scripts executed by WebKit). Ship only the **web worker host** in the App Store build; the node
     host is a "Power Mode" that is unavailable/greyed in App Store builds. This is how the app
     can plausibly pass review, and it's honest: no compiled code is downloaded.
  2. *Curated registry* — you review and host every extension (codeapp's model, at the cost of
     coverage).
- Do not ship a hidden toggle that turns on the node host in the App Store build. That's 2.5.2
  violation plus review fraud; if it's found, the account is the casualty, not the binary.

## 8. Staged plan with acceptance tests

**M0 — Feasibility (hours, on-device):** static `vscode-web` dist served over localhost in WKWebView,
workbench boots, opens a folder through the FS provider, persists layout. *Accept:* reload restores
tabs; write a file from Monaco and see it on disk.

**M1 — Marketplace client (web-only):** Open VSX search, compat badges, install/uninstall,
`contributes` merge without reload. *Accept:* install a theme + a grammar + one web extension
(Prettier) and have all three function.

**M2 — Native shell:** SwiftUI app, workspace bookmarks, terminal (ios_system or VM), git via
libgit2, IPA via GH Actions. *Accept:* device install, open an iCloud folder, commit.

**M3 — Node host:** nodejs-mobile + `ExtensionHostProtocol`, capability shim, permission UI.
*Accept:* an extension using `fs` + one using `child_process` (allowed binary) work; a `node-gyp`
extension fails cleanly with an actionable message.

**M4 — Power mode:** VM-backed workspace (code-server or plain node) for the 20% of extensions
that need real processes. *Accept:* Pylance-class language server attaches over LSP.

## 9. M0 findings (measured on-device, 2026-10-27)

Environment: iSH/Alpine aarch64, Node 22.23.2, `vscode-web@1.91.1` npm dist (58 MB),
served by `tools/server.py` on `127.0.0.1:8913`, viewed in the app's WKWebView (iOS 26 WebKit).

**Works:**
- Full workbench boots in WKWebView from our own origin. `crossOriginIsolated: true`,
  `SharedArrayBuffer` available, IndexedDB healthy (`quota 10.3 GB`, `vscode-web-db` created).
- Web extension host starts: `webWorkerExtensionHostIframe.html?vscode-coi=…` is created and
  the workbench runs it. This is the platform the whole plan depends on, and it is alive.
- Marketplace: search + POPULAR list come back from **Open VSX** (`POST /vscode/gallery/extensionquery`
  → 200), with VS Code's own web-compat filter drawing ⚠ on desktop-only extensions.
- A real marketplace VSIX installs and registers from our own store: `esbenp.prettier-vscode@12.4.0`,
  3 643 663 bytes, `sha256 fb730ea4306d09cdc0a3aaa9e9baae28058cc97a4fbfce8b056b377a0639a9fe`;
  the workbench fetches `package.json` + `package.nls.json` from `/ext/…` and registers its
  contributions (45 asset requests).

**Two corrections to the assumptions above (both cost real time, both now known):**
1. **The npm `vscode-web` build ignores the `vscode-workbench-web-configuration` meta tag.**
   `workbench.js` reads `window.product` and otherwise does `fetch('product.json')`. Until we served
   a real `/product.json`, the workbench ran with default identity ("Code - OSS"), no gallery
   config, and the extensions view silently returned nothing. Symptom was *zero network requests
   and zero console errors* — the giveaway is the window title.
2. **The browser-side install pipeline hangs.** `installFromGallery` runs in the extension host
   (its proxy is visible in the main bundle), fetches manifest + details (200), and then never
   issues the VSIX GET. State stays "Installing" indefinitely, no notification, no console output,
   with and without COEP/COI. Verified from the same origin that every download URL variant works
   (`/api/{ns}/{n}/{v}/file/*.vsix` 200 3.6 MB, `/vscode/asset/…/VSIXPackage` 200,
   `/vscode/gallery/publishers/…/vspackage` 200 → redirects to openvsx.eclipsecontent.org;
   `/vscode/unversional-download/…` is 404, so that template is wrong).

**Consequence — inverted install design (better anyway):** the app owns installation.
`tools/install_ext.py` resolves on Open VSX → downloads → prints/verifies sha256 (`--pin`) →
refuses lifecycle scripts, zip-slip members and symlinks → unpacks to `extensions/<id>-<ver>` →
writes a ledger (`extensions/installed.json`) → the server registers it as a builtin extension
(`additionalBuiltinExtensions` in `/product.json`, assets on `/ext/…`). Deterministic, auditable,
offline-capable, and it is the natural choke point for the permission model in §5.

**Filesystem bridge (built, working):** `extensions/ios-fs` registers a `FileSystemProvider`
for scheme `iosfs` (`iosfs://local/<abs path>`), proxying stat / readDirectory / readFile /
writeFile / createDirectory / delete / rename to `/_api/fs/*`. The workbench opens
`iosfs://local/var/.../demo-workspace` as its workspace folder — Explorer lists real device
files, and `vscode.workspace.fs.writeFile` round-trips to disk
(`SELFTEST ok, 48 bytes` verified on disk). Watch/change-notification is still a no-op
(`build: FileSystemProviderCapabilities` gap → the ⚠ badge on the folder).

**Three traps that cost hours, all environmental — record them:**
1. **A stale server silently owns the port.** `pkill` may miss an instance; the live page then
   talks to a process whose stdout points at a dead inode. Every log, every trace, is a lie.
   Always restart with `run.sh` (it kills first) and confirm with one marker request.
2. **`Cache-Control: max-age=3600` on the FS API.** `_send` applied it to every non-HTML
   response, so WebKit replayed `stat`/`read` from cache: the tree rendered, the server saw
   nothing, and edits looked like they vanished. A filesystem API must be `no-store`, and the
   dev bridge also appends a random `_=<nonce>` to every call. In the native build there is no
   HTTP cache at all — this is a prototype artifact, but the header fix stays.
3. **`document.visibilityState === "hidden"` in the driven WebView** (`rAF` never fires,
   `getBoundingClientRect` of `.view-lines` = height 0). Monaco renders exclusively off rAF, so
   the editor draws **zero lines** even though the model holds the right bytes. Not an app bug:
   it means headless UI verification of editor content is impossible; verify the bridge through
   the API (the `--selftest` round trip) and check visuals in a foregrounded app.

**Still open at M0:** extension *activation* for marketplace installs (contributions register,
`activate()` is lazy — the builtin Prettier loads manifest + nls but not its entrypoint),
file watching, and the 1.91.1 base is ~2 years old (`vscode-web` on npm is frozen there; newer
builds need `gulp vscode-web-min` in CI or `@codingame/monaco-vscode-api`).

## 10. Open decisions

1. Track A first, or Track B first (fastest to "everything works", heaviest)?
2. Distribution target: sideload/TestFlight (no limits) vs App Store (web host only)?
3. Reuse `@codingame/monaco-vscode-api` (embedding-first, alive) vs raw `vscode-web` static dist
   (closest to upstream, but ext-host wiring must be done by hand).
