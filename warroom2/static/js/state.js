// warroom2/static/js/state.js — global state container.
(function () {
  'use strict';

  window.WR2 = window.WR2 || {
    agents: [],
    activeTabId: null,
    sessions: {},           // agentId -> { ws, term, fit, scrollback: [] }
    unread: {},             // agentId -> bool
    leftPanelSection: 'files',
    basicAuthCreds: null,   // base64("user:pass") or null
    lastCopy: '',           // last selected text — fallback for the copy modal
    sseSource: null,        // shared EventSource for bus log
  };

  window.WR2.setActive = function (id) {
    var prev = window.WR2.activeTabId;
    window.WR2.activeTabId = id;
    if (window.WR2.unread[id]) window.WR2.markUnread(id, false);
    var ev = new CustomEvent('wr2:active-changed', { detail: { id: id, prev: prev } });
    window.dispatchEvent(ev);
  };

  window.WR2.markUnread = function (id, on) {
    window.WR2.unread[id] = !!on;
    var ev = new CustomEvent('wr2:unread-changed', { detail: { id: id, on: !!on } });
    window.dispatchEvent(ev);
  };

  window.WR2.getAgent = function (id) {
    return (window.WR2.agents || []).find(function (a) { return a.id === id; });
  };
})();
