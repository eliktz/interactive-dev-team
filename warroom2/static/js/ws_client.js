// warroom2/static/js/ws_client.js — per-agent WebSocket with reconnect and ack flow-control.
(function () {
  'use strict';

  var ACK_THRESHOLD_BYTES = 4096;
  // Liveness heartbeat: sent on an interval REGARDLESS of focus/output so the
  // server can tell an alive-but-quiet tab (e.g. a paused/backgrounded agent)
  // from a half-open WS left by a tunnel drop. The server's periodic sweep
  // reaps tmux client-sessions whose heartbeat has gone stale — this is what
  // stops orphaned `<base>-cli-*` clients from accumulating and corrupting
  // window geometry between warroom2 restarts.
  var HEARTBEAT_MS = 20000;

  function jitter(ms) { return ms * (0.7 + Math.random() * 0.6); }

  function WSClient(opts) {
    this.agentId = opts.agentId;
    this.url = opts.url;
    this.onFrame = opts.onFrame || function () {};
    this.onOpen = opts.onOpen || function () {};
    this.onClose = opts.onClose || function () {};
    this.onError = opts.onError || function () {};
    this.basicCreds = opts.basicCreds || null;

    this._ws = null;
    this._backoff = 1000;
    this._maxBackoff = 30000;
    this._reconnectTimer = null;
    this._closedByUser = false;
    this._bytesSinceAck = 0;
    this._seq = 0;
    this._hbTimer = null;
  }

  WSClient.prototype.connect = function () {
    var self = this;
    if (this._ws) {
      try { this._ws.close(); } catch (e) {}
    }
    var url = this.url;
    // Browsers ignore Sec-WebSocket-Protocol for Basic auth; rely on cookies/IP allowlist.
    try {
      this._ws = new WebSocket(url);
    } catch (e) {
      this.onError(e);
      this._scheduleReconnect();
      return;
    }
    this._ws.binaryType = 'arraybuffer';

    this._ws.onopen = function () {
      self._backoff = 1000;
      self._bytesSinceAck = 0;
      self._startHeartbeat();
      self.onOpen();
    };

    this._ws.onmessage = function (ev) {
      var data = ev.data;
      var len = 0;
      var frame = null;
      if (typeof data === 'string') {
        len = data.length;
        frame = window.WRSafeParse(data);
        if (!frame) frame = { type: 'raw', data: data };
      } else if (data instanceof ArrayBuffer) {
        len = data.byteLength;
        frame = { type: 'binary', data: data };
      }
      self._bytesSinceAck += len;
      try {
        self.onFrame(frame);
      } catch (e) {
        if (window.console) console.error('[ws_client] onFrame error', e);
      }
      if (self._bytesSinceAck >= ACK_THRESHOLD_BYTES) {
        self._seq += 1;
        self._safeSend({ type: 'ack', seq: self._seq, bytes: self._bytesSinceAck });
        self._bytesSinceAck = 0;
      }
    };

    this._ws.onerror = function (ev) {
      self.onError(ev);
    };

    this._ws.onclose = function (ev) {
      self._stopHeartbeat();
      self.onClose(ev);
      if (!self._closedByUser) self._scheduleReconnect();
    };
  };

  WSClient.prototype._startHeartbeat = function () {
    var self = this;
    this._stopHeartbeat();
    this._hbTimer = setInterval(function () {
      self._safeSend({ type: 'hb' });
    }, HEARTBEAT_MS);
  };

  WSClient.prototype._stopHeartbeat = function () {
    if (this._hbTimer) {
      clearInterval(this._hbTimer);
      this._hbTimer = null;
    }
  };

  WSClient.prototype._scheduleReconnect = function () {
    var self = this;
    if (this._reconnectTimer) return;
    var wait = jitter(this._backoff);
    this._reconnectTimer = setTimeout(function () {
      self._reconnectTimer = null;
      self._backoff = Math.min(self._maxBackoff, self._backoff * 2);
      self.connect();
    }, wait);
  };

  WSClient.prototype._safeSend = function (obj) {
    if (!this._ws || this._ws.readyState !== WebSocket.OPEN) return false;
    try {
      this._ws.send(typeof obj === 'string' ? obj : JSON.stringify(obj));
      return true;
    } catch (e) {
      return false;
    }
  };

  WSClient.prototype.send = function (obj) {
    return this._safeSend(obj);
  };

  WSClient.prototype.close = function () {
    this._closedByUser = true;
    this._stopHeartbeat();
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    if (this._ws) {
      try { this._ws.close(); } catch (e) {}
    }
  };

  WSClient.prototype.isOpen = function () {
    return !!this._ws && this._ws.readyState === WebSocket.OPEN;
  };

  window.WSClient = WSClient;
})();
