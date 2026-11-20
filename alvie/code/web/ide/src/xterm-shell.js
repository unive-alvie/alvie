// The shell of the IDE on xterm.js
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { Shell } from './terminal.js';

// A shell on xterm.js in an element of the page
export function xtermShell(element, options) {
  const term = new Terminal({ fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: 13, convertEol: true, cursorBlink: true,
    theme: { background: '#1e1e1e' } });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(element);
  fit.fit();
  new ResizeObserver(() => fit.fit()).observe(element);
  const shell = new Shell(term, options);
  term.onData((d) => shell.input(d));
  return shell;
}
