# CLAUDE.md — IA#2 zero-downtime migration (CSC13114)

Context for an AI assistant working in this repository. Read this fully before touching anything.

**Source of truth (decided by the student, 2026-10-14):** `IA02-requirements.pdf` (the rubric) first, then `README.md`,
then this file. If this file disagrees with the PDF, fix this file and say so in AI-LOG.md. Any design choice the PDF does
not require must be named as the assistant's own addition, so the student can reject it.

## Goal

In the `smart-restaurant` menu service, replace `menu_items.price` (REAL, thousands of dong, e.g. `45.5` = 45,500 đ)
with `menu_items.price_vnd` (INTEGER, dong), then drop `price` — while two instances keep serving traffic.
Zero failed requests, and a way back at every step until the one named as the point of no return.

HTTP contract never breaks: old clients send/read `price` (thousands) forever; new clients may send/read `priceVnd`
(dong) once the API offers it. Both always see the same price. `order_items.unit_price` keeps its old unit (thousands).

## Ground rules (assignment integrity — do not break these)

1. **The assistant writes files; the student runs things.** You may write migration files, code, scripts and docs.
   You must NOT run `npm run migrate`, `migrate:down`, `seed`, the backfill, `npm run traffic`, deploys or rollbacks
   against `data/app.db`, and must NOT create or edit `traffic-log.txt` / `check-log.txt`. Those logs are the student's evidence.
   - Allowed: `npm test`, and rehearsals on a scratch DB only (`DB_PATH=$PWD/data/scratch.db`), clearly told to the student.
2. **Do not commit, tag, push, or create worktrees** unless the student asks for that specific action.
3. **AI-LOG.md is mandatory.** After each piece of work, append an entry: what the student asked, what you produced
   (files), what the student changed or rejected. Never write it as if the student did work you did.
4. **Never claim something was run or verified if it was not.** The student's self-assessment is compared with the real mark;
   an over-claim costs points. When a step is untested, say "untested".
5. Never edit `scripts/traffic.js` or `scripts/check.js` silently. If a change seems necessary, stop and raise it (see Open decisions).

## Repository facts (verified from the starter)

- Node >= 22.5, zero dependencies, DB is SQLite through built-in `node:sqlite` (SQLite 3.50.x), WAL mode, `busy_timeout=5000`.
- `src/app.js` — whole HTTP service. Routes: `GET /health`, `GET|POST /menu`, `GET|PATCH /menu/:id`, `POST /orders`.
  Responses use `view(row)` = `{id, name, price}`. Errors: `{error, message}`. `isPrice`: finite number, `0 < p <= 100000`.
- `src/db.js` — `open()`; `DB_PATH` env (use an **absolute** path when running an older version from a worktree).
- `src/server.js` — `PORT` env; SIGINT/SIGTERM finish in-flight requests then exit (clean rolling restart).
- `migrations/001_init.{up,down}.sql` — `price REAL CHECK (price > 0)` is **nullable** (so v4 not writing `price` will not violate NOT NULL).
- `scripts/migrate.js` — `up` applies every pending file, each in one transaction; `down` reverts only the **last** applied step
  and fails if its `.down.sql` is missing. Files are `NNN_name.up.sql` / `NNN_name.down.sql`.
- `scripts/seed.js` — 20,000 items, prices `15.0..250.0` in 0.5 steps.
- `scripts/check.js` — prints columns, row count, `price_vnd_null`, `price_vnd_not_integer`, `disagree`
  (`price_vnd <> CAST(round(price*1000) AS INTEGER)` when both columns exist); ends with `CONSISTENT` or `INCONSISTENT`.
  It prints "CONSISTENT, but N rows have no price_vnd yet" while NULLs remain — that is not the clean state the rubric wants after backfill.
- `scripts/traffic.js` — 8 workers, ~60% read item, 20% PATCH price, 15% order, 2% POST /menu, rest list page.
  Ids `1..50` are never re-priced (orders are checked against them). Failure kinds: `error` (5xx), `contract`, `stale`, `unavailable`.
  One instance down while the other answers = `rerouted` (OK). Both down = `unavailable` (downtime). Log is **appended** to `traffic-log.txt`.
  Starter: `NEW_CLIENTS` is read **once at start** (env var). Patched (disclosed): also re-read from `NEW_CLIENTS_FILE` every second.
- `test/app.test.js` — runs **every** `*.up.sql` into `:memory:`, then inserts `INSERT INTO menu_items (name, price) ...`.
  After migration 003 drops `price` this setup breaks: the test fixture must be updated in the v4 commit.
  Also: the first test `deepEqual`s `{id,name,price}`, so it must be updated in the **v2** commit (response gains `priceVnd`).
- `003_drop_price.*.sql` is added in the **v4** commit, not before: `npm run migrate` applies every pending file, so 003 must not
  exist in the main worktree while v1–v3 are serving.
- SQLite checks done: `ALTER TABLE menu_items DROP COLUMN price` works (the CHECK is attached to that same column);
  `ADD COLUMN price REAL CHECK (price > 0)` works for the `.down.sql` of the drop; `DROP COLUMN price_vnd` works.

