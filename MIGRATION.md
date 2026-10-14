# MIGRATION.md — `menu_items.price` (REAL, thousands) → `menu_items.price_vnd` (INTEGER, dong)

Expand → dual write → backfill → switch reads → stop writing the old column → contract. Two instances (A = :3001,
B = :3002) share one SQLite file. Every version change is a rolling restart, one instance at a time.
The HTTP contract never changes: every response carries `price` (thousands); from v2 on it also carries `priceVnd` (dong).

Conversion, the same everywhere: `price_vnd = round(price × 1000)` (server `Math.round`, SQL `CAST(round(price*1000) AS INTEGER)`,
same as `check.js`), and `price = price_vnd / 1000`. `order_items.unit_price` keeps its old unit (thousands).

## Code versions (tags)

| Tag | Reads | Writes | API |
|---|---|---|---|
| `v1` (= starter, `2b889bd`) | `price` | `price` | `price` only |
| `v2` | `price` | `price` **and** `price_vnd`, one statement, on `POST /menu` and `PATCH /menu/:id` | accepts `price` or `priceVnd` (must agree if both); returns both |
| `v3` | `price_vnd` | `price` **and** `price_vnd`, one statement | same as v2; `/orders` uses `price_vnd / 1000` |
| `v4` | `price_vnd` | `price_vnd` only (never touches `price`) | same; `price = price_vnd / 1000` on every endpoint |

## The plan, one row per step

Undo commands are run from the repo root with `export DB_PATH="$PWD/data/app.db"`. A "rolling restart to vN" means:
stop A, `cd ../vN && PORT=3001 npm start`, wait for `3001 back` in the traffic log, then the same for B on :3002.

| Step | Schema after the step | Code on every instance | Exact undo command | Earlier versions that can still run safely on this schema |
|---|---|---|---|---|
| 0 | `001` (`price` REAL, nullable) | A=v1, B=v1 | — (baseline) | v1 |
| 1 | `002_add_price_vnd`: + `price_vnd INTEGER` (nullable) | A=v1, B=v1 | `npm run migrate:down` (reverts 002: `DROP COLUMN price_vnd`) | v1 (never touches `price_vnd`), v2. **Not v3/v4**: `price_vnd` is still NULL |
| 2 | `002` | A=v2, B=v2 (dual write) | rolling restart to v1 | v1, v2. v1 is safe to *serve* because v2 still writes `price`, but any row v1 writes leaves `price_vnd` NULL or stale, so the backfill must run after the last v1 is gone. Not v3/v4 |
| 3 | `002`, backfilled (`price_vnd` = `round(price×1000)` on every row) | A=v2, B=v2 | none needed: data-only, nothing reads `price_vnd` yet; v2 keeps both columns equal. The structural undo is still `npm run migrate:down` (drops `price_vnd`) | v2, v3. (v1 would serve correctly but would make `price_vnd` stale again, so it is excluded from here on) |
| 4 | `002` | A=v3, B=v3 (reads `price_vnd`) | rolling restart to v2 — **performed under traffic** (4 → 4R → 4F) | v2, v3 |
| 5 | `002`, `price` no longer maintained | A=v4, B=v4 | rolling restart to v3 (v3 reads `price_vnd`, which v4 keeps correct) | v3, v4. **Not v2**: v2 reads `price`, which v4 has stopped updating (check: `disagree 1926`) |
| 6 | `003_drop_price`: `DROP COLUMN price` | A=v4, B=v4 | `npm run migrate:down` (reverts 003: re-adds `price REAL CHECK (price > 0)` and fills it with `price_vnd / 1000.0`), then rolling restart to v3 if needed | **v4 only.** v1–v3 crash at start (`table menu_items has no column named price`): their prepared statements name `price` |

Matches the repository: tags `v1`–`v4`, `migrations/002_add_price_vnd.{up,down}.sql`, `migrations/003_drop_price.{up,down}.sql`,
`scripts/backfill.js`. 003 was committed only with v4, so running `npm run migrate` while v1–v3 served could never drop `price`.

## Point of no return: step 6, `003_drop_price`

Dropping `price` deletes the only copy of the old float values and the column v1–v3 depend on.
After it, none of v1–v3 can even start. `003_drop_price.down.sql` re-creates the column, but it **restores values, not the
pre-drop state**: every price is rebuilt from `price_vnd / 1000.0`. Any precision finer than 1/1000 of a thousand dong, and
the history of what `price` held, is gone for good. Before step 6 every step could be undone with no loss.

## Why the rollback v3 → v2 is safe, and which later rollback would not be

- **v3 → v2 is safe.** v3 still writes `price` and `price_vnd` together in one `UPDATE … SET price = ?, price_vnd = ?`.
  The old column never falls behind, so v2, which reads `price`, sees every write v3 acknowledged. The two can even serve
  side by side during the rolling restart.
  Done under traffic: check-log steps 4 / 4R / 4F all `CONSISTENT`, zero failures in traffic-log lines 15–31.
