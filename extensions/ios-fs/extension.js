// iOS filesystem bridge — a web extension (CJS, like VS Code's own builtin web extensions).
// Registers a FileSystemProvider for scheme `iosfs` and proxies every operation to the
// native host over HTTP.  In the shipped app this same interface is served by Swift
// (FileManager / security-scoped bookmarks) instead of Python.
const vscode = require('vscode');
const ORIGIN = (typeof self !== 'undefined' && self.location && self.location.origin) || 'http://127.0.0.1:8920';
(function () {
	try {
		fetch(ORIGIN + '/_api/log', { method: 'POST', body: JSON.stringify({
			ev: 'module-load', loc: String((typeof self !== 'undefined' && self.location && self.location.href) || 'none')
		}) });
	} catch (e) {}
})();

const API = ORIGIN + '/_api/fs/';

function log(msg) {
	try {
		fetch(ORIGIN + '/_api/log', { method: 'POST', body: JSON.stringify(msg) });
	} catch (e) { /* logging must never break the bridge */ }
}

// FileSystemProviderCapabilities is not part of the public vscode.d.ts surface, so
// these are the numeric values from the protocol: 2 = FileReadWrite (readFile /
// writeFile), 1024 = PathCaseSensitive. Without capabilities the file service sees
// 0 and treats the workspace as read-only, which breaks saving from the editor.
const CAPABILITIES = 2 | 1024;

class IosFsProvider {
	constructor() {
		this._emitter = new vscode.EventEmitter();
		this.onDidChangeFile = this._emitter.event;
	}

	get capabilities() {
		return CAPABILITIES;
	}

	// ---- helpers -------------------------------------------------------
	async _call(op, params, init) {
		const q = Object.entries(params || {})
			.map(([k, v]) => k + '=' + encodeURIComponent(v))
			.concat('_=' + Math.random().toString(36).slice(2))
			.join('&');
		let res;
		try {
			res = await fetch(API + op + (q ? '?' + q : ''), init);
		} catch (e) {
			log({ ev: 'FETCH-FAILED', op, url: API + op, err: String(e && e.message || e) });
			throw vscode.FileSystemError.FileIO(String(e));
		}
		if (!res.ok) {
			let msg = op + ' failed (' + res.status + ')';
			try {
				const j = await res.json();
				if (j.error) {
					msg = j.error;
				}
			} catch (e) { /* non-json body */ }
			// VS Code branches on these codes (e.g. "file does not exist yet" when
			// saving a new file). Reporting everything as FileIO breaks those paths.
			if (res.status === 404) {
				throw vscode.FileSystemError.FileNotFound(msg);
			}
			if (res.status === 403) {
				throw vscode.FileSystemError.NoPermissions(msg);
			}
			if (res.status === 400 && /not empty/i.test(msg)) {
				throw vscode.FileSystemError.FileIsADirectory(msg);
			}
			throw vscode.FileSystemError.FileIO(msg);
		}
		return res;
	}

	// ---- FileSystemProvider -------------------------------------------
	watch() {
		// M0: no change notification yet. Real app: FSEvents -> onDidChangeFile.
		return new vscode.Disposable(() => {});
	}

	async stat(uri) {
		const res = await this._call('stat', { path: uri.path });
		const s = await res.json();
		log({ ev: 'stat', path: uri.path, type: s.type, size: s.size });
		return {
			type: s.type === 2 ? vscode.FileType.Directory : vscode.FileType.File,
			ctime: s.mtime,
			mtime: s.mtime,
			size: s.size
		};
	}

	async readDirectory(uri) {
		const res = await this._call('list', { path: uri.path });
		const rows = await res.json();
		return rows.map((r) => [r.name, r.dir ? vscode.FileType.Directory : vscode.FileType.File]);
	}

	async readFile(uri) {
		const res = await this._call('read', { path: uri.path });
		const buf = new Uint8Array(await res.arrayBuffer());
		log({ ev: 'readFile', path: uri.path, bytes: buf.length, head: Array.from(buf.slice(0, 12)).join(',') });
		return buf;
	}

	async writeFile(uri, content) {
		await this._call('write', { path: uri.path }, { method: 'PUT', body: content });
	}