## Plan to implement (tags = code versions; migrations continue from 001)

| Step | Schema after | Code on every instance | Notes |
|---|---|---|---|
| 0 | 001 | **v1** (starter, tag `v1`) | baseline |
| 1 | `002_add_price_vnd`: `ALTER TABLE menu_items ADD COLUMN price_vnd INTEGER` (nullable) | v1 | v1 keeps working; rows v1 writes have `price_vnd` NULL |
| 2 | 002 | **v2**: reads `price`; writes **both** columns on **every** write path (`POST /menu` and `PATCH /menu/:id`); accepts `price` or `priceVnd`; returns `{id,name,price,priceVnd}` with `priceVnd = Math.round(price*1000)` | rolling restart, one instance at a time |
| 3 | 002 | v2 on both | **Backfill** (`scripts/backfill.js`), only once no v1 is serving; then `npm run check` must say plain `CONSISTENT` |
| 4 | 002 | **v3**: reads `price_vnd` (`price = price_vnd/1000`), still writes both; `/orders` uses `price_vnd/1000` as `unit_price` | then **rollback v3 -> v2 -> v3 under traffic**, `check` before and after |
| 5 | 002 | **v4**: neither reads nor writes `price`; still returns `price = price_vnd/1000` on **every** endpoint | on both instances before the drop |
| 6 | `003_drop_price`: `DROP COLUMN price` | v4 | **point of no return** (student decides wording; see below) |

Rules for the code:
- Conversion is `Math.round(price * 1000)` and `price_vnd / 1000`. Use the same rounding in the server and in the backfill SQL
  (`CAST(round(price * 1000) AS INTEGER)`, same as `check.js`).
- Both write paths, both columns, **inside one statement** (`UPDATE ... SET price = ?, price_vnd = ?`), never two statements.
- Validate `priceVnd` as a positive integer; if a body has both `price` and `priceVnd`, they must agree or return 400.
- v3/v4 must never fail on a row with NULL `price_vnd` — that is why backfill runs before v3.
- After the drop, **every** endpoint (`GET /menu`, `GET /menu/:id`, `POST /menu`, `PATCH /menu/:id`) still returns numeric `price`.
- Every migration has a real `.down.sql`. `003_drop_price.down.sql` must re-add `price REAL CHECK (price > 0)` and restore it
  from `price_vnd / 1000.0`; say honestly in MIGRATION.md that this restores values, not the original pre-drop state.

### Backfill requirements (`scripts/backfill.js`)
- Small batches (e.g. 500 rows), **each batch its own short transaction**, a short pause between batches (traffic keeps running).
- Idempotent and resumable: select with
  `WHERE price IS NOT NULL AND (price_vnd IS NULL OR price_vnd <> CAST(round(price * 1000) AS INTEGER))`;
  kill it mid-way, rerun, same final state.
  (Updated 2026-10-14 with the student: while A=v2 and B=v1, v1 can re-price a row v2 already dual-wrote, leaving a
  non-NULL but stale `price_vnd`. A NULL-only backfill would miss it and `check` would report `disagree > 0`.
  It is safe to treat `price` as the truth because the backfill runs only when v2 is on both instances, and v2 reads `price`.)
- Each batch: select ids `LIMIT 500`, then `UPDATE ... WHERE id IN (...) AND <same condition>` inside `BEGIN IMMEDIATE ... COMMIT`.
- Use `open()` from `src/db.js` so it honours `DB_PATH`; print progress and a final count of remaining NULLs.
- Rows with NULL `price` stay NULL — mention that in MIGRATION.md.

## Open decisions — raise these with the student, do not decide silently

1. **DECIDED 2026-10-14 by the student: patch `traffic.js` (disclosed).** `NEW_CLIENTS_FILE` (default `new-clients.txt`) is re-read
   every second and each change is logged. Recorded in AI-LOG.md; must also be stated in MIGRATION.md. Original note:
   **`NEW_CLIENTS` cannot change mid-run.** The rubric wants one continuous traffic log with `NEW_CLIENTS > 0` after the API
   offers `priceVnd`, but `traffic.js` reads it once at start, and new clients get 400 from v1. Options: accept a split log
   (rubric band 11–16 for criterion 4), or ask the lecturer whether a small, disclosed patch to `traffic.js`
   (re-read the share from a file) is acceptable. Never patch without the student's explicit go-ahead; if patched, log it in AI-LOG.md.
2. **DECIDED 2026-10-14 by the student: record the real output, then drop right away.** The check after v4 is labelled with an
   explanation and kept as is (INCONSISTENT); 003 is applied immediately after, then check again (CONSISTENT). MIGRATION.md explains
   that `price` is a dead column at that point (no running version reads it). **`check.js` after v4 is deployed, before the drop.** Verified in the assistant's rehearsal: `disagree 1936`, `INCONSISTENT`,
   because v4 no longer writes `price`. After 003, `CONSISTENT`. Also verified: v3 code crashes at start on schema 003
   (`table menu_items has no column named price`).
   Original note: v4 stops writing `price`, so re-priced rows leave `price` stale and
   `disagree > 0` makes `check` print `INCONSISTENT`. Decide with the student: run the drop immediately after v4 is on both instances,
   or record the expected result with an explanation in MIGRATION.md. Do not hide or edit the output.
