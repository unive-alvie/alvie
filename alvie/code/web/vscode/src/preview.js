// The preview of models: a webview that draws one or two models (.dot) with the viewer of the IDE, and follows
// inputs on them. It draws them again when they change (a model learned again).
import * as vscode from 'vscode';

export class Preview {
  constructor(context, files) {
    Object.assign(this, { context, files });
    this.panel = null; this.paths = []; this.inputs = [];
    files.onChange((path) => { if (this.panel && (path === undefined || this.paths.includes(path))) this.post(); });
  }

  show(paths, inputs = []) {
    this.paths = paths.slice(0, 2); this.inputs = inputs;
    const title = `Model: ${this.paths.map((p) => p.split('/').pop()).join(' | ')}`;
    if (!this.panel) {
      const media = vscode.Uri.joinPath(this.context.extensionUri, 'out');
      this.panel = vscode.window.createWebviewPanel('alvie.preview', title, { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
        { enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [media] });
      const web = this.panel.webview, src = (f) => web.asWebviewUri(vscode.Uri.joinPath(media, f));
      web.html = `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${web.cspSource} 'unsafe-inline'; script-src ${web.cspSource} 'wasm-unsafe-eval'; img-src ${web.cspSource} data:;">
<link rel="stylesheet" href="${src('preview.css')}"></head>
<body><div id="viewer"></div><script src="${src('preview.js')}"></script></body></html>`;
      web.onDidReceiveMessage((m) => { if (m.type === 'ready') this.post(); });
      this.panel.onDidDispose(() => { this.panel = null; });
    } else {
      this.panel.title = title;
      this.panel.reveal(undefined, true);
      this.post();
    }
  }

  post() {
    const models = this.paths.map((p) => ({ path: p, text: this.files.has(p) ? this.files.read(p) : null }));
    this.panel?.webview.postMessage({ type: 'show', models, inputs: this.inputs });
  }
}
