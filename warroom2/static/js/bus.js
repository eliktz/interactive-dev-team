// warroom2/static/js/bus.js — live tail of the agent-bus via SSE into #bus-section.
(function () {
  'use strict';

  var MAX_EVENTS = 200;
  var events = [];
  var autoScroll = true;

  function mount() {
    var host = document.getElementById('bus-section');
    if (!host) return;
    host.innerHTML = '';

    var info = document.createElement('div');
    info.style.fontSize = '11px';
    info.style.color = 'var(--fg-muted)';
    info.style.marginBottom = '6px';
    info.id = 'bus-status';
    info.textContent = 'Connecting…';
    host.appendChild(info);

    var log = document.createElement('div');
    log.id = 'bus-log';
    log.addEventListener('scroll', function () {
      var nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
      autoScroll = nearBottom;
    });
    host.appendChild(log);

    connectSSE();
  }

  function connectSSE() {
    if (window.WR2.sseSource) {
      try { window.WR2.sseSource.close(); } catch (e) {}
    }
    var url = '/api/events';
    // EventSource doesn't allow setting an Authorization header. If we have Basic
    // creds in memory, embed user:pass into the URL as a best-effort fallback.
    // Cookie-based auth (if backend uses sessions) Just Works because EventSource
    // includes cookies on same-origin by default.
    if (window.WR2.basicAuthCreds) {
      try {
        var decoded = window.atob(window.WR2.basicAuthCreds);
        var parts = decoded.split(':');
        var u = encodeURIComponent(parts[0] || '');
        var p = encodeURIComponent(parts.slice(1).join(':') || '');
        // Documented gap: URL userinfo is widely deprecated. We still try the query-string
        // fallback so a server-side handler can opt in if it wants to support it.
        url += (url.indexOf('?') === -1 ? '?' : '&') + 'u=' + u + '&p=' + p;
      } catch (e) {}
    }

    var src;
    try {
      src = new EventSource(url, { withCredentials: true });
    } catch (e) {
      setStatus('SSE unavailable: ' + (e.message || e));
      return;
    }
    window.WR2.sseSource = src;

    src.onopen = function () { setStatus('Connected'); };
    src.onerror = function () { setStatus('Disconnected (auto-reconnecting)'); };
    src.onmessage = function (ev) { handleEvent(ev.data); };
    // Custom-named events the backend may emit:
    ['bus', 'agent', 'tmux', 'health'].forEach(function (name) {
      src.addEventListener(name, function (ev) { handleEvent(ev.data, name); });
    });
  }

  function setStatus(s) {
    var info = document.getElementById('bus-status');
    if (info) info.textContent = s;
  }

  function handleEvent(raw, kind) {
    var parsed = window.WRSafeParse(raw);
    if (!parsed) parsed = { body: raw };
    parsed._kind = kind || parsed.type || 'event';
    pushEvent(parsed);
  }

  function pushEvent(ev) {
    events.push(ev);
    if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS);
    appendDom(ev);
  }

  function appendDom(ev) {
    var log = document.getElementById('bus-log');
    if (!log) return;
    var div = document.createElement('div');
    div.className = 'bus-event';
    var ts = ev.ts || ev.timestamp || Date.now();
    try { ts = new Date(ts).toLocaleTimeString(); } catch (e) {}
    var head = document.createElement('span');
    head.innerHTML = '<span class="ts">' + window.WREscape(String(ts)) + '</span>' +
      (ev.from ? '<span class="from">' + window.WREscape(ev.from) + '</span>' : '') +
      (ev.to ? ' → <span class="to">' + window.WREscape(ev.to) + '</span>' : '') +
      (ev._kind ? ' <span style="color:var(--fg-muted)">[' + window.WREscape(ev._kind) + ']</span>' : '');
    div.appendChild(head);
    var body = document.createElement('span');
    body.className = 'body';
    body.textContent = ev.text || ev.body || ev.message || JSON.stringify(ev);
    div.appendChild(body);
    log.appendChild(div);
    // Trim DOM to bound.
    while (log.children.length > MAX_EVENTS) log.removeChild(log.firstChild);
    if (autoScroll) log.scrollTop = log.scrollHeight;
  }

  window.WRBus = { mount: mount };
})();
