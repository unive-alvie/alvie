// Shorter labels for the models of ALVIE/Sancus, whose transitions carry whole S-expressions, e.g.
//   ((IAttacker(CTimerEnable 1))((OTime((k 15)(gie false)(umem_val 0)(reg_val 0)(timerA_counter 0)(mode UM))))()32))
// becomes "timer_enable 1 / Time k=15 tA=0 UM". Labels that are not S-expressions of Sancus (VaultLink, Tiny) stay.

function parse(text) {
  let i = 0;
  const value = () => {
    while (text[i] === ' ') i++;
    if (text[i] === '(') {
      i++; const items = [];
      while (i < text.length && text[i] !== ')') { items.push(value()); while (text[i] === ' ') i++; }
      i++; return items;
    }
    const j = i; while (i < text.length && !' ()'.includes(text[i])) i++;
    return text.slice(j, i);
  };
  const v = value();
  return i >= text.trimEnd().length ? v : null;
}

const NAMES = { CTimerEnable: 'timer_enable', CStartCounting: 'start_counting', CCreateEncl: 'create', CJmpIn: 'jin', CReti: 'reti', CRst: 'rst',
  CRstNZ: 'rstnz', CUbr: 'ubr', I_NOP: 'nop', I_DINT: 'dint', I_MOV: 'mov', I_ADD: 'add', I_CMP: 'cmp', I_JMP: 'br', I_JZ: 'jz', I_JNZ: 'jnz',
  I_PUSH: 'push', CIfZ: 'ifz', CBalancedIfZ: 'ifz', INoInput: '_' };

function operand(o) {
  if (typeof o === 'string') return o;
  const [t, v] = o;
  if (t === 'S_IMM') return `#${operand(v)}`;
  if (t === 'S_AMP' || t === 'D_AMP_MEM' || t === 'D_AMP') return `&${operand(v)}`;
  if (t === 'S_R' || t === 'D_R') return Array.isArray(v) ? `r${v[1]}` : `r${v}`;
  if (t === 'S_AT') return `@r${Array.isArray(v) ? v[1] : v}`;
  return o.map(operand).join(' ');
}

function input(e) {
  if (typeof e === 'string') return NAMES[e] || e;
  const [tag, ...args] = e;
  if (tag === 'IAttacker' || tag === 'IEnclave' || tag === 'CInst') return input(args[0]);
  if (tag === 'CCreateEncl') return 'create';
  if (tag === 'CIfZ' || tag === 'CBalancedIfZ') return `ifz(${args[0].map((b) => b.map(input).join('; ')).join(' | ')})`;
  const name = NAMES[tag] || tag;
  return args.length ? `${name} ${args.map(operand).join(', ')}` : name;
}

function fields(r) {
  const f = Object.fromEntries(r.filter(Array.isArray).map(([k, v]) => [k, v]));
  return [f.k !== undefined && `k=${f.k}`, f.timerA_counter !== undefined && f.timerA_counter !== '0' && `tA=${f.timerA_counter}`,
    f.mode, f.gie === 'false' && 'gie=0'].filter(Boolean).join(' ');
}

function outputs(list) {
  return list.map((o) => {
    if (typeof o === 'string') return o.replace(/^O/, '');
    const [tag, ...rs] = o, name = tag.replace(/^O/, '');
    return rs.length ? `${name} ${rs.map(fields).join(' | ')}` : name;
  }).join('; ');
}

function shorten(label) {
  if (!label.startsWith('((')) return null;
  const e = parse(label);
  if (!Array.isArray(e) || e.length < 2) return null;
  try {
    const out = Array.isArray(e[1]) ? e[1][0] : e[1];
    return `${input(e[0])} / ${Array.isArray(out) ? outputs(out) : out}`;
  } catch { return null; }
}

export function shortLabels(dot) {
  return dot.replace(/label="((?:[^"\\]|\\.)*)"/g, (whole, label) => {
    const s = shorten(label.replace(/\\"/g, '"'));
    return s === null ? whole : `label="${s.replace(/"/g, '\\"')}"`;
  });
}
