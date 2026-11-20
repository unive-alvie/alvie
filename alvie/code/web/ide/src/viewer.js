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

  // paths: one or two models; inputs: a sequence of inputs to follow from the initial state of each (e.g. a sequence
  // that compare printed), whose transitions are highlighted, and the first state where one is missing marked
  async show(paths, inputs = []) { this.paths = paths.slice(0, 2); this.inputs = inputs; await this.render(); }
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
        // Top to bottom: the panes are taller than wide, two of them side by side
        const dot = mergeParallel(this.short ? shortLabels(this.files.read(path)) : this.files.read(path)).replace(/rankdir\s*=\s*"?LR"?\s*;?/g, '');
        const svg = this.viz.renderSVGElement(dot, {
          graphAttributes: { fontname: 'Helvetica' },
          nodeAttributes: { fontname: 'Helvetica', fontsize: 11 },
          edgeAttributes: { fontname: 'Helvetica', fontsize: 9 },
        });
        body.append(svg);
        if (this.inputs?.length) head.textContent += `  —  ${follow(svg, this.inputs)}`;
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
// One edge for the transitions between the same two states, with one line of label for each: models of ALVIE often
// have many (e.g. every input that a state refuses), which otherwise hide the drawing
export function mergeParallel(dot) {
  const groups = new Map(), rest = [];
  for (const line of dot.split('\n')) {
    const m = line.match(/^\s*("?[\w.]+"?)\s*->\s*("?[\w.]+"?)\s*\[label="((?:[^"\\]|\\.)*)"[^\]]*\];?\s*$/);
    if (m && m[1] !== '__start') {
      const key = `${m[1]} -> ${m[2]}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(m[3]);
    } else rest.push(line);
  }
  if (groups.size === 0) return dot;
  const close = rest.map((l) => l.trim()).lastIndexOf('}');
  const edges = [...groups].map(([key, labels]) => `  ${key} [label="${labels.join('\\l')}${labels.length > 1 ? '\\l' : ''}"];`);
  return [...rest.slice(0, close), ...edges, ...rest.slice(close)].join('\n');
}

// Follows the inputs from the initial state of a drawn model (the target of __start, or the state 0): the label of a
// transition starts with its input, as in "HELLO / OK" or "timer_enable 1 / Time ...". Highlights the transitions
// taken, marks the state where an input has no transition, and says how far it went.
function follow(svg, inputs) {
  const edges = [...svg.querySelectorAll('g.edge')].map((g) => {
    const [from, to] = (g.querySelector('title')?.textContent || '').split('->');
    return { g, from, to, lines: [...g.querySelectorAll('text')].map((t) => t.textContent.trim()) };
  });
  const node = (name) => [...svg.querySelectorAll('g.node')].find((g) => g.querySelector('title')?.textContent === name);
  let state = edges.find((e) => e.from === '__start')?.to ?? (node('0') ? '0' : null);
  const paint = (g, color) => g.querySelectorAll('path, polygon, ellipse').forEach((el) => {
    el.setAttribute('stroke', color); el.setAttribute('stroke-width', '2.5'); if (el.tagName === 'polygon') el.setAttribute('fill', color);
  });
  if (state === null) return 'no initial state';
  paint(node(state), '#2a78d6');
  for (const [k, input] of inputs.entries()) {
    const matches = (l) => l === input || l.startsWith(`${input} /`) || l.startsWith(`${input}/`);
    const e = edges.find((x) => x.from === state && x.lines.some(matches));
    if (!e) { const n = node(state); if (n) paint(n, '#e34948'); return `no transition for ${input} (step ${k + 1}) in state ${state}`; }
    paint(e.g, '#2a78d6');
    e.g.querySelectorAll('text').forEach((t) => { if (matches(t.textContent.trim())) { t.setAttribute('fill', '#2a78d6'); t.setAttribute('font-weight', 'bold'); } });
    state = e.to;
    const n = node(state); if (n) paint(n, '#2a78d6');
  }
  return `followed ${inputs.length} input${inputs.length === 1 ? '' : 's'} to state ${state}`;
}

function panZoom(container, svg) {
  let scale = 1, x = 0, y = 0, drag = null;
  const apply = () => { svg.style.transform = `translate(${x}px, ${y}px) scale(${scale})`; };
  svg.style.transformOrigin = '0 0';
  const fit = () => {
    const c = container.getBoundingClientRect(), w = svg.width.baseVal.value, h = svg.height.baseVal.value;
    // Natural size, smaller to fit the width of the pane, but not below half (pan for the rest)
    scale = Math.max(0.5, Math.min(1, (c.width - 16) / w));
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
