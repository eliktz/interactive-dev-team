// Telegram inbox attachment cleanup — keep last 7 days, archive or delete older.
// Usage: node inbox-cleanup.js [archive|delete]
const fs = require('fs'), path = require('path');
const base = '/home/claude/.claude/channels';
const DAYS = 7;
const CUTOFF = Date.now() - DAYS * 24 * 3600 * 1000;
const MODE = process.argv[2] === 'delete' ? 'delete' : 'archive';
let total = 0, kept = 0;
if (!fs.existsSync(base)) { console.log('no channels dir'); process.exit(0); }
for (const ch of fs.readdirSync(base)) {
  if (!ch.startsWith('telegram-')) continue;
  const inbox = path.join(base, ch, 'inbox');
  if (!fs.existsSync(inbox)) continue;
  const arch = path.join(base, ch, 'inbox-archived');
  let moved = 0;
  for (const f of fs.readdirSync(inbox)) {
    const fp = path.join(inbox, f);
    let st; try { st = fs.statSync(fp); } catch (e) { continue; }
    if (!st.isFile()) continue;
    if (st.mtimeMs < CUTOFF) {
      try {
        if (MODE === 'delete') fs.unlinkSync(fp);
        else { fs.mkdirSync(arch, { recursive: true }); fs.renameSync(fp, path.join(arch, f)); }
        moved++;
      } catch (e) {}
    }
  }
  const remain = fs.readdirSync(inbox).length;
  if (moved) console.log(`  ${ch}: ${MODE} ${moved} (kept ${remain} from last ${DAYS}d)`);
  total += moved; kept += remain;
}
console.log(`TOTAL ${MODE}: ${total} | kept (< ${DAYS}d): ${kept}`);
