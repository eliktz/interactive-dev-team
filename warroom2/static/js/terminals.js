// warroom2/static/js/terminals.js — mount xterm for PTY agents and a chat UI for Yefet.
(function () {
  'use strict';

  var GH_DARK_THEME = {
    background: '#0d1117',
    foreground: '#c9d1d9',
    cursor: '#58a6ff',
    cursorAccent: '#0d1117',
    selectionBackground: '#3392ff44',
    black: '#484f58',
    red: '#ff7b72',
    green: '#7ee787',
    yellow: '#d29922',
    blue: '#58a6ff',
    magenta: '#bc8cff',
    cyan: '#39c5cf',
    white: '#c9d1d9',
    brightBlack: '#6e7681',
    brightRed: '#ffa198',
    brightGreen: '#56d364',
    brightYellow: '#e3b341',
    brightBlue: '#79c0ff',
    brightMagenta: '#d2a8ff',
    brightCyan: '#56d4dd',
    brightWhite: '#f0f6fc',
  };

  function wsUrlFor(agentId) {
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return proto + '//' + location.host + '/ws/agent/' + encodeURIComponent(agentId);
  }

  // Re-fit a terminal across a few frames/ms after it (re)gains a visible box.
  // A terminal created in a hidden tab has no xterm cell metrics yet, so the
  // FIRST fit on show reads stale metrics and sticks at 80x24 (measured: an
  // immediate fit returns 80, a fit ~60ms later returns the correct size). One
  // fit isn't enough — we retry until layout + metrics have settled. Each fit
  // is idempotent and, when it changes cols/rows, term.onResize propagates the
  // new geometry to tmux via the WS resize frame.
  function fitSoon(session) {
    if (!session || !session.fit || !session.term) return;
    var doFit = function () {
      var host = session.term.element ? session.term.element.parentElement : null;
      if (host && host.clientWidth > 0 && host.clientHeight > 0) {
        try { session.fit.fit(); } catch (e) {}
        // Force a full repaint after fitting. A terminal that mounted while
        // hidden (or whose render loop stalled) can have a correct buffer that
        // never painted; refresh() guarantees the visible rows are drawn.
        try { session.term.refresh(0, session.term.rows - 1); } catch (e) {}
      }
    };
    window.requestAnimationFrame(doFit);
    setTimeout(doFit, 60);
    setTimeout(doFit, 200);
  }
  window.WRFitSoon = fitSoon;

  function mountTerminal(agentId, hostDiv) {
    if (!window.Terminal) {
      hostDiv.textContent = '[xterm.js not loaded]';
      return null;
    }
    var fontMono = getComputedStyle(document.documentElement).getPropertyValue('--font-mono') || 'monospace';
    var term = new window.Terminal({
      fontFamily: fontMono.replace(/^\s+|\s+$/g, '') || 'monospace',
      fontSize: 14,
      lineHeight: 1.3,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 5000,
      theme: GH_DARK_THEME,
      convertEol: true,
    });

    var fit = null;
    if (window.FitAddon && window.FitAddon.FitAddon) {
      fit = new window.FitAddon.FitAddon();
      term.loadAddon(fit);
    }

    term.open(hostDiv);
    try { if (fit) fit.fit(); } catch (e) {}

    var ws = new window.WSClient({
      agentId: agentId,
      url: wsUrlFor(agentId),
      onOpen: function () {
        if (window.WRTabs) window.WRTabs.setTabStatus(agentId, 'connected');
        // Send initial resize so backend knows our viewport.
        try {
          var cols = term.cols, rows = term.rows;
          ws.send({ type: 'resize', cols: cols, rows: rows });
        } catch (e) {}
        // Focused-streaming: tell the backend whether this agent is the one the
        // user is viewing. Unfocused agents are paused server-side so a busy
        // multi-agent squad only streams ONE terminal to the browser, keeping the
        // single main thread free for keystrokes. (activeTabId is set by the
        // initial switchTo before this async onOpen fires.)
        try {
          var isActive = window.WR2 && window.WR2.activeTabId === agentId;
          ws.send({ type: 'focus', active: !!isActive });
        } catch (e) {}
      },
      onClose: function () {
        if (window.WRTabs) window.WRTabs.setTabStatus(agentId, 'disconnected');
      },
      onFrame: function (frame) {
        if (!frame) return;
        if (frame.type === 'data' && typeof frame.data === 'string') {
          var decoded;
          try { decoded = window.WRBase64Decode(frame.data); }
          catch (e) { decoded = frame.data; }
          term.write(decoded);
          stashScrollback(agentId, decoded);
          if (window.WR2.activeTabId !== agentId) {
            window.WR2.markUnread(agentId, true);
          }
        } else if (frame.type === 'raw' && typeof frame.data === 'string') {
          term.write(frame.data);
          stashScrollback(agentId, frame.data);
        } else if (frame.type === 'title' && frame.title) {
          // optional: update tab name later
        } else if (frame.type === 'scrollback' && Array.isArray(frame.lines)) {
          frame.lines.forEach(function (l) { term.write(l); stashScrollback(agentId, l); });
        }
      },
    });
    ws.connect();

    // Forward keystrokes to the backend (base64-encoded so UTF-8 / control chars survive).
    term.onData(function (d) {
      ws.send({ type: 'input', data: window.WRBase64Encode(d) });
    });

    // Debounce + dedupe the resize frame. fitSoon fires three refits per
    // trigger and is wired to a ResizeObserver, so a single settled geometry
    // can emit a burst of identical/near-identical onResize callbacks. Each
    // frame costs a backend `docker exec stty` (~130ms), which on a high-RTT
    // remote link floods the shared executor and starves keystroke writes
    // (perceived ~30s/letter). A 150ms trailing debounce collapses the burst
    // into at most one frame per settled geometry; the dedupe drops frames
    // whose cols×rows match the last one actually sent. NOTE: the INITIAL
    // resize lives in the WS onOpen handler above and is intentionally NOT
    // routed through here — it must fire immediately so the backend learns the
    // viewport on connect.
    var lastSentCols = -1, lastSentRows = -1;
    var sendResizeDebounced = window.WRDebounce(function (cols, rows) {
      if (cols === lastSentCols && rows === lastSentRows) return;
      lastSentCols = cols;
      lastSentRows = rows;
      ws.send({ type: 'resize', cols: cols, rows: rows });
    }, 150);
    term.onResize(function (sz) {
      sendResizeDebounced(sz.cols, sz.rows);
    });

    // OSC 52 copy: on selection change, copy via terminal-side OSC 52 escape and stash for modal.
    term.onSelectionChange(function () {
      try {
        var sel = term.getSelection();
        if (sel && sel.length > 0) {
          window.WR2.lastCopy = sel;
          var b64 = window.WRBase64Encode(sel);
          term.write('\x1b]52;c;' + b64 + '\x07');
          // Best-effort: also try the browser clipboard API.
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(sel).catch(function () {});
          }
        }
      } catch (e) {}
    });

    // Resize on window resize.
    var debouncedFit = window.WRDebounce(function () {
      if (fit) try { fit.fit(); } catch (e) {}
    }, 120);
    window.addEventListener('resize', debouncedFit);

    var session = {
      ws: ws,
      term: term,
      fit: fit,
      scrollback: [],
    };
    window.WR2.sessions[agentId] = session;

    // Robustly re-fit whenever the host element gains or changes a non-zero
    // size. A synchronous fit() right after un-hiding a tab measures the
    // pre-reflow (often zero/default) size, leaving the PTY stuck at 80x24
    // while the browser renders a different geometry — garbled output plus
    // redraw churn (worse on slow/remote connections). ResizeObserver fires
    // after layout for every such case (tab show, panel collapse, window
    // resize, DPR change); term.onResize then propagates the new geometry to
    // tmux via the WS resize frame.
    if (window.ResizeObserver && fit) {
      session.ro = new ResizeObserver(function () {
        if (hostDiv.clientWidth > 0 && hostDiv.clientHeight > 0) {
          fitSoon(session);
        }
      });
      session.ro.observe(hostDiv);
    }
    // First fit after the element is laid out (covers the tab active at load).
    fitSoon(session);

    // Pull initial scrollback from REST and write it before live tail catches up.
    window.WRFetchJSON('/api/agents/' + encodeURIComponent(agentId) + '/scrollback?limit=200')
      .then(function (data) {
        if (!data) return;
        var lines = data.lines || data.scrollback || [];
        lines.forEach(function (line) {
          term.write(line);
          stashScrollback(agentId, line);
        });
      })
      .catch(function () { /* non-fatal */ });

    return session;
  }

  function stashScrollback(agentId, chunk) {
    var s = window.WR2.sessions[agentId];
    if (!s) return;
    s.scrollback.push(chunk);
    // cap to keep memory bounded
    if (s.scrollback.length > 5000) s.scrollback.splice(0, s.scrollback.length - 5000);
  }

  function mountYefetChat(agentId, hostDiv) {
    hostDiv.innerHTML = '';
    var wrap = document.createElement('div');
    wrap.className = 'yefet-chat';
    var log = document.createElement('div');
    log.className = 'yefet-log';
    wrap.appendChild(log);
    var inputRow = document.createElement('div');
    inputRow.className = 'yefet-input';
    var input = document.createElement('input');
    input.type = 'text';
    input.placeholder = 'Message Yefet…';
    var sendBtn = document.createElement('button');
    sendBtn.textContent = 'Send';
    inputRow.appendChild(input);
    inputRow.appendChild(sendBtn);
    wrap.appendChild(inputRow);
    hostDiv.appendChild(wrap);

    function appendMsg(msg) {
      var div = document.createElement('div');
      var from = msg.from || 'yefet';
      var who = (from === 'operator' || from === 'user') ? 'from-operator'
              : (from === 'yefet') ? 'from-yefet'
              : 'from-system';
      div.className = 'yefet-msg ' + who;
      var meta = document.createElement('div');
      meta.className = 'meta';
      var ts = msg.ts ? new Date(msg.ts).toLocaleTimeString() : '';
      meta.textContent = (from || '') + (msg.to ? ' → ' + msg.to : '') + (ts ? ' · ' + ts : '');
      div.appendChild(meta);
      var body = document.createElement('div');
      body.textContent = msg.text || msg.body || msg.data || '';
      div.appendChild(body);
      log.appendChild(div);
      // auto-scroll
      log.scrollTop = log.scrollHeight;
      stashScrollback(agentId, (msg.from || '') + ': ' + (msg.text || '') + '\n');
    }

    async function doSend() {
      var text = input.value;
      if (!text || !text.trim()) return;
      sendBtn.disabled = true;
      try {
        var res = await window.WRFetch('/api/agents/' + encodeURIComponent(agentId) + '/send-message', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: text }),
        });
        if (!res.ok) {
          appendMsg({ from: 'system', text: '[send failed: HTTP ' + res.status + ']', ts: Date.now() });
        } else {
          appendMsg({ from: 'operator', to: agentId, text: text, ts: Date.now() });
          input.value = '';
        }
      } catch (e) {
        appendMsg({ from: 'system', text: '[send error: ' + (e.message || e) + ']', ts: Date.now() });
      } finally {
        sendBtn.disabled = false;
        input.focus();
      }
    }

    sendBtn.addEventListener('click', doSend);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        doSend();
      }
    });

    var ws = new window.WSClient({
      agentId: agentId,
      url: wsUrlFor(agentId),
      onOpen: function () {
        if (window.WRTabs) window.WRTabs.setTabStatus(agentId, 'connected');
      },
      onClose: function () {
        if (window.WRTabs) window.WRTabs.setTabStatus(agentId, 'disconnected');
      },
      onFrame: function (frame) {
        if (!frame) return;
        if (frame.type === 'bus' || frame.type === 'message') {
          appendMsg({
            from: frame.from || 'yefet',
            to: frame.to,
            text: frame.text || frame.body || '',
            ts: frame.ts || Date.now(),
          });
          if (window.WR2.activeTabId !== agentId) {
            window.WR2.markUnread(agentId, true);
          }
        } else if (frame.type === 'scrollback' && Array.isArray(frame.messages)) {
          frame.messages.forEach(appendMsg);
        }
      },
    });
    ws.connect();

    var session = { ws: ws, scrollback: [], log: log, input: input };
    window.WR2.sessions[agentId] = session;

    // Initial scrollback pull.
    window.WRFetchJSON('/api/agents/' + encodeURIComponent(agentId) + '/scrollback?limit=200')
      .then(function (data) {
        if (!data) return;
        var msgs = data.messages || data.lines || data.scrollback || [];
        msgs.forEach(function (m) {
          if (typeof m === 'string') appendMsg({ from: 'yefet', text: m, ts: Date.now() });
          else appendMsg(m);
        });
      })
      .catch(function () { /* non-fatal */ });

    return session;
  }

  window.WRTerm = {
    mountTerminal: mountTerminal,
    mountYefetChat: mountYefetChat,
  };
})();
