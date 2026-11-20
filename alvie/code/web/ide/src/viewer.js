// The viewer of the IDE: models and witness graphs (.dot) drawn by Graphviz in WebAssembly (@viz-js/viz), one or two
// side by side, with pan (drag) and zoom (wheel). It follows the files: a model learned again is drawn again.
import { instance } from '@viz-js/viz';
import { shortLabels } from './labels.js';

export class Viewer {
  constructor(element, { files, onTitle }) {
    Object.assign(this, { element, files, onTitle });
    this.paths = []; this.viz = null; this.short = true;
    files.onChange((path) => { if (this.paths.length && (path === undefined || this.paths.includes(path))) this.render(); });
  }

  async show(paths) { this.paths = paths.slice(0, 2); await this.render(); }
  close(i) { this.paths.splice(i, 1); this.render(); }

  async render() {
    this.viz ??= await instance();
    this.element.replaceChildren();
    this.onTitle(this.paths);
    for (const [i, path] of this.paths.entries()) {
      const pane = document.createElement('div');
      pane.className = 'viewer-pane';
      const head = document.createElement('div');
      head.className = 'viewer-pane-head';
      head.textContent = path;
      const body = document.createElement('div');
      body.className = 'viewer-pane-body';
      pane.append(head, body);
      this.element.append(pane);
      if (!this.files.has(path)) { body.textContent = '(the file does not exist)'; continue; }
      try {
        const dot = this.short ? shortLabels(this.files.read(path)) : this.files.read(path);
        const svg = this.viz.renderSVGElement(dot, {
          graphAttributes: { fontname: 'Helvetica' },
          nodeAttributes: { fontname: 'Helvetica', fontsize: 11 },
          edgeAttributes: { fontname: 'Helvetica', fontsize: 9 },
        });
        body.append(svg);
        panZoom(body, svg);
      } catch (e) {
        body.textContent = `Graphviz cannot draw ${path}: ${e.message || e}`;
      }
      if (i === 0 && this.paths.length === 2) pane.classList.add('first');
    }
    if (this.paths.length === 0) this.element.innerHTML = '<p class="hint">Open a model (.dot) to draw it: double-click it in the files, or <code>view FILE [FILE2]</code>.</p>';
  }
}

// Pan (drag) and zoom (wheel) a drawing; it starts at its natural size, smaller if the pane is smaller, and a double
// click goes back there
function panZoom(container, svg) {
  let scale = 1, x = 0, y = 0, drag = null;
  const apply = () => { svg.style.transform = `translate(${x}px, ${y}px) scale(${scale})`; };
  svg.style.transformOrigin = '0 0';
  const fit = () => {
    const c = container.getBoundingClientRect(), w = svg.width.baseVal.value, h = svg.height.baseVal.value;
    scale = Math.min(1, (c.width - 16) / w, (c.height - 16) / h);
    x = Math.max(8, (c.width - w * scale) / 2); y = 8; apply();
  };
  requestAnimationFrame(fit);
  container.addEventListener('wheel', (e) => {
    e.preventDefault();
    const r = container.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    const f = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    x = mx - (mx - x) * f; y = my - (my - y) * f; scale *= f; apply();
  }, { passive: false });
  container.addEventListener('pointerdown', (e) => { drag = { x: e.clientX - x, y: e.clientY - y }; container.setPointerCapture(e.pointerId); });
  container.addEventListener('pointermove', (e) => { if (drag) { x = e.clientX - drag.x; y = e.clientY - drag.y; apply(); } });
  container.addEventListener('pointerup', () => { drag = null; });
  container.addEventListener('dblclick', fit);
}
