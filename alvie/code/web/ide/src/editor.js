// The editor of the IDE (CodeMirror 6): one file at a time, saved to the files of the IDE as it changes, with the
// highlighting of its language and, when given, a linter (see check.js)
import { EditorState, Compartment } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { syntaxHighlighting, defaultHighlightStyle, bracketMatching, indentOnInput } from '@codemirror/language';
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { lintGutter } from '@codemirror/lint';
import { languageOf } from './languages.js';

export class Editor {
  constructor(element, { files, onStatus, linterFor }) {
    Object.assign(this, { files, onStatus, linterFor });
    this.path = null; this.timer = null;
    this.language = new Compartment(); this.lint = new Compartment(); this.readOnly = new Compartment();
    this.view = new EditorView({
      parent: element,
      state: this.state(''),
    });
    files.onChange((path) => {
      // A command changed the open file: show its new text, unless it is being edited
      if (this.path && (path === undefined || path === this.path) && this.files.has(this.path) && !this.timer) {
        const text = this.files.read(this.path);
        if (text !== this.view.state.doc.toString()) this.view.dispatch({ changes: { from: 0, to: this.view.state.doc.length, insert: text } });
      }
    });
  }

  state(text) {
    return EditorState.create({
      doc: text,
      extensions: [
        lineNumbers(), history(), drawSelection(), highlightActiveLine(), bracketMatching(), indentOnInput(),
        highlightSelectionMatches(), syntaxHighlighting(defaultHighlightStyle), lintGutter(),
        keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, indentWithTab]),
        this.language.of([]), this.lint.of([]), this.readOnly.of(EditorState.readOnly.of(true)),
        EditorView.updateListener.of((u) => { if (u.docChanged && this.path) this.scheduleSave(); }),
      ],
    });
  }

  open(path) {
    if (!this.files.has(path)) this.files.write(path, '');
    this.flush();
    this.path = path;
    this.view.setState(this.state(this.files.read(path)));
    const lang = languageOf(path);
    this.view.dispatch({ effects: [
      this.language.reconfigure(lang ? [lang] : []),
      this.lint.reconfigure(this.linterFor ? this.linterFor(path) : []),
      this.readOnly.reconfigure(EditorState.readOnly.of(false)),
    ] });
    this.onStatus(path, 'saved');
  }

  scheduleSave() {
    clearTimeout(this.timer);
    this.onStatus(this.path, 'editing');
    this.timer = setTimeout(() => this.flush(), 400);
  }

  flush() {
    if (this.timer && this.path) {
      clearTimeout(this.timer); this.timer = null;
      this.files.write(this.path, this.view.state.doc.toString());
      this.onStatus(this.path, 'saved');
    }
  }
}
