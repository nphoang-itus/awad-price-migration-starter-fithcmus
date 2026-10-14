// Backfill menu_items.price_vnd (dong, integer) from price (thousands, float).
// Run it only when every instance runs v2 or later: from then on every write
// sets both columns in one statement, so `price` is the truth for old rows.
//
//   BATCH=500     rows per batch; each batch is its own short transaction
//   PAUSE_MS=50   pause between batches, so live traffic gets the write lock
//
// Idempotent and resumable: it only touches rows whose price_vnd is NULL or
// disagrees with price (a row v1 re-priced after v2 had written it). Kill it
// at any point and run it again; it ends in the same state.
// Rows whose price is NULL are left as they are (there is nothing to copy).
import { open, DB_PATH } from '../src/db.js';

const BATCH = Number(process.env.BATCH ?? 500);
const PAUSE_MS = Number(process.env.PAUSE_MS ?? 50);
const db = open();

const cols = new Set(db.prepare('PRAGMA table_info(menu_items)').all().map((c) => c.name));
if (!cols.has('price') || !cols.has('price_vnd')) {
  console.error(`backfill needs both price and price_vnd (has: ${[...cols].join(', ')}) — run migration 002 first`);
  process.exit(1);
}

// Same conversion as the server (Math.round(price * 1000)) and as check.js.
const NEEDS = 'price IS NOT NULL AND (price_vnd IS NULL OR price_vnd <> CAST(round(price * 1000) AS INTEGER))';
const pick = db.prepare(`SELECT id FROM menu_items WHERE id > ? AND ${NEEDS} ORDER BY id LIMIT ?`);
const fix = db.prepare(`UPDATE menu_items SET price_vnd = CAST(round(price * 1000) AS INTEGER) WHERE id = ? AND ${NEEDS}`);
const count = (where) => db.prepare(`SELECT count(*) n FROM menu_items WHERE ${where}`).get().n;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log(`backfill · db ${DB_PATH} · ${count(NEEDS)} rows to fix · batch ${BATCH} · pause ${PAUSE_MS}ms`);
let lastId = 0, batches = 0, fixed = 0;
const t0 = Date.now();
for (;;) {
  db.exec('BEGIN IMMEDIATE');
  let ids;
  try {
    ids = pick.all(lastId, BATCH).map((r) => r.id);
    for (const id of ids) fixed += Number(fix.run(id).changes);
    db.exec('COMMIT');
  } catch (e) { db.exec('ROLLBACK'); throw e; }
  if (!ids.length) break;
  lastId = ids.at(-1);
  if (++batches % 10 === 0) console.log(`  batch ${batches} · up to id ${lastId} · ${fixed} rows fixed`);
  await sleep(PAUSE_MS);
}

console.log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s · ${batches} batches · ${fixed} rows fixed`);
console.log(`remaining price_vnd NULL (price set): ${count('price IS NOT NULL AND price_vnd IS NULL')}`);
console.log(`remaining disagree:                    ${count('price_vnd <> CAST(round(price * 1000) AS INTEGER)')}`);
console.log(`rows with NULL price (left as is):     ${count('price IS NULL')}`);
