// warroom2/static/js/company.js — render THIS squad's COMPANY.md into #company-section.
// No markdown renderer is bundled, so the raw markdown is shown in a <pre>
// (same approach the file browser uses for file content). Fail-soft: a 404
// means the squad has no company package.
(function () {
  'use strict';

  var loaded = false;

  function mount() {
    var host = document.getElementById('company-section');
    if (!host) return;
    host.innerHTML = '';

    var header = document.createElement('div');
    header.id = 'company-header';
    header.style.fontSize = '11px';
    header.style.color = 'var(--fg-muted)';
    header.style.marginBottom = '6px';
    header.textContent = 'Loading…';
    host.appendChild(header);

    var content = document.createElement('pre');
    content.id = 'company-content';
    host.appendChild(content);

    load();
  }

  async function load() {
    var header = document.getElementById('company-header');
    var content = document.getElementById('company-content');
    if (!header || !content) return;
    try {
      var res = await window.WRFetch('/api/company');
      if (res.status === 404) {
        header.textContent = 'No company package for this squad.';
        content.textContent = '';
        return;
      }
      if (!res.ok) {
        header.textContent = 'Failed to load company (HTTP ' + res.status + ')';
        content.textContent = '';
        return;
      }
      var text = await res.text();
      var data = window.WRSafeParse(text);
      if (data && typeof data.content === 'string') {
        content.textContent = data.content;
        header.textContent = 'COMPANY.md' +
          (data.slug ? ' — ' + data.slug : '') +
          (data.redacted ? ' (redacted)' : '') +
          (data.truncated ? ' (truncated)' : '');
      } else {
        content.textContent = text;
        header.textContent = 'COMPANY.md';
      }
      loaded = true;
    } catch (e) {
      header.textContent = 'Error: ' + (e.message || 'failed');
      content.textContent = '';
    }
  }

  window.WRCompany = { mount: mount };
})();
