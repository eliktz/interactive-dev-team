// Codi Telegram bridge v3 — thread continuity + memory files + reaction/format.
// Verbatim from codex-lab-1:/home/claude/codi/bridge.js (2026-07-10), with the
// operator id replaced by a placeholder. See docs/CODI-CODEX-TELEGRAM-AGENT.md.
const https = require('https');
const { execFileSync } = require('child_process');
const fs = require('fs');

const HOME = '/home/claude/codi';
const STATE = '/home/claude/.claude/channels/telegram-codi';
const TOKEN = fs.readFileSync(STATE + '/.env', 'utf8').match(/TELEGRAM_BOT_TOKEN=(.+)/)[1].trim();
const OPERATOR = '<YOUR_TELEGRAM_NUMERIC_ID>';
const API = `https://api.telegram.org/bot${TOKEN}`;
const OFFSET_FILE = STATE + '/bridge-offset';
const THREAD_FILE = STATE + '/thread-id';
const SCHEMA = HOME + '/schema.json';
const VALID = ['👀','❤','🔥','🎉','👏','🫡','🙏','👍','😁','🤩','💯','⚡','🏆','🤣','😴'];

function tg(method, params) {
  return new Promise((resolve) => {
    const data = JSON.stringify(params);
    const req = https.request(`${API}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, r => {
      let b = ''; r.on('data', c => b += c); r.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { resolve({ ok: false }); } });
    });
    req.on('error', () => resolve({ ok: false })); req.write(data); req.end();
  });
}

function askCodi(text) {
  let threadId = null;
  try { threadId = (fs.readFileSync(THREAD_FILE, 'utf8').trim()) || null; } catch (e) {}
  const base = ['--dangerously-bypass-approvals-and-sandbox', '--json', '--skip-git-repo-check', '--output-schema', SCHEMA];
  const args = threadId ? ['exec', 'resume', threadId, ...base, text] : ['exec', ...base, text];
  try {
    const out = execFileSync('codex', args, { cwd: HOME, timeout: 180000, maxBuffer: 20 * 1024 * 1024, encoding: 'utf8' });
    let result = null, newThread = null;
    for (const line of out.trim().split('\n')) {
      try { const j = JSON.parse(line);
        if (j.type === 'thread.started' && j.thread_id) newThread = j.thread_id;
        if (j.type === 'item.completed' && j.item && j.item.type === 'agent_message') result = JSON.parse(j.item.text);
      } catch (e) {}
    }
    if (!threadId && newThread) { fs.writeFileSync(THREAD_FILE, newThread); console.log('[codi] new thread', newThread); }
    return result;
  } catch (e) { console.log('[codi] exec error:', String(e.message).slice(0, 150)); return null; }
}

let offset = 0;
try { offset = parseInt(fs.readFileSync(OFFSET_FILE, 'utf8')) || 0; } catch (e) {}
console.log('[codi] bridge v3 (thread + memory) started, offset', offset);

async function loop() {
  while (true) {
    try {
      const r = await tg('getUpdates', { offset, timeout: 25 });
      if (r.ok) for (const u of r.result) {
        offset = u.update_id + 1; fs.writeFileSync(OFFSET_FILE, String(offset));
        const m = u.message;
        if (!m || !m.text) continue;
        if (String(m.from.id) !== OPERATOR || m.chat.type !== 'private') continue;
        console.log('[codi] msg:', m.text.slice(0, 60));
        await tg('sendChatAction', { chat_id: m.chat.id, action: 'typing' });
        const res = askCodi(m.text) || { reaction: '👀', format: 'text', reply: 'סליחה, תקלה זמנית. תנסה שוב.' };
        const emoji = VALID.includes(res.reaction) ? res.reaction : '👀';
        await tg('setMessageReaction', { chat_id: m.chat.id, message_id: m.message_id, reaction: [{ type: 'emoji', emoji }] });
        let sent;
        if (res.format === 'markdownv2') {
          sent = await tg('sendMessage', { chat_id: m.chat.id, text: res.reply, parse_mode: 'MarkdownV2' });
          if (!sent.ok) sent = await tg('sendMessage', { chat_id: m.chat.id, text: res.reply });
        } else sent = await tg('sendMessage', { chat_id: m.chat.id, text: res.reply });
        console.log('[codi] react', emoji, '| fmt', res.format, '| replied:', sent.ok ? 'ok' : JSON.stringify(sent).slice(0, 90));
      }
    } catch (e) { console.log('[codi] loop err:', String(e.message).slice(0, 80)); await new Promise(r => setTimeout(r, 3000)); }
  }
}
loop();