- **v4 → v2 (or v3 → v2 after v4 has run) would NOT be safe.** v4 stops writing `price`. Every re-price after it leaves
  `price` stale: check step 5 shows `disagree 1926` after about 10 s. v2 reads `price`, so it would serve old prices
  (`stale` in the traffic log) and return `price: null` for items v4 created.
  This is exactly what happened in the failed first attempt (below). v4 → v3 is still safe, because v3 reads `price_vnd`.
- **After 003, no rollback below v4** without first running `migrate:down` of 003.

## Expected `INCONSISTENT` results (not hidden, not edited)

- **Step 2: `disagree 9`** (check-log lines 20–28). During the rolling restart there were a few seconds with A=v2 and B=v1.
  v2 dual-wrote a row, then v1 re-priced it and set only `price`, so `price_vnd` was non-NULL but stale. Nothing read
  `price_vnd` at that point.
  `scripts/backfill.js` repairs exactly these rows as well as the NULL ones:
  `WHERE price IS NOT NULL AND (price_vnd IS NULL OR price_vnd <> CAST(round(price*1000) AS INTEGER))`.
  After it, step 3 is plain `CONSISTENT`.
- **Step 5: `disagree 1926`** (check-log lines 93–101). v4 no longer writes `price`, by design ("neither reads nor writes it").
  From here `price` is a dead column that no running version reads. 003 was applied right after (step 6, same second),
  and step 6 is `CONSISTENT`.

## Backfill (`scripts/backfill.js`)

- Batches of `BATCH` rows (500 by default; 200 in the run). Each batch is its own `BEGIN IMMEDIATE … COMMIT`, with a
  `PAUSE_MS` sleep between batches so live writes get the lock.
- Idempotent and resumable: it touches only rows that still need fixing, so it can be killed at any time and rerun.
  In the run it was stopped with SIGINT after 4 s (step 3a: 14,249 rows still NULL), then rerun (14,249 fixed), and step 3 is `CONSISTENT`.
- Ran only when `who` showed v2 on both instances (step 3a / 3 headers): no version that writes `price` alone was serving.
- Rows with a NULL `price` would keep a NULL `price_vnd`: there is nothing to copy. The run had 0 such rows; seed, v1 and v2
  all require a price.

## Evidence map

| What | Where |
|---|---|
| One continuous traffic run | `traffic-log.txt` lines 2–45, start 11:26:27Z, `RESULT: zero failed requests` (line 45) |
| 002 under traffic | check-log line 8 (`applied 002_add_price_vnd`) at 11:26:37Z, about 10 s into traffic (between traffic-log lines 4 and 5) |
| v1 → v2 | traffic-log 6–9 · check step 2 |
| `NEW_CLIENTS` 0 → 0.3 after v2 | traffic-log 11 |
| backfill interrupted + rerun | check-log 29–61 |
| v2 → v3, rollback → v2, → v3 | traffic-log 15–19, 21–25, 27–31 · check steps 4 / 4R / 4F (lines 63–91) |
| v3 → v4 | traffic-log 33–37 · check step 5 |
| 003 under traffic, then 30 s more traffic | check-log 102–111 (11:27:41Z = about 74 s) · traffic-log 38–45 |
| `migrate:down` once per migration (separate DB `data/scratch.db`) | check-log 122–190 (D1 reverts 003, D2 reverts 002, D3 reverts 001; "no such table" is expected) |

## Disclosures

- **`scripts/traffic.js` was patched**, with a small, disclosed change (AI-LOG.md). It re-reads the new-client share from
  `new-clients.txt` every second and logs each change (traffic-log line 11). The starter reads `NEW_CLIENTS` only once at start,
  so one continuous log from v1 could never have new clients after v2. Failure checks, counters and the RESULT line are unchanged.
- **The run was driven by `scripts/live-run.sh`**, an automated version of `RUNBOOK.md` (both written with Claude Code, see AI-LOG.md).
  I ran it. It refuses any step whose label does not match the version each port really runs (`who` lines in check-log).
- **A first manual attempt failed** (28,894 failed requests; logs kept outside the repo):
  - 002 was applied before traffic started.
  - Both instances were stopped together, which gave 682 `unavailable`.
  - A rollback round was skipped, so v4 served next to v2, which gave 28,070 `stale` + 142 `contract`.

  These were operational mistakes, not code faults. They are what the second bullet of the rollback section predicts.
  The submitted logs are the second, clean run.
- PostgreSQL note: `ADD COLUMN` (nullable, no default) and `DROP COLUMN` are metadata-only there too, but both need a brief
  `ACCESS EXCLUSIVE` lock. They should run with a short `lock_timeout` and a retry, so they never queue behind a long query.
  The backfill's short batches also keep row locks short.
