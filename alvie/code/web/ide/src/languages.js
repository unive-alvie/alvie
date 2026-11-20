// The languages of the editor, as stream languages of CodeMirror: the specs of ALVIE/Sancus (.atdl, .etdl, the
// TestDL of ALVIE), the specs of ALVIE/VaultLink (.vtdl) and models (.dot)
import { StreamLanguage } from '@codemirror/language';

// Nested (* ... *) comments, shared by the spec languages
function comment(stream, state) {
  while (!stream.eol()) {
    if (stream.match('(*')) state.depth++;
    else if (stream.match('*)')) { if (--state.depth === 0) return 'comment'; }
    else stream.next();
  }
  return 'comment';
}

function specLanguage({ name, sections, keywords }) {
  return StreamLanguage.define({
    name,
    startState: () => ({ depth: 0 }),
    token(stream, state) {
      if (state.depth > 0) return comment(stream, state);
      if (stream.eatSpace()) return null;
      if (stream.match('(*')) { state.depth = 1; return comment(stream, state); }
      if (stream.match(/^"(?:[^"\\]|\\.)*"?/)) return 'string';
      if (stream.match(/^#-?(?:0x[0-9a-fA-F]+|\d+)/) || stream.match(/^-?(?:0x[0-9a-fA-F]+|\d+)\b/)) return 'number';
      if (stream.match(/^&[A-Za-z_][\w]*/)) return 'variableName.special';
      if (stream.match('?')) return 'atom';
      if (stream.match('->')) return 'operator';
      if (stream.match(/^[|;*]/)) return 'operator';
      const m = stream.match(/^[A-Za-z_][\w-]*/);
      if (m) {
        const w = m[0];
        if (sections.includes(w)) return 'keyword';
        if (keywords.includes(w)) return 'atom';
        if (/^r\d+$/.test(w)) return 'variableName';
        if (/^[A-Z][A-Z0-9_]*$/.test(w)) return 'typeName';
        return 'variableName';
      }
      stream.next();
      return null;
    },
    languageData: { commentTokens: { block: { open: '(*', close: '*)' } } },
  });
}

export const testdl = specLanguage({
  name: 'testdl',
  sections: ['isr', 'prepare', 'cleanup', 'enclave'],
  keywords: ['eps', 'ifz', 'timer_enable', 'start_counting', 'create', 'jin', 'reti', 'rst', 'rstnz', 'ubr', 'nop', 'dint', 'mov',
    'add', 'cmp', 'jmp', 'jz', 'jnz', 'push', 'enc_s', 'enc_e', 'data_s', 'data_e', 'unprot_mem'],
});

export const vtdl = specLanguage({ name: 'vtdl', sections: ['values', 'inputs', 'observe', 'session'], keywords: ['eps', '_'] });

export const dot = StreamLanguage.define({
  name: 'dot',
  token(stream) {
    if (stream.eatSpace()) return null;
    if (stream.match('//')) { stream.skipToEnd(); return 'comment'; }
    if (stream.match(/^"(?:[^"\\]|\\.)*"?/)) return 'string';
    if (stream.match(/^(?:digraph|graph|node|edge|subgraph|strict)\b/)) return 'keyword';
    if (stream.match(/^-[->]/)) return 'operator';
    if (stream.match(/^\d+/)) return 'number';
    if (stream.match(/^[A-Za-z_]\w*/)) return 'variableName';
    stream.next(); return null;
  },
});

export function languageOf(path) {
  if (/\.(atdl|etdl|spec)$/.test(path)) return testdl;
  if (/\.vtdl$/.test(path)) return vtdl;
  if (/\.dot$/.test(path)) return dot;
  return null;
}
