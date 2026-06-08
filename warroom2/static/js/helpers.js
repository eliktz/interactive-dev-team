// warroom2/static/js/helpers.js — utility shims (fetch wrapper, debounce, base64 utf-8).
(function () {
  'use strict';

  function authHeader() {
    var creds = (window.WR2 && window.WR2.basicAuthCreds) || null;
    if (creds) return 'Basic ' + creds;
    return null;
  }

  // Fetch wrapper: attaches Basic Authorization if WR2.basicAuthCreds is set.
  // Returns the raw Response object (callers decide whether to .json/.text).
  window.WRFetch = async function (url, opts) {
    opts = opts || {};
    opts.headers = opts.headers || {};
    var auth = authHeader();
    if (auth && !opts.headers['Authorization']) opts.headers['Authorization'] = auth;
    // Default: include credentials so any cookie path also works.
    if (opts.credentials === undefined) opts.credentials = 'include';
    return fetch(url, opts);
  };

  // Convenience: fetch and parse JSON, raising on non-2xx with status code.
  window.WRFetchJSON = async function (url, opts) {
    var res = await window.WRFetch(url, opts);
    if (!res.ok) {
      var err = new Error('HTTP ' + res.status + ' for ' + url);
      err.status = res.status;
      err.response = res;
      throw err;
    }
    var text = await res.text();
    return window.WRSafeParse(text);
  };

  // Debounce: returns a wrapped function that delays invocation by `wait` ms.
  window.WRDebounce = function (fn, wait) {
    var t = null;
    return function () {
      var ctx = this;
      var args = arguments;
      if (t) clearTimeout(t);
      t = setTimeout(function () { fn.apply(ctx, args); }, wait);
    };
  };

  // Safe JSON parse: returns null on parse error rather than throwing.
  window.WRSafeParse = function (text) {
    if (text === undefined || text === null || text === '') return null;
    try { return JSON.parse(text); } catch (e) { return null; }
  };

  // base64 encode/decode that handle UTF-8 via TextEncoder/TextDecoder.
  window.WRBase64Encode = function (str) {
    if (typeof str !== 'string') str = String(str);
    var enc = new TextEncoder();
    var bytes = enc.encode(str);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return window.btoa(bin);
  };

  window.WRBase64Decode = function (b64) {
    var bin = window.atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    var dec = new TextDecoder();
    return dec.decode(bytes);
  };

  // Tiny element creator.
  window.WREl = function (tag, attrs, children) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'class') el.className = attrs[k];
        else if (k === 'style' && typeof attrs[k] === 'object') {
          Object.assign(el.style, attrs[k]);
        } else if (k.indexOf('on') === 0 && typeof attrs[k] === 'function') {
          el.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
        } else if (k === 'text') {
          el.textContent = attrs[k];
        } else {
          el.setAttribute(k, attrs[k]);
        }
      });
    }
    if (children) {
      (Array.isArray(children) ? children : [children]).forEach(function (c) {
        if (c == null) return;
        el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
      });
    }
    return el;
  };

  window.WREscape = function (s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  };
})();
