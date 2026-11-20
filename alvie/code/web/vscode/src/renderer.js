// The renderer of models in the cells of a tutorial (application/vnd.alvie.models+json: { models: [{ path, text }],
// inputs }): the viewer of the preview, one or two models side by side, with the inputs followed on them
import { Viewer } from './core/viewer.js';

const STYLE = `
.alvie-models { display: flex; height: 460px; border: 1px solid var(--vscode-panel-border, #444); }
.alvie-models .viewer-pane { flex: 1; display: grid; grid-template-rows: auto minmax(0, 1fr); min-width: 0; }
.alvie-models .viewer-pane.first { border-right: 1px solid var(--vscode-panel-border, #444); }
.alvie-models .viewer-pane-head { padding: 4px 8px; font-size: 12px; opacity: 0.8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.alvie-models .viewer-pane-body { overflow: hidden; cursor: grab; position: relative; background: #fff; }
.alvie-models .viewer-pane-body svg { position: absolute; left: 0; top: 0; }
.alvie-models .hint { padding: 16px; }`;

export function activate() {
  return {
    renderOutputItem(item, element) {
      const { models, inputs } = item.json();
      const texts = new Map(models.map((m) => [m.path, m.text]));
      const files = { has: (p) => texts.get(p) != null, read: (p) => texts.get(p), onChange: () => {} };
      element.replaceChildren();
      const style = document.createElement('style'); style.textContent = STYLE;
      const box = document.createElement('div'); box.className = 'alvie-models';
      element.append(style, box);
      new Viewer(box, { files, onTitle: () => {} }).show(models.map((m) => m.path), inputs || []);
    },
  };
}
