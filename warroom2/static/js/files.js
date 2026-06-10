// warroom2/static/js/files.js — read-only file browser for #files-section.
(function () {
  'use strict';

  var ROOTS = ['/workspace/agents', '/workspace/project', '/workspace/agent-bus'];
  var currentRoot = ROOTS[0];

  function mount() {
    var host = document.getElementById('files-section');
    if (!host) return;
    host.innerHTML = '';

    var roots = document.createElement('div');
    roots.className = 'file-roots';
    ROOTS.forEach(function (r) {
      var b = document.createElement('button');
      b.textContent = r.replace('/workspace/', '');
      b.dataset.root = r;
      if (r === currentRoot) b.classList.add('active');
      b.addEventListener('click', function () {
        currentRoot = r;
        Array.prototype.forEach.call(roots.querySelectorAll('button'), function (x) {
          x.classList.toggle('active', x.dataset.root === r);
        });
        renderTree();
      });
      roots.appendChild(b);
    });
    host.appendChild(roots);

    var tree = document.createElement('div');
    tree.className = 'file-tree';
    tree.id = 'file-tree';
    host.appendChild(tree);

    var contentHeader = document.createElement('div');
    contentHeader.id = 'file-content-header';
    host.appendChild(contentHeader);

    var content = document.createElement('pre');
    content.id = 'file-content';
    content.style.display = 'none';
    host.appendChild(content);

    renderTree();
  }

  async function renderTree() {
    var tree = document.getElementById('file-tree');
    if (!tree) return;
    await renderDirInto(tree, currentRoot, /*replace=*/ true);
  }

  async function renderDirInto(container, dirPath, replace) {
    if (replace) container.innerHTML = 'Loading…';
    var data;
    try {
      data = await window.WRFetchJSON('/api/files/tree?root=' + encodeURIComponent(dirPath));
    } catch (e) {
      var msg = 'Error: ' + (e.status ? 'HTTP ' + e.status : (e.message || 'failed'));
      if (replace) container.textContent = msg;
      else container.appendChild(document.createTextNode(msg));
      return;
    }
    if (replace) container.innerHTML = '';
    var entries = (data && Array.isArray(data.entries)) ? data.entries : [];
    if (replace) {
      var header = document.createElement('div');
      header.className = 'file-tree-root';
      header.textContent = data.root || dirPath;
      container.appendChild(header);
    }
    entries.forEach(function (entry) {
      container.appendChild(buildEntry(entry));
    });
  }

  function isDirEntry(entry) {
    if (typeof entry.is_dir === 'boolean') return entry.is_dir;
    var name = entry.name || '';
    if (name.endsWith('/')) return true;
    // Heuristic fallback: no dot in basename ⇒ probably a directory.
    return name.indexOf('.') === -1;
  }

  function buildEntry(entry) {
    if (!entry) return document.createTextNode('');
    var name = entry.name || entry.path || '(unnamed)';
    var path = entry.path || name;
    if (isDirEntry(entry)) {
      var details = document.createElement('details');
      var summary = document.createElement('summary');
      summary.textContent = name + '/';
      details.appendChild(summary);
      var childrenHost = document.createElement('div');
      childrenHost.className = 'file-children';
      details.appendChild(childrenHost);
      var loaded = false;
      details.addEventListener('toggle', function () {
        if (details.open && !loaded) {
          loaded = true;
          childrenHost.textContent = 'Loading…';
          renderDirInto(childrenHost, path, /*replace=*/ true);
        }
      });
      return details;
    }
    var div = document.createElement('div');
    div.className = 'file';
    div.textContent = name;
    div.title = path;
    div.addEventListener('click', function () { openFile(path); });
    return div;
  }

  async function openFile(path) {
    var header = document.getElementById('file-content-header');
    var content = document.getElementById('file-content');
    if (!content || !header) return;
    header.textContent = path + ' (loading…)';
    content.style.display = 'block';
    content.textContent = '';
    try {
      var res = await window.WRFetch('/api/files/content?path=' + encodeURIComponent(path));
      if (!res.ok) {
        header.textContent = path + ' (HTTP ' + res.status + ')';
        return;
      }
      var text = await res.text();
      var parsed = window.WRSafeParse(text);
      if (parsed && typeof parsed.content === 'string') {
        content.textContent = parsed.content;
        header.textContent = path + (parsed.redacted ? ' (redacted)' : '');
      } else {
        content.textContent = text;
        header.textContent = path;
      }
    } catch (e) {
      header.textContent = path + ' (' + (e.message || 'error') + ')';
    }
  }

  window.WRFiles = { mount: mount };
})();
