// warroom2/static/js/wizard.js — mount-new-agent wizard modal.
//
// 4 steps: identity → telegram → persona → preview/apply.
// Talks to /api/admin/wizard/{getme,preview,apply,restart-warroom}.
// Requires both basic-auth (cookie/Authorization header inherited from page)
// AND an X-Admin-Token the operator pastes into the wizard header.
(function () {
  'use strict';

  var ADMIN_TOKEN_LS_KEY = 'wr2.adminToken';

  var state = {
    step: 1,
    adminToken: window.localStorage.getItem(ADMIN_TOKEN_LS_KEY) || '',
    agent: {
      slug: '',
      display_name: '',
      model: 'sonnet',
      color: '#7ee787',
      telegram: { token: '', group_id: '', operator_id: '' },
      persona: { template: 'default', role: '', tools: [] }
    },
    botValidation: null,    // { ok, bot_username, bot_id, error }
    previewDiff: null,
    applyResult: null,
    busy: false,
    err: ''
  };

  // --------- helpers ---------

  function $(sel, root) { return (root || document).querySelector(sel); }

  function makeEl(tag, attrs, children) {
    var el = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'class') el.className = attrs[k];
        else if (k === 'text') el.textContent = attrs[k];
        else if (k.indexOf('on') === 0) el.addEventListener(k.slice(2), attrs[k]);
        // Skip null/undefined/false so a boolean attr like `disabled: null` is
        // truly absent — setAttribute('disabled', null) would set disabled="null",
        // which still disables the element (boolean attrs are presence-based).
        else if (attrs[k] != null && attrs[k] !== false) el.setAttribute(k, attrs[k]);
      });
    }
    (children || []).forEach(function (c) {
      if (typeof c === 'string') el.appendChild(document.createTextNode(c));
      else if (c) el.appendChild(c);
    });
    return el;
  }

  async function api(path, body) {
    var headers = { 'Content-Type': 'application/json', 'X-Admin-Token': state.adminToken };
    var res = await window.WRFetch(path, {
      method: 'POST',
      headers: headers,
      body: JSON.stringify(body || {})
    });
    var data;
    try { data = await res.json(); } catch (e) { data = {}; }
    return { ok: res.ok, status: res.status, data: data };
  }

  // --------- validation (mirror server-side) ---------

  var SLUG_RE = /^[a-z][a-z0-9-]{2,30}$/;
  var COLOR_RE = /^#[0-9a-fA-F]{6}$/;
  var TG_TOKEN_RE = /^\d+:[\w-]+$/;
  var TG_ID_RE = /^-?\d+$/;
  var MODELS = ['sonnet', 'opus', 'haiku', 'gpt-5.5'];
  var TEMPLATES = ['default', 'dev', 'qa'];
  var TOOLS = ['bus', 'paperclip', 'trello', 'bitbucket'];

  function validateStep(step) {
    var a = state.agent;
    var errs = [];
    if (step >= 1) {
      if (!SLUG_RE.test(a.slug)) errs.push('Slug must match a-z, 3-31 chars, lowercase-dash.');
      if (!a.display_name || a.display_name.length > 40) errs.push('Display name 1-40 chars.');
      // '|' and newlines would corrupt launch.sh's pipe-joined roster rows
      // (server rejects these too — keep mirrored).
      if (/[|\r\n]/.test(a.display_name)) errs.push('Display name must not contain | or newlines.');
      if (MODELS.indexOf(a.model) < 0) errs.push('Pick a model.');
      if (!COLOR_RE.test(a.color)) errs.push('Color must be #RRGGBB.');
    }
    if (step >= 2) {
      // Token is optional: empty means a CLI-only agent (no Telegram).
      var hasToken = !!a.telegram.token;
      if (hasToken && !TG_TOKEN_RE.test(a.telegram.token)) errs.push('Telegram token shape invalid.');
      if (a.telegram.group_id && !TG_ID_RE.test(a.telegram.group_id)) errs.push('Group ID must be numeric.');
      if (a.telegram.operator_id && !TG_ID_RE.test(a.telegram.operator_id)) errs.push('Operator ID must be numeric.');
      if (hasToken && (!state.botValidation || !state.botValidation.ok)) errs.push('Validate the Telegram token first.');
    }
    if (step >= 3) {
      if (TEMPLATES.indexOf(a.persona.template) < 0) errs.push('Pick a persona template.');
    }
    return errs;
  }

  // --------- modal shell ---------

  function ensureRoot() {
    var existing = document.getElementById('wizard-modal');
    if (existing) return existing;
    var root = makeEl('div', { id: 'wizard-modal', hidden: 'hidden' });
    document.body.appendChild(root);
    return root;
  }

  function close() {
    var root = document.getElementById('wizard-modal');
    if (root) root.hidden = true;
    state.step = 1;
    state.botValidation = null;
    state.previewDiff = null;
    state.applyResult = null;
    state.err = '';
  }

  function open() {
    var root = ensureRoot();
    root.hidden = false;
    render();
  }

  function render() {
    var root = ensureRoot();
    root.innerHTML = '';
    var card = makeEl('div', { class: 'wz-card' });

    // Header
    var header = makeEl('div', { class: 'wz-header' }, [
      makeEl('div', { class: 'wz-title', text: 'Mount new agent' }),
      makeEl('div', { class: 'wz-steps' }, stepDots()),
      makeEl('button', { class: 'wz-close', text: 'x', onclick: close })
    ]);
    card.appendChild(header);

    // Admin token (always visible)
    var tokRow = makeEl('div', { class: 'wz-admin-row' }, [
      makeEl('label', { text: 'X-Admin-Token' }),
      makeEl('input', {
        type: 'password',
        value: state.adminToken,
        placeholder: 'WARROOM2_ADMIN_TOKEN value',
        oninput: function (e) {
          state.adminToken = e.target.value;
          window.localStorage.setItem(ADMIN_TOKEN_LS_KEY, e.target.value);
        }
      })
    ]);
    card.appendChild(tokRow);

    // Body
    var body = makeEl('div', { class: 'wz-body' });
    if (state.step === 1) body.appendChild(stepIdentity());
    else if (state.step === 2) body.appendChild(stepTelegram());
    else if (state.step === 3) body.appendChild(stepPersona());
    else if (state.step === 4) body.appendChild(stepPreview());
    else if (state.step === 5) body.appendChild(stepSuccess());
    card.appendChild(body);

    // Footer
    if (state.err) {
      card.appendChild(makeEl('div', { class: 'wz-err', text: state.err }));
    }
    if (state.step < 5) card.appendChild(footer());

    root.appendChild(card);
  }

  function stepDots() {
    var dots = [];
    for (var i = 1; i <= 4; i++) {
      var cls = 'wz-dot';
      if (i === state.step) cls += ' active';
      else if (i < state.step) cls += ' done';
      dots.push(makeEl('span', { class: cls, text: String(i) }));
    }
    return dots;
  }

  function footer() {
    var f = makeEl('div', { class: 'wz-footer' });
    if (state.step > 1) {
      f.appendChild(makeEl('button', {
        class: 'wz-btn',
        text: 'Back',
        onclick: function () {
          state.step--;
          state.err = '';
          render();
        }
      }));
    }
    var nextLabel = state.step === 4 ? 'Apply' : 'Next';
    f.appendChild(makeEl('button', {
      class: 'wz-btn wz-btn-primary',
      text: state.busy ? 'Working…' : nextLabel,
      disabled: state.busy ? 'disabled' : null,
      onclick: onNext
    }));
    return f;
  }

  async function onNext() {
    state.err = '';
    var errs = validateStep(state.step);
    if (errs.length) {
      state.err = errs.join(' ');
      render();
      return;
    }
    if (state.step < 3) {
      state.step++;
      render();
      return;
    }
    if (state.step === 3) {
      // call preview
      state.busy = true; render();
      var pr = await api('/api/admin/wizard/preview', { agent: state.agent });
      state.busy = false;
      if (!pr.ok) {
        state.err = formatErr(pr);
        render();
        return;
      }
      state.previewDiff = pr.data.diff || [];
      state.step = 4;
      render();
      return;
    }
    if (state.step === 4) {
      // call apply
      state.busy = true; render();
      var ar = await api('/api/admin/wizard/apply', { agent: state.agent });
      state.busy = false;
      if (!ar.ok) {
        state.err = formatErr(ar);
        render();
        return;
      }
      state.applyResult = ar.data;
      state.step = 5;
      render();
    }
  }

  function formatErr(r) {
    if (r.data && r.data.detail) {
      if (typeof r.data.detail === 'string') return 'Error (' + r.status + '): ' + r.data.detail;
      if (r.data.detail.errors) return 'Error (' + r.status + '): ' + r.data.detail.errors.join('; ');
      return 'Error (' + r.status + '): ' + JSON.stringify(r.data.detail);
    }
    return 'Error (' + r.status + ')';
  }

  // --------- step bodies ---------

  function input(label, key, opts) {
    opts = opts || {};
    var pieces = key.split('.');
    var get = function () {
      var v = state.agent;
      pieces.forEach(function (p) { v = v[p]; });
      return v;
    };
    var set = function (val) {
      var v = state.agent;
      for (var i = 0; i < pieces.length - 1; i++) v = v[pieces[i]];
      v[pieces[pieces.length - 1]] = val;
    };
    var inputEl = makeEl('input', {
      type: opts.type || 'text',
      value: get() || '',
      placeholder: opts.placeholder || '',
      oninput: function (e) { set(e.target.value); if (opts.onchange) opts.onchange(); }
    });
    return makeEl('div', { class: 'wz-field' }, [
      makeEl('label', { text: label }),
      inputEl,
      opts.hint ? makeEl('div', { class: 'wz-hint', text: opts.hint }) : null
    ]);
  }

  function stepIdentity() {
    var wrap = makeEl('div', { class: 'wz-step' });
    wrap.appendChild(makeEl('h3', { text: '1. Identity' }));
    wrap.appendChild(input('Slug', 'slug', { placeholder: 'lowercase-dash, e.g. nora', hint: '^[a-z][a-z0-9-]{2,30}$' }));
    wrap.appendChild(input('Display name', 'display_name', { placeholder: 'Nora' }));

    var modelSel = makeEl('select', {
      onchange: function (e) { state.agent.model = e.target.value; }
    }, MODELS.map(function (m) {
      var attrs = { value: m, text: m };
      if (m === state.agent.model) attrs.selected = 'selected';
      return makeEl('option', attrs);
    }));
    wrap.appendChild(makeEl('div', { class: 'wz-field' }, [
      makeEl('label', { text: 'Model' }), modelSel
    ]));

    wrap.appendChild(input('Color (#RRGGBB)', 'color', { type: 'color' }));
    return wrap;
  }

  function stepTelegram() {
    var wrap = makeEl('div', { class: 'wz-step' });
    wrap.appendChild(makeEl('h3', { text: '2. Telegram' }));

    wrap.appendChild(input('Bot token (optional)', 'telegram.token', {
      placeholder: '123456:ABC-DEF...',
      hint: 'Leave empty for a CLI-only agent (no Telegram)',
      onchange: function () { state.botValidation = null; }
    }));
    var validateBtn = makeEl('button', {
      class: 'wz-btn',
      text: 'Validate token',
      onclick: async function () {
        state.err = '';
        // getme needs a token — skip the call entirely when empty (CLI-only agent).
        if (!state.agent.telegram.token) {
          state.botValidation = null;
          state.err = 'No token to validate — leave empty for a CLI-only agent, or paste a token first.';
          render(); return;
        }
        if (!TG_TOKEN_RE.test(state.agent.telegram.token)) {
          state.err = 'Token shape invalid.'; render(); return;
        }
        state.busy = true; render();
        var r = await api('/api/admin/wizard/getme', { token: state.agent.telegram.token });
        state.busy = false;
        if (!r.ok || !r.data.ok) {
          state.botValidation = { ok: false, error: (r.data && r.data.error) || formatErr(r) };
        } else {
          state.botValidation = r.data;
        }
        render();
      }
    });
    wrap.appendChild(validateBtn);

    if (state.botValidation) {
      if (state.botValidation.ok) {
        wrap.appendChild(makeEl('div', { class: 'wz-ok', text: '✓ @' + state.botValidation.bot_username + ' (id ' + state.botValidation.bot_id + ')' }));
      } else {
        wrap.appendChild(makeEl('div', { class: 'wz-err', text: '✗ ' + state.botValidation.error }));
      }
    }

    wrap.appendChild(input('Group ID (optional)', 'telegram.group_id', { placeholder: '-100123...' }));
    wrap.appendChild(input('Operator ID (defaults to OPERATOR_TELEGRAM_ID)', 'telegram.operator_id'));
    return wrap;
  }

  function stepPersona() {
    var wrap = makeEl('div', { class: 'wz-step' });
    wrap.appendChild(makeEl('h3', { text: '3. Persona' }));

    var sel = makeEl('select', {
      onchange: function (e) { state.agent.persona.template = e.target.value; }
    }, TEMPLATES.map(function (t) {
      var attrs = { value: t, text: t };
      if (t === state.agent.persona.template) attrs.selected = 'selected';
      return makeEl('option', attrs);
    }));
    wrap.appendChild(makeEl('div', { class: 'wz-field' }, [
      makeEl('label', { text: 'Template' }), sel
    ]));

    var roleTa = makeEl('textarea', {
      placeholder: 'One-line role description',
      rows: '2',
      oninput: function (e) { state.agent.persona.role = e.target.value; }
    });
    roleTa.value = state.agent.persona.role || '';
    wrap.appendChild(makeEl('div', { class: 'wz-field' }, [
      makeEl('label', { text: 'Role' }), roleTa
    ]));

    var toolsBox = makeEl('div', { class: 'wz-tools' });
    toolsBox.appendChild(makeEl('label', { text: 'Tools' }));
    TOOLS.forEach(function (t) {
      var cb = makeEl('input', {
        type: 'checkbox',
        onchange: function (e) {
          var idx = state.agent.persona.tools.indexOf(t);
          if (e.target.checked && idx < 0) state.agent.persona.tools.push(t);
          else if (!e.target.checked && idx >= 0) state.agent.persona.tools.splice(idx, 1);
        }
      });
      if (state.agent.persona.tools.indexOf(t) >= 0) cb.checked = true;
      toolsBox.appendChild(makeEl('label', { class: 'wz-tool' }, [cb, document.createTextNode(' ' + t)]));
    });
    wrap.appendChild(toolsBox);

    return wrap;
  }

  function stepPreview() {
    var wrap = makeEl('div', { class: 'wz-step' });
    wrap.appendChild(makeEl('h3', { text: '4. Preview' }));
    if (!state.previewDiff || !state.previewDiff.length) {
      wrap.appendChild(makeEl('div', { text: '(no changes computed)' }));
      return wrap;
    }
    state.previewDiff.forEach(function (d) {
      var card = makeEl('div', { class: 'wz-diff' });
      card.appendChild(makeEl('div', { class: 'wz-diff-head' }, [
        makeEl('span', { class: 'wz-action wz-action-' + d.action, text: d.action }),
        makeEl('span', { class: 'wz-path', text: d.file })
      ]));
      card.appendChild(makeEl('pre', { class: 'wz-diff-body', text: d.after_excerpt }));
      wrap.appendChild(card);
    });
    return wrap;
  }

  function stepSuccess() {
    var wrap = makeEl('div', { class: 'wz-step' });
    wrap.appendChild(makeEl('h3', { text: 'Applied' }));
    var r = state.applyResult || {};
    wrap.appendChild(makeEl('div', { class: 'wz-ok', text: '✓ wrote ' + ((r.written || []).length) + ' files' }));
    if (r.backups && r.backups.length) {
      wrap.appendChild(makeEl('div', { class: 'wz-hint', text: 'backups: ' + r.backups.length }));
      var ul = makeEl('ul');
      r.backups.forEach(function (b) { ul.appendChild(makeEl('li', { text: b })); });
      wrap.appendChild(ul);
    }
    wrap.appendChild(makeEl('div', { class: 'wz-hint', text: r.next_step || '' }));

    var actions = makeEl('div', { class: 'wz-footer' });
    var status = makeEl('div', { class: 'wz-hint', text: '' });
    actions.appendChild(makeEl('button', {
      class: 'wz-btn wz-btn-primary',
      text: 'Restart war-room now',
      onclick: async function () {
        state.busy = true;
        status.textContent = 'restarting…';
        var rr = await api('/api/admin/wizard/restart-warroom', {});
        state.busy = false;
        if (!rr.ok) {
          status.textContent = 'restart failed: ' + formatErr(rr);
          return;
        }
        status.textContent = 'restarted. polling for agent…';
        await pollUntilAgent(state.agent.slug, 60, status);
      }
    }));
    actions.appendChild(makeEl('button', {
      class: 'wz-btn',
      text: "I'll restart manually",
      onclick: close
    }));
    wrap.appendChild(actions);
    wrap.appendChild(status);
    return wrap;
  }

  async function pollUntilAgent(slug, maxAttempts, statusEl) {
    for (var i = 0; i < maxAttempts; i++) {
      try {
        var data = await window.WRFetchJSON('/api/agents');
        var agents = (data && data.agents) || [];
        if (agents.some(function (a) { return a.id === slug; })) {
          statusEl.textContent = '✓ ' + slug + ' is registered.';
          return;
        }
      } catch (e) { /* ignore */ }
      await new Promise(function (res) { setTimeout(res, 1500); });
    }
    statusEl.textContent = 'agent did not appear within timeout — check logs.';
  }

  // --------- expose ---------

  window.WRWizard = {
    open: open,
    close: close
  };
})();
