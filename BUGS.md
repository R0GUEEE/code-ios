# Bug audit — v0.1.0 → v0.1.1

Method: static review of every source file, plus live verification of the JavaScript layer
against a running workbench (the Swift layer cannot be executed on the device it was built for).
Each finding below states how it was confirmed.

Severity is "what happens on first launch", not "how bad the code looks".

## Fixed in v0.1.1

### 1. BLOCKER — the workbench was served as `text/plain`
`WebHost.workbench()` returned `HTTPResponse.text(html)`, and `text()` sets
`Content-Type: text/plain; charset=utf-8`. WKWebView would have rendered the HTML source as
literal text: the app launches to a wall of markup instead of an editor.

Confirmed by inspection (`HTTPTypes.swift:32`, `WebHost.swift:194`). Fixed with an explicit
`.html()` response type.

### 2. HIGH — the provider declared no `capabilities`, so saving looked read-only
`registerFileSystemProvider` takes only `{isCaseSensitive, isReadonly}`; the *capability bits*
come from `provider.capabilities`. Ours was absent → the service saw `0` (`None`), which lacks
`FileReadWrite` (2). `vscode.workspace.fs.writeFile` bypasses that check (which is why the
prototype self-test passed), but `TextFileService`/`FileService.writeFile` — the path the editor
uses when you press save — consults it.

Confirmed: `FileSystemProviderCapabilities` in the bundle is
`None=0, FileReadWrite=2, FileOpenReadWriteClose=4, FileFolderCopy=8, FileReadStream=16,
PathCaseSensitive=1024, …`. Fixed by exposing `capabilities = 2 | 1024`; verified live in the
workbench (`caps: 1026` logged from the extension).

### 3. HIGH — every filesystem error became `FileIO`
The bridge mapped 404/403/400 all to `FileSystemError.FileIO`. VS Code branches on those codes:
`FileNotFound` is how it knows a path is free (new file) versus broken.

Confirmed live: stat of a missing path returned `code: "Unknown"` before the fix,
`code: "FileNotFound"` after it (with the prototype aligned to return 404 like the app does).

### 4. HIGH — symlink escape out of the workspace
`FSBridge.resolve()` canonicalised the *requested* path with `standardizedFileURL` but compared it
against roots resolved with `resolvingSymlinksInPath()`. A symlink planted inside the workspace
(e.g. by a malicious extension or an unzipped project) pointed anywhere on disk and passed the
containment check; `Data(contentsOf:)` then followed it.

Confirmed by inspection. Fixed: resolve symlinks on the candidate before the prefix check.

### 5. MEDIUM — a chunked upload would silently truncate a file to zero bytes
The server parses only `Content-Length`. A `Transfer-Encoding: chunked` request would be read as
an empty body and `writeFile` would happily write nothing. Silent data loss is worse than an
error, so the server now answers `411 Length Required` and logs it.

`fetch()` with a `Uint8Array` sends `Content-Length`, so the current client never triggers this —
it is a trap for the next one.

### 6. MEDIUM — bundled assets were cacheable for an hour, across app updates
`Cache-Control: public, max-age=3600` on everything under `/out` and `/ext`, with no validator.
Update the app, relaunch, and WebKit could keep running last build's workbench from cache against
new Swift code — the worst kind of bug to diagnose.

Fixed: assets are `no-cache` with a weak `ETag` (size + mtime), answered with `304` when it
matches. The filesystem API stays `no-store`.

### 7. MEDIUM — connections leaked on stalled clients
Nothing timed out a half-open request: a client that sent headers and stopped held an
`NWConnection` for the life of the process. Added a 30 s idle timeout per connection.

### 8. LOW — `delete` ignored `options.recursive`
Always recursive on the server side. VS Code asks for non-recursive deletes too, and the
difference is "refuse to remove a non-empty folder" vs "wipe it". Now honoured end to end.

### 9. LOW — missing `X-Content-Type-Options: nosniff`; `&` unescaped in the config attribute
Both hardening details rather than live bugs. Fixed.

## v0.1.2 — crash instrumentation

The v0.1.1 build crashed on device at startup and could not be reproduced off-device.
v0.1.2 does not guess at a fix; it makes the app testify:

- `Documents/launch.log` — timestamped breadcrumb per boot stage (app init → host init →
  listen port → webview create → load → didFinish).
- A launch marker armed in `App.init` and removed only when the page finishes loading. If the
  marker survives to the next launch, the app opens **diagnostics instead of a blank screen**
  and shows the trail, with Copy / Retry / Continue-anyway.
- `NSSetUncaughtExceptionHandler` + fatal-signal handlers append a final line and write a
  report to `Documents/crashes/`.
- `Documents` is visible in the Files app (`UIFileSharingEnabled`), so the log can be read
  without a Mac.

Two latent defects fixed on the way:

- `sockaddr_in.sin_len` was left 0 before `bind()`; Darwin expects it set, and on failure every
  candidate port would look busy and startup would abort with "no free port".
- `NWListener` was driven from a *concurrent* queue, so connection callbacks could interleave
  unsynchronised; it is serial now.

Also added `LSRequiresIPhoneOS` and a `UIApplicationSceneManifest`, both of which Xcode puts in
every iOS app and neither of which the earlier build had.

## Open — known, deliberate, not fixed here

| # | Issue | Why it matters |
|---|---|---|
| 1 | **No file watching** (`watch()` returns a no-op disposable) | External changes never reach the editor; git operations, `npm install`, Shortcuts writing into the folder all look invisible until reload. Needs FSEvents → `onDidChangeFile`. |
| 2 | **Marketplace install hangs in the extension host** | Browsing works; installing does not. `tools/install_ext.py` is the working path (resolve → pin → unpack → ledger). |
| 3 | **Loopback is device-wide on iOS** | Any app on the device can reach `127.0.0.1:<port>/_api/fs/*` and read/write the workspace. A per-launch bearer token would stop casual discovery but cannot fully solve it while the token must be handed to the WebView. |
| 4 | **`Connection: close` per request** | ~700 requests per workbench load, each a fresh TCP connection. Correct, not fast. Keep-alive is the obvious optimisation. |
| 5 | **No `Range` support** | Only matters if something streams media; nothing does yet. |
| 6 | **`contentInsetAdjustmentBehavior = .never`** | The workbench may draw under the notch and home indicator; VS Code's web layout has no safe-area awareness of its own. |

## Product gaps versus "an iOS version of VS Code"

These are not bugs — they are the boundary of the architecture, and they should be stated plainly
because three of them are things people assume VS Code does:

- **No integrated terminal.** It needs a pty and a shell; the web workbench has neither. This is
  Track B (embedded Linux) territory.
- **No debugger and no tasks/build.** Both require spawning Node processes.
- **No built-in Git UI.** The desktop `vscode.git` extension is Node-only; the web build ships
  "GitHub Repositories" instead.
- **Extensions are limited to the web host**: no `child_process`, no native `.node` binaries, no
  Node-only entrypoints. Roughly the same subset vscode.dev offers.
- **One workspace**: `Documents/Workspace`, chosen at launch. No folder picker, no multi-root from
  external locations (a `UIDocumentPicker` + security-scoped bookmark is the fix).
- **No app icon** — irrelevant for sideloading, a submission blocker for the App Store.
