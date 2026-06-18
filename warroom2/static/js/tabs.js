// warroom2/static/js/tabs.js — render agent tabs and handle switching.
(function () {
  'use strict';

  function renderTabs(agents) {
    var bar = document.getElementById('tab-bar');
    if (!bar) return;
    bar.innerHTML = '';
    agents.forEach(function (agent, idx) {
      var tab = document.createElement('div');
      tab.className = 'tab idle';
      tab.dataset.agentId = agent.id;
      tab.style.borderTopColor = agent.color || 'transparent';

      var dot = document.createElement('span');
      dot.className = 'tab-dot';
      tab.appendChild(dot);

      var name = document.createElement('span');
      name.className = 'tab-name';
      name.textContent = agent.display_name || agent.name || agent.id;
      tab.appendChild(name);

      var model = document.createElement('span');
      model.className = 'tab-model';
      model.textContent = agent.model || '';
      tab.appendChild(model);

      var copy = document.createElement('button');
      copy.className = 'tab-copy';
      copy.textContent = 'Copy';
      copy.title = 'Copy scrollback to clipboard';
      copy.addEventListener('click', function (e) {
        e.stopPropagation();
        openCopyForAgent(agent.id);
      });
      tab.appendChild(copy);

      tab.addEventListener('click', function () { switchTo(agent.id); });

      bar.appendChild(tab);
    });
  }

  function switchTo(id) {
    var bar = document.getElementById('tab-bar');
    if (!bar) return;
    var tabs = bar.querySelectorAll('.tab');
    tabs.forEach(function (t) {
      t.classList.toggle('active', t.dataset.agentId === id);
      if (t.dataset.agentId === id) t.classList.remove('unread');
    });
    var content = document.getElementById('tab-content');
    if (content) {
      var panes = content.querySelectorAll('.tab-pane');
      panes.forEach(function (p) {
        p.classList.toggle('active', p.dataset.agentId === id);
      });
    }
    window.WR2.setActive(id);

    // Flush any output buffered while this tab was hidden (active-only
    // rendering): hidden terminals don't write to xterm live, so replay the
    // buffer now that it's visible, before fitting.
    var sess = window.WR2.sessions[id];
    if (sess && typeof sess.flush === 'function') {
      try { sess.flush(); } catch (e) {}
    }

    // Resize xterm to fit the now-visible pane. Deferred to the next frame so
    // the browser lays out the just-un-hidden pane before we measure it — a
    // synchronous fit() here reads the pre-reflow size and leaves the terminal
    // at the wrong geometry. (The per-terminal ResizeObserver also covers this;
    // this is a fast-path for the common tab-switch.)
    if (sess && sess.fit) {
      if (window.WRFitSoon) window.WRFitSoon(sess);
      else window.requestAnimationFrame(function () { try { sess.fit.fit(); } catch (e) {} });
    }
  }

  function setTabStatus(id, status) {
    var tab = document.querySelector('#tab-bar .tab[data-agent-id="' + cssEscape(id) + '"]');
    if (!tab) return;
    tab.classList.remove('connected', 'disconnected', 'idle');
    tab.classList.add(status);
  }

  function cssEscape(s) {
    if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
    return String(s).replace(/[^a-zA-Z0-9_-]/g, '_');
  }

  function markTabUnread(id, on) {
    var tab = document.querySelector('#tab-bar .tab[data-agent-id="' + cssEscape(id) + '"]');
    if (!tab) return;
    tab.classList.toggle('unread', !!on);
  }

  function openCopyForAgent(id) {
    var sess = window.WR2.sessions[id];
    var text = '';
    if (sess && sess.scrollback && sess.scrollback.length) {
      text = sess.scrollback.join('');
    } else if (sess && sess.term && sess.term.buffer) {
      try {
        var buf = sess.term.buffer.active;
        var lines = [];
        for (var i = 0; i < buf.length; i++) {
          var line = buf.getLine(i);
          if (line) lines.push(line.translateToString(true));
        }
        text = lines.join('\n');
      } catch (e) { text = window.WR2.lastCopy || ''; }
    } else {
      text = window.WR2.lastCopy || '';
    }
    if (window.showCopyModal) window.showCopyModal(text);
  }

  function bindKeyboard() {
    document.addEventListener('keydown', function (e) {
      if (!(e.metaKey || e.ctrlKey)) return;
      var n = parseInt(e.key, 10);
      if (isNaN(n) || n < 1 || n > 9) return;
      var agents = window.WR2.agents || [];
      var agent = agents[n - 1];
      if (!agent) return;
      e.preventDefault();
      switchTo(agent.id);
    });
  }

  // React to state changes from elsewhere.
  window.addEventListener('wr2:unread-changed', function (ev) {
    markTabUnread(ev.detail.id, ev.detail.on);
  });

  window.WRTabs = {
    renderTabs: renderTabs,
    switchTo: switchTo,
    setTabStatus: setTabStatus,
    markTabUnread: markTabUnread,
    bindKeyboard: bindKeyboard,
    openCopyForAgent: openCopyForAgent,
  };
})();
