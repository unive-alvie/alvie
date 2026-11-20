// The file tree of the IDE: folders open and close; a click opens a file in the editor, a double click on a model
// (.dot) draws it, and the selected file is the one that download saves.
export class Tree {
  constructor(element, { files, onOpen, onView }) {
    Object.assign(this, { element, files, onOpen, onView });
    this.open = new Set(JSON.parse(localStorage.getItem('alvie-ide-open') || '["/spec-lib", "/models"]'));
    this.selected = null;
    files.onChange(() => this.render());
  }

  select(path) { this.selected = path; this.render(); }

  render() {
    const ul = this.list('/');
    this.element.replaceChildren(ul);
  }

  list(dir) {
    const ul = document.createElement('ul');
    for (const [name, isDir] of this.files.list(dir)) {
      if (name === '.keep') continue;
      const path = dir === '/' ? `/${name}` : `${dir}/${name}`;
      const li = document.createElement('li');
      const row = document.createElement('div');
      row.className = `row ${isDir ? 'dir' : 'file'}${path === this.selected ? ' selected' : ''}`;
      row.textContent = isDir ? `${this.open.has(path) ? '▾' : '▸'} ${name}` : name;
      row.title = path;
      row.addEventListener('click', () => {
        if (isDir) {
          if (this.open.has(path)) this.open.delete(path); else this.open.add(path);
          try { localStorage.setItem('alvie-ide-open', JSON.stringify([...this.open])); } catch {}
          this.render();
        } else { this.selected = path; this.onOpen(path); this.render(); }
      });
      if (!isDir && path.endsWith('.dot')) row.addEventListener('dblclick', () => this.onView([path]));
      li.append(row);
      if (isDir && this.open.has(path)) li.append(this.list(path));
      ul.append(li);
    }
    return ul;
  }
}
