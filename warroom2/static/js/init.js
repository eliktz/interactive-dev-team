// warroom2/static/js/init.js — boot sequence.
(function () {
  'use strict';

  function buildAuthModal() {
    var modal = document.createElement('div');
    modal.id = 'auth-modal';
    modal.innerHTML =
      '<div class="card">' +
        '<h3>War Room 2.0 sign-in</h3>' +
        '<input id="auth-user" type="text" placeholder="username" autocomplete="username">' +
        '<input id="auth-pass" type="password" placeholder="password" autocomplete="current-password">' +
        '<button id="auth-submit">Sign in</button>' +
        '<div id="auth-err" class="err"></div>' +
      '</div>';
    document.body.appendChild(modal);
    return modal;
  }

  async function ensureAuth() {
    // Probe a cheap authed endpoint. If 200, no modal needed.
    try {
      var res = await window.WRFetch('/api/agents');
      if (res.ok) return true;
      if (res.status !== 401 && res.status !== 403) return true; // other errors: surface later
    } catch (e) { /* network error — still try modal */ }

    var modal = buildAuthModal();
    return new Promise(function (resolve) {
      var userInput = document.getElementById('auth-user');
      var passInput = document.getElementById('auth-pass');
      var btn = document.getElementById('auth-submit');
      var err = document.getElementById('auth-err');
      userInput.focus();

      async function submit() {
        var u = userInput.value;
        var p = passInput.value;
        if (!u || !p) { err.textContent = 'username + password required'; return; }
        window.WR2.basicAuthCreds = window.btoa(u + ':' + p);
        err.textContent = '';
        try {
          var res = await window.WRFetch('/api/agents');
          if (res.ok) {
            modal.remove();
            resolve(true);
            return;
          }
          window.WR2.basicAuthCreds = null;
          err.textContent = 'auth failed (HTTP ' + res.status + ')';
        } catch (e2) {
          window.WR2.basicAuthCreds = null;
          err.textContent = 'network error: ' + (e2.message || e2);
        }
      }

      btn.addEventListener('click', submit);
      passInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') submit();
      });
      userInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { passInput.focus(); }
      });
    });
  }

  async function fetchAgents() {
    try {
      var data = await window.WRFetchJSON('/api/agents');
      if (!data) return [];
      if (Array.isArray(data)) return data;
      if (Array.isArray(data.agents)) return data.agents;
      return [];
    } catch (e) {
      console.error('[init] /api/agents failed', e);
      return [];
    }
  }

  function ensureAgentDefaults(agents) {
    // Fallback registry if backend is empty — UI still renders.
    if (agents && agents.length) return agents;
    return [
      { id: 'captain', display_name: 'Captain', model: 'sonnet', color: '#7fd3ff', kind: 'pty' },
      { id: 'leo', display_name: 'Leo', model: 'opus', color: '#ffa657', kind: 'pty' },
      { id: 'iris', display_name: 'Iris (Hedva)', model: 'sonnet', color: '#d2a8ff', kind: 'pty' },
      { id: 'yefet', display_name: 'Yefet', model: 'gpt-5.5', color: '#7ee787', kind: 'bus' },
    ];
  }

  function mountPanes(agents) {
    var content = document.getElementById('tab-content');
    if (!content) return;
    content.innerHTML = '';
    agents.forEach(function (agent) {
      var pane = document.createElement('div');
      pane.className = 'tab-pane';
      pane.dataset.agentId = agent.id;

      var host = document.createElement('div');
      host.className = (agent.id === 'yefet' || agent.kind === 'bus') ? 'yefet-chat-host' : 'terminal-host';
      pane.appendChild(host);
      content.appendChild(pane);

      if (agent.id === 'yefet' || agent.kind === 'bus') {
        window.WRTerm.mountYefetChat(agent.id, host);
      } else {
        window.WRTerm.mountTerminal(agent.id, host);
      }
    });
  }

  function bindAdminNav() {
    var nav = document.getElementById('admin-nav');
    if (!nav) return;
    var buttons = nav.querySelectorAll('button');
    buttons.forEach(function (b) {
      b.addEventListener('click', function () {
        var section = b.dataset.section;
        if (!section) return;
        buttons.forEach(function (x) { x.classList.toggle('active', x === b); });
        document.querySelectorAll('.admin-section').forEach(function (s) {
          s.classList.toggle('active', s.id === section + '-section');
        });
        window.WR2.leftPanelSection = section;
      });
    });
  }

  function bindDivider() {
    var divider = document.getElementById('pane-divider');
    var leftPanel = document.getElementById('left-panel');
    if (!divider || !leftPanel) return;
    var dragging = false;
    var startX = 0;
    var startW = 0;

    divider.addEventListener('mousedown', function (e) {
      dragging = true;
      startX = e.clientX;
      startW = leftPanel.getBoundingClientRect().width;
      document.body.style.cursor = 'col-resize';
      document.body.style.userSelect = 'none';
      e.preventDefault();
    });

    document.addEventListener('mousemove', function (e) {
      if (!dragging) return;
      var delta = e.clientX - startX;
      var w = Math.min(600, Math.max(200, startW + delta));
      leftPanel.style.width = w + 'px';
      // re-fit active terminal
      var id = window.WR2.activeTabId;
      var sess = id && window.WR2.sessions[id];
      if (sess && sess.fit) {
        try { sess.fit.fit(); } catch (e2) {}
      }
    });

    document.addEventListener('mouseup', function () {
      if (!dragging) return;
      dragging = false;
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    });
  }

  function bindCollapse() {
    var btn = document.getElementById('btn-collapse');
    var leftPanel = document.getElementById('left-panel');
    if (!btn || !leftPanel) return;
    var collapsed = false;
    var prevWidth = '';
    btn.addEventListener('click', function () {
      collapsed = !collapsed;
      if (collapsed) {
        prevWidth = leftPanel.style.width;
        leftPanel.style.width = '40px';
        leftPanel.style.minWidth = '40px';
        btn.textContent = '»';
      } else {
        leftPanel.style.width = prevWidth || '320px';
        leftPanel.style.minWidth = '200px';
        btn.textContent = '«';
      }
    });
  }

  function bindWizardButton() {
    var btn = document.getElementById('btn-mount-agent');
    if (!btn) return;
    btn.addEventListener('click', function () {
      if (window.WRWizard) window.WRWizard.open();
    });
  }

  function bindTipsFooter() {
    var toggle = document.getElementById('tips-toggle');
    var content = document.getElementById('tips-content');
    if (!toggle || !content) return;
    var open = true;
    toggle.addEventListener('click', function () {
      open = !open;
      content.style.display = open ? '' : 'none';
      toggle.innerHTML = open ? 'Tips &#9650;' : 'Tips &#9660;';
    });
  }

  async function mountHealth() {
    var host = document.getElementById('health-section');
    if (!host) return;
    host.innerHTML = '<div id="health-status"></div>';
    var status = document.getElementById('health-status');

    async function ping() {
      var rows = [];
      async function check(name, url) {
        try {
          var res = await window.WRFetch(url);
          rows.push({ name: name, ok: res.ok, status: res.status });
        } catch (e) {
          rows.push({ name: name, ok: false, status: 'err' });
        }
      }
      await check('agents', '/api/agents');
      await check('files', '/api/files/tree?root=/workspace/agents');
      await check('healthz', '/healthz');
      status.innerHTML = '';
      rows.forEach(function (r) {
        var div = document.createElement('div');
        div.className = 'row';
        var n = document.createElement('span');
        n.textContent = r.name;
        var v = document.createElement('span');
        v.textContent = r.ok ? 'OK (' + r.status + ')' : 'FAIL (' + r.status + ')';
        v.className = r.ok ? 'ok' : 'err';
        div.appendChild(n);
        div.appendChild(v);
        status.appendChild(div);
      });
    }
    ping();
    setInterval(ping, 15000);
  }

  async function boot() {
    if (window.WRCopyModal) window.WRCopyModal.bind();
    bindAdminNav();
    bindDivider();
    bindCollapse();
    bindTipsFooter();
    bindWizardButton();
    if (window.WRTabs) window.WRTabs.bindKeyboard();

    await ensureAuth();
    var agents = ensureAgentDefaults(await fetchAgents());
    window.WR2.agents = agents;
    if (window.WRTabs) window.WRTabs.renderTabs(agents);
    mountPanes(agents);
    if (agents.length) {
      if (window.WRTabs) window.WRTabs.switchTo(agents[0].id);
    }
    if (window.WRFiles) window.WRFiles.mount();
    if (window.WRBus) window.WRBus.mount();
    mountHealth();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