3. **Which step is the point of no return** and the exact reason (student writes the final sentence).

## Runbook skeleton (the student runs this; refine with them, do not execute it)

**The full, current runbook is `RUNBOOK.md`** (step 7, 2026-10-14). The skeleton below is kept for context; if they differ, RUNBOOK.md wins.

PDF, criterion 4: "One continuous traffic-log.txt covers **every deploy and every migration**".
So 002 and 003 must be applied **while traffic runs**. The initial setup must create schema 001 only. `npm run migrate` from
`main` would apply 002 as well, so the setup runs from the `v1` worktree, whose tag has only `001`.
Tag `v1` already exists on `2b889bd` (the starter); do not re-create it.

```bash
export DB_PATH="$PWD/data/app.db"            # absolute, same file for every version
git worktree add ../v1 v1                     # v1 code + only migration 001
rm -f data/app.db* traffic-log.txt check-log.txt new-clients.txt   # one clean run; traffic.js appends
(cd ../v1 && npm run migrate && npm run seed) # schema 001 ONLY + 20,000 items (not from main!)

# label every check:
step() { echo "=== STEP $1" | tee -a check-log.txt; npm run check 2>&1 | tee -a check-log.txt; }

# Start instances ONE AT A TIME and wait for "menu service on :PORT" before the next. Starter `db.js` runs
# `journal_mode = WAL` before `busy_timeout`, so two processes opening the file at the same instant can crash
# with "database is locked" (seen in the assistant's scratch rehearsal, 2026-10-14). Always check the instance printed that line.
PORT=3001 npm start   &                       # instance A (v1)
PORT=3002 npm start   &                       # instance B (v1)
npm run traffic                               # terminal 3, left running all the way (from main: patched traffic.js)
# step 1: `npm run migrate` from main (applies 002 only, since 003 is not committed before v4), under traffic.
# rolling restart: kill A's pid, start A from ../v2 worktree, wait for "back" in the log, then B.
# once BOTH run v2 (README: "Turn it on once every running version offers priceVnd"): echo 0.3 > new-clients.txt
# repeat the pattern for v3, rollback to v2, v3 again, v4; after v4 on both: `npm run migrate` (applies 003), under traffic.
# keep traffic running for a while after 003 (PDF: "from v1 to after the last migration"), then Ctrl+C → RESULT line.
```

`migrate:down` evidence (PDF criterion 2: "migrate:down was run once for each — on a separate database file is fine — with the
output in check-log.txt"). `seed.js` inserts into `price`, so it cannot run once 003 is applied. Build the scratch DB in stages
(verified by the assistant on a scratchpad DB, 2026-10-14):
```bash
export DB_PATH="$PWD/data/scratch.db"; rm -f data/scratch.db*
(cd ../v3 && npm run migrate)      # 001 + 002 only (tag v3 has no 003)
npm run seed && npm run backfill   # data in both columns
npm run migrate && npm run check   # applies 003 → CONSISTENT (columns id, name, price_vnd)
npm run migrate:down && npm run check   # reverts 003 → price re-created from price_vnd, disagree 0, CONSISTENT
npm run migrate:down && npm run check   # reverts 002 → CONSISTENT (columns id, name, price)
npm run migrate:down && npm run check   # reverts 001 → check fails "no such table: menu_items" (expected; record as is)
```
Paste everything, labelled, into `check-log.txt`. `migrate:down` reverts only the last step, so each migration is exercised once.

## Deliverables checklist (one zip named `<StudentID>_<total>.zip`, including `.git`)

- [ ] tags `v1` (= starter), `v2`, `v3`, `v4` — one per deployed code version, matching `MIGRATION.md`
- [ ] `migrations/002_*.up.sql` + `.down.sql`, `003_*.up.sql` + `.down.sql`
- [ ] `scripts/backfill.js`
- [ ] `MIGRATION.md` — table, one row per step, 4 columns: schema after the step · code version on each instance ·
      exact undo command · which earlier versions can still run safely on this schema; names the point of no return and why;
      explains why rollback v3->v2 is safe and which later rollback would not be
- [ ] `traffic-log.txt` — one continuous run, per-instance `down`/`back` lines, ends `RESULT: zero failed requests`
- [ ] `check-log.txt` — `npm run check` after every step, labelled, plus the `migrate:down` outputs
- [ ] `AI-LOG.md`
- [ ] `SELF_ASSESSMENT_REPORT.md` — one row per criterion with marks and evidence (file / tag / log line range / migration),
      a short "what I did not manage"; total in the table = number in the zip name (gap > +10 vs real mark is penalised)
- [ ] updated `test/app.test.js` (fixture must not use `price` after migration 003)

## Working style

- Small commits only when the student asks; message says which version/step it is.
- Before writing code for a step, state which versions can run against the schema after that step.
- If something in the rubric or README is ambiguous, ask the student to confirm with the lecturer rather than guessing.
