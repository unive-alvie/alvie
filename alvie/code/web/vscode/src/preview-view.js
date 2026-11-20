// The webview of the preview: the viewer of the IDE on the models that the extension posts
import { Viewer } from './core/viewer.js';

const vscode = acquireVsCodeApi();
const models = new Map();
const files = { has: (p) => models.get(p) != null, read: (p) => models.get(p), onChange: () => {} };
const viewer = new Viewer(document.getElementById('viewer'), { files, onTitle: () => {} });
window.addEventListener('message', (e) => {
  const m = e.data;
  if (m.type !== 'show') return;
  models.clear();
  for (const { path, text } of m.models) models.set(path, text);
  viewer.show(m.models.map((x) => x.path), m.inputs);
});
vscode.postMessage({ type: 'ready' });