	async createDirectory(uri) {
		await this._call('mkdir', { path: uri.path }, { method: 'POST' });
	}

	async delete(uri, options) {
		const recursive = options && options.recursive ? 1 : 0;
		await this._call('delete', { path: uri.path, recursive: recursive }, { method: 'POST' });
	}

	async rename(from, to) {
		await this._call('rename', { from: from.path, to: to.path }, { method: 'POST' });
	}
}

function folderUri(path) {
	// iosfs://local/<absolute path>  — authority is a placeholder, path is authoritative
	return vscode.Uri.from({ scheme: 'iosfs', authority: 'local', path });
}

async function activate(context) {
	try {
		return await _activate(context);
	} catch (e) {
		log({ ev: 'ACTIVATE-FAILED', err: String(e && e.stack || e) });
		throw e;
	}
}

async function _activate(context) {
	log({ ev: 'activate', origin: ORIGIN });

	const provider = new IosFsProvider();
	context.subscriptions.push(
		vscode.workspace.registerFileSystemProvider('iosfs', provider, {
			isCaseSensitive: true,
			isReadonly: false
		})
	);
	log({ ev: 'provider-registered', folders: (vscode.workspace.workspaceFolders || []).length });

	context.subscriptions.push(
		vscode.commands.registerCommand('iosfs.ping', async () => {
			const res = await fetch(ORIGIN + '/_api/workspace');
			const j = await res.json();
			vscode.window.showInformationMessage('iOS bridge alive. Root: ' + (j.folder || '(none)'));
		})
	);

	context.subscriptions.push(
		vscode.commands.registerCommand('iosfs.openWorkspace', async () => {
			const res = await fetch(ORIGIN + '/_api/workspace');
			const j = await res.json();
			if (!j.folder) {
				vscode.window.showErrorMessage('No workspace configured on the host.');
				return;
			}
			await vscode.commands.executeCommand('vscode.openFolder', folderUri(j.folder), {
				forceReopen: true
			});
		})
	);

	// Bridge self-test: exercises the exact code paths the editor uses.
	try {
		const info = await (await fetch(ORIGIN + '/_api/workspace')).json();
		if (info.selftest && info.folder) {
			const uri = vscode.Uri.from({ scheme: 'iosfs', authority: 'local',
				path: info.folder + '/.bridge-selftest.txt' });
			const payload = '# written by ios-fs at ' + new Date().toISOString() + '\n';
			await vscode.workspace.fs.writeFile(uri, new TextEncoder().encode(payload));
			const back = await vscode.workspace.fs.readFile(uri);
			const text = new TextDecoder().decode(back);
			log({ ev: 'SELFTEST', ok: text === payload, bytes: back.length, text: text.trim() });

			// error-code contract: a missing file must surface as FileNotFound,
			// not FileIO, or VS Code cannot tell "new file" from "broken bridge"
			const missing = vscode.Uri.from({ scheme: 'iosfs', authority: 'local',
				path: info.folder + '/.definitely-not-here' });
			try {
				await vscode.workspace.fs.stat(missing);
				log({ ev: 'ERRCHECK', ok: false, why: 'stat of missing path did not throw' });
			} catch (e) {
				log({ ev: 'ERRCHECK', ok: e.code === 'FileNotFound', code: e.code, caps: provider.capabilities });
			}
		}
	} catch (e) {
		log({ ev: 'SELFTEST-FAILED', err: String(e && e.message || e) });
	}

	// If the host has a workspace but the workbench is not in one, open it now.
	// Guarded so it can only fire once per page load.
	try {
		if (!(vscode.workspace.workspaceFolders || []).length && !globalThis.__iosfsOpened) {
			globalThis.__iosfsOpened = true;
			const res = await fetch(ORIGIN + '/_api/workspace');
			const j = await res.json();
			if (j.folder && j.autoOpen) {
				log({ ev: 'opening-folder', folder: j.folder });
				await vscode.commands.executeCommand('vscode.openFolder', folderUri(j.folder), {
					forceReopen: true
				});
			}
		}
	} catch (e) {
		log({ ev: 'open-failed', err: String(e) });
	}
}

function deactivate() {}

exports.activate = activate;
exports.deactivate = deactivate;
