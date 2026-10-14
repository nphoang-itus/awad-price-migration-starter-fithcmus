# AI-LOG.md — IA#2 zero-downtime migration (CSC13114)

Format per entry: my prompt copied verbatim, a short summary of the assistant's response (not a transcript),
then the template fields. The assistant writes files; I run every migration, seed, backfill, traffic run, deploy
and rollback myself.

## 2026-10-14 — understanding the assignment, planning the steps
Tool: Claude Code (Opus 5.5), plan mode.
Prompt (verbatim):
> Đọc @IA02-requirements.pdf , @README.md sau đó đọc @CLAUDE.md để hiểu bài tập tôi đang cần làm. Sau đó hướng dẫn chi tiết tôi từng bước một để hoàn thành bài tập (mỗi lần làm chỉ tập chung vào 1 bước). Dưới đây là template cho @AI-LOG.md hãy dựa vào và mỗi khi tôi thực hiện prompt copy nguyên y câu mà tôi prompt và response của bạn sau đó điền những thứ cần thiết trong AI-LOG: [AI-LOG template pasted]

Response (summary): read the rubric, README, CLAUDE.md, `src/app.js`, `scripts/traffic.js` and `test/app.test.js`, then
asked me 3 questions before writing any plan:
(1) `NEW_CLIENTS` is read only once at start, but criterion 4 wants one continuous log;
(2) should the AI-LOG keep the full response or only a summary;
(3) the backfill condition in CLAUDE.md (`WHERE price_vnd IS NULL`) misses rows that v1 re-prices after v2 already dual-wrote them.
Asked for: an explanation of the assignment and a step-by-step plan.
Kept: the 8-step roadmap (prepare → 002 → v2 → backfill → v3 → v4 + 003 → live run → documents).
Changed: — (the plan was approved as written).
Rejected: —
By hand: the decisions on the 3 questions (next entry).

## 2026-10-14 — decisions + step 1 (prepare)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> 1. sửa traffic.js đi
> 2. đọc lại theo yêu cầu xem có nhất thiết phải chép hết response ko? nếu không thì cứ làm theo những gì mà theo bạn thấy ổn nhất.
> 3. nếu CLAUDE.md chưa tối ưu cho backfill, trực tiếp sửa lại để có thể đạt điểm tối đa

Response (summary): the template says "an account, not a transcript", so responses are summarised and prompts are kept verbatim.
Patched `scripts/traffic.js` so the new-client share can change mid-run. Updated CLAUDE.md:
- the backfill also fixes rows whose `price_vnd` disagrees with `price`;
- the first test must change in the v2 commit;
- migration 003 is added only in the v4 commit;
- open decision 1 is recorded as decided.

Ran `npm test` (4/4 pass on the starter code + patch; the test does not cover traffic.js).
Files:
- `scripts/traffic.js`: **disclosed change to a provided script.** New `NEW_CLIENTS_FILE` (default `new-clients.txt`)
  is re-read every 1 s. A value in 0..1 replaces the share, and the change is written to the log as
  `new clients X -> Y`. Failure checks, counters and the RESULT line are unchanged.
- `CLAUDE.md`, `.gitignore` (`new-clients.txt`), `AI-LOG.md`.

Untested: the traffic.js patch has not been run against a live server yet.
Asked for: let NEW_CLIENTS change mid-run, keep the AI-LOG short, make the backfill reach plain CONSISTENT.
Kept: patching `traffic.js` so one continuous log covers the whole run (share re-read from `new-clients.txt`); the short-summary format (prompts verbatim, responses summarised); the CLAUDE.md backfill fix.
Changed: `scripts/traffic.js` (new `NEW_CLIENTS_FILE`, disclosed); CLAUDE.md (backfill also fixes rows where `price_vnd` disagrees with `price`, first test changes in the v2 commit, 003 only in the v4 commit, open decision 1 recorded); `.gitignore`.
Rejected: splitting the evidence into several traffic runs/logs; copying every full response into the AI-LOG; the original `WHERE price_vnd IS NULL` backfill condition.
By hand: I decided to patch traffic.js instead of accepting a split log.

## 2026-10-14 — tag v1 already exists
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> hiện tôi ko gắn được tag v1, nó báo lỗi: … `git tag v1 2b889bd` → `fatal: tag 'v1' already exists`

Response (summary): checked with `git tag -l`, `git rev-parse v1` and `git log --decorate`, which are read-only.
`v1` already exists as a lightweight tag on `2b889bd` (the starter commit), so it is already correct.
No need to recreate it; continue with the step-1 commit.
Asked for: help with the tag error.
Kept: the existing tag v1.
Changed: —
Rejected: deleting and recreating the tag (not needed).
By hand: —

## 2026-10-14 — step 2: migration 002 (expand)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 1

Response (summary): wrote `migrations/002_add_price_vnd.up.sql` (`ALTER TABLE menu_items ADD COLUMN price_vnd INTEGER`, nullable)
and `.down.sql` (`DROP COLUMN price_vnd`).
A first draft had `CHECK (price_vnd > 0)`. The assistant removed it itself: v1 accepts `price = 0.0001`, and
`round(0.1) = 0` would then break v2 and the backfill with a 500.
Rehearsal by the assistant on a throw-away DB in its scratchpad, never `data/app.db`:
migrate → seed → check (`CONSISTENT, but 20000 rows have no price_vnd yet`) → migrate:down → check (`CONSISTENT`).
The scratch DB was deleted after. `npm test` 4/4 with 002 applied.
This rehearsal is NOT the `migrate:down` evidence for check-log.txt; I produce that myself in the final run.
Asked for: the next step.
Kept: `price_vnd INTEGER` added as a nullable column in its own migration, with a matching `.down.sql`; rehearsing on a throw-away DB instead of `data/app.db`.
Changed: the assistant removed its own draft `CHECK (price_vnd > 0)` before delivering, because v1 accepts `price = 0.0001` and `round(0.1) = 0` would cause a 500.
Rejected: the `CHECK (price_vnd > 0)` constraint.
By hand: nothing executed yet at this step; the real `migrate` and the `migrate:down` evidence for check-log.txt are mine to produce in the final run.

## 2026-10-14 — is dropping the CHECK on price_vnd allowed by the requirements?
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> ủa phần "Có một edge case: giá v1 0.0001 khi quy đổi sẽ bằng 0 và vi phạm CHECK price_vnd > 0, gây lỗi 500. Tôi sẽ bỏ ràng buộc CHECK, dùng kiểu INTEGER thuần theo CLAUDE.md, rồi chạy lại thử nghiệm." bạn phải đọc @IA02-requirements.pdf xem có được chỉnh sửa vậy ko? ưu tiên requirement gốc

Response (summary): re-read the PDF and README. Both ask only for `menu_items.price_vnd` as an INTEGER in dong
(README: "Move to `menu_items.price_vnd INTEGER`, in dong"). Neither asks for a CHECK.
The rubric's only schema rules for this step: the new column is added in its own migration, v1 keeps working,
and there is no rename or in-place type change.
The CHECK was the assistant's own extra in a draft, not a requirement, so plain `INTEGER` is the literal requirement.
The assistant should have said so in the first answer instead of only citing CLAUDE.md.
No file changed except this log.
Asked for: confirm the change against the original requirements.
Kept: plain `INTEGER` for `price_vnd`, which is what the PDF and README literally ask for.
Changed: no code changed; the log now records that the CHECK was the assistant's own extra, not a requirement.
Rejected: justifying the schema only by CLAUDE.md; the CHECK constraint.
By hand: I asked for the change to be checked against the original requirements before accepting it.

## 2026-10-14 — CLAUDE.md checked against the PDF + step 3: code v2 (expand: dual write)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 2. bây giờ cứ ưu tiên nội dung trong @IA02-requirements.pdf trước, nếu sai thì chỉnh @CLAUDE.md để đảm bảo chính xác luôn

Response (summary):
- **CLAUDE.md vs PDF.** Fixed a real runbook bug. The old runbook ran `npm run migrate` from `main` before traffic,
  which would have applied 002 with no traffic running. That breaks criterion 4: "covers every deploy and every migration".
  New runbook:
  - initial migrate + seed from the `../v1` worktree (schema 001 only);
  - 002 and 003 applied under traffic;
  - `new-clients.txt` set to 0.3 only once both instances run v2;
  - traffic kept running after 003.

  Also: `migrate:down` evidence now includes 001; the runbook no longer says `git tag v1` (the tag already exists);
  a "source of truth: PDF → README → CLAUDE.md" rule; a note to start instances one at a time.
- **v2** (`src/app.js`): reads `price`, writes `price` + `price_vnd` in ONE statement on both write paths
  (`INSERT … (name, price, price_vnd)` and `UPDATE … SET price = ?, price_vnd = ?`).
  Accepts `price` or `priceVnd`. `priceVnd` must be a positive safe integer ≤ 100,000,000; if both are sent they must agree, else 400.
  Responses are `{id, name, price, priceVnd}` with `priceVnd = Math.round(price*1000)`. `/orders` is unchanged (reads `price`).
- **Tests** (`test/app.test.js`): first test now expects `priceVnd`. New tests read the DB directly to show both columns
  are written by PATCH and POST (from `price` and from `priceVnd`), plus the validation cases. `npm test` 8/8 pass.
- **Rehearsal by the assistant** (scratchpad DB, ports 3101/3102, log in scratchpad; not `data/app.db`, not `traffic-log.txt`):
  - A=v2 + B=v1 (copied from tag v1 with `git archive`, no worktree created), traffic 16 s;
  - B restarted as v2;
  - `0.3` written to the share file → log line `new clients 0 -> 0.3`;
  - `RESULT: zero failed requests`, check `disagree 0`.

  The first attempt had 40 `unavailable`. The assistant's script started A and B at the same instant, A crashed on
  `database is locked` (starter `db.js` sets WAL before `busy_timeout`), and then B was killed. This was a fault of the test
  script, not of v2. Rerun with a 1 s gap was clean. `src/db.js` was NOT changed.

Asked for: follow the PDF first, fix CLAUDE.md where it is wrong, then continue.
Kept: v2 dual write (`price` + `price_vnd` in ONE statement) on both write paths; the `priceVnd` validation rules; the "PDF -> README -> CLAUDE.md" source-of-truth rule; `src/db.js` unchanged.
Changed: CLAUDE.md runbook (002/003 applied under traffic, initial migrate + seed from the v1 worktree, `migrate:down` evidence includes 001, no `git tag v1`); `src/app.js` (v2); `test/app.test.js` (8/8 pass).
Rejected: running `npm run migrate` from `main` before traffic (it breaks criterion 4); changing `db.js` to avoid the `database is locked` crash (fault of the test script, not of v2).
By hand: I told the assistant to follow the PDF first and fix CLAUDE.md where it was wrong; the assistant's rehearsal is not evidence, I run the real deploys myself.

## 2026-10-14 — step 4: backfill script
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 3

Response (summary): wrote `scripts/backfill.js` and added `"backfill"` to `package.json`.
- Uses `open()` from `src/db.js`, so it honours `DB_PATH`.
- Refuses to run if `price` or `price_vnd` is missing.
- Each batch (`BATCH`, default 500 rows) is its own `BEGIN IMMEDIATE … COMMIT`, with a pause between batches (`PAUSE_MS`, default 50).
- Fixes rows where `price IS NOT NULL AND (price_vnd IS NULL OR price_vnd <> CAST(round(price*1000) AS INTEGER))`,
  which is the same rounding as the server and `check.js`.
- Walks by id with a cursor; prints progress and the final remaining NULL / disagree / NULL-price counts.

Rehearsals by the assistant, on scratchpad DBs only, deleted after:
1. Stop and rerun. Seeded DB, then simulated "v2 wrote" on 1/7 of the rows, "v1 re-priced afterwards" on 1/14 (stale `price_vnd`),
   and one row with NULL price. Before: `disagree 1428`, INCONSISTENT. Run 1 was killed after 0.4 s. Run 2 finished with
   0 NULL and 0 disagree. Run 3 found 0 rows to fix, so it is idempotent. `check` then said "CONSISTENT, but 1 rows have
   no price_vnd". That row is the simulated NULL-price row, which cannot occur in the real run: seed, v1 and v2 all require a price.
2. Under traffic. Two v2 instances, traffic 12 s with new clients 0.3, backfill run in the middle (37 batches, 1.9 s).
   Result: `RESULT: zero failed requests`, then `check` gave plain `CONSISTENT`.

Asked for: the next step.
Kept: batched backfill (own `BEGIN IMMEDIATE ... COMMIT` per batch, pause between batches, id cursor), idempotent, honours `DB_PATH`, same rounding as the server and `check.js`.
Changed: new `scripts/backfill.js`; `"backfill"` added to `package.json`.
Rejected: a NULL-only backfill condition, since it misses rows that v1 re-priced after v2 dual-wrote them.
By hand: the real backfill on `data/app.db` under traffic, including the interrupt and the rerun, is mine to run.

## 2026-10-14 — step 5: code v3 (reads price_vnd)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 4

Response (summary):
- **`src/app.js` → v3.**
  - `SELECT id, name, price_vnd` on list and get; `price = price_vnd / 1000`, `priceVnd = price_vnd`.
  - `/orders` uses `price_vnd / 1000` as `unit_price` (old unit).
  - Writes are unchanged from v2: both columns in one statement, so v3 → v2 stays safe.
  - No fallback to `price` when `price_vnd` is NULL. v3 relies on the backfill having finished; after that,
    v2/v3 always write both columns.
- **`test/app.test.js`.**
  - The fixture inserts `price_vnd` too, as the backfill would have.
  - New test: change only `price_vnd` in the DB and see GET and list follow it, which proves reads come from the new column.
  - The order test also checks `order_items.unit_price` is still in thousands.
  - `npm test` 9/9.

Rehearsal by the assistant (scratchpad DB and a `git archive v2` copy, ports 3101/3102, all deleted after):
migrate → seed → backfill, then two v2 instances and traffic for 24 s with new clients 0.3.
Sequence: rolling v2→v3, check `CONSISTENT`, rollback v3→v2 rolling, check `CONSISTENT`, v2→v3 again, check `CONSISTENT`.
One instance at a time: 6 down/back pairs, `RESULT: zero failed requests`.
Asked for: the next step.
Kept: v3 still writes both columns, so v3 -> v2 rollback stays safe; `price = price_vnd / 1000` in responses and in `/orders` `unit_price`.
Changed: `src/app.js` (v3 reads `price_vnd`); `test/app.test.js` (fixture inserts `price_vnd`, new read-source test, 9/9 pass).
Rejected: a fallback to `price` when `price_vnd` is NULL; v3 relies on the finished backfill.
By hand: the real rolling v2 -> v3, the rollback and the checks around them are mine to run.

## 2026-10-14 — step 6: code v4 + migration 003 (contract)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 5

Response (summary):
- **`src/app.js` → v4.** Neither reads nor writes `price`: `INSERT … (name, price_vnd)`, `UPDATE … SET price_vnd = ?`.
  Every response still has `price = price_vnd / 1000`, and old clients may still send `price` (converted).
- **Migration 003.**
  - `003_drop_price.up.sql`: `DROP COLUMN price`.
  - `.down.sql`: re-adds `price REAL CHECK (price > 0)` and fills it from `price_vnd / 1000.0`, with a comment that this
    restores values, not the pre-drop column.
- **`test/app.test.js`.**
  - The fixture inserts only `price_vnd`, since all migrations are applied and `price` is gone.
  - New tests: the column is gone, and GET one / list / PATCH / POST all still return a numeric `price`.
  - `npm test` 11/11.

Rehearsals by the assistant (scratchpad DBs and `git archive v3` copies, deleted after):
1. **v3 → v4 → 003 under traffic.**
   - v3 on both, traffic 14 s with new clients 0.3.
   - Rolling v3 → v4. check: `disagree 1936`, `INCONSISTENT`, expected because v4 no longer writes `price`.
   - `npm run migrate` (003) under traffic. check: `CONSISTENT`.
   - Traffic: `RESULT: zero failed requests`.
2. **v3 code on schema 003** crashes at start: `table menu_items has no column named price`.
3. **migrate:down chain.** The sequence in CLAUDE.md was wrong: `seed` fails after 003 because `seed.js` inserts `price`.
   Fixed in CLAUDE.md: migrate 001 + 002 from the v3 copy, seed, backfill, migrate 003, then `migrate:down` ×3 with checks.
   - down 003 → `disagree 0`, CONSISTENT;
   - down 002 → CONSISTENT;
   - down 001 → check fails with "no such table", which is expected.

Open decision 2 raised with me (check after v4 says INCONSISTENT); my answer is in the next entry.
Asked for: the next step.
Kept: responses still expose a numeric `price` derived from `price_vnd`; 003 `.down.sql` restores values from `price_vnd` (and says so in a comment); 003 lives only in the v4 commit.
Changed: `src/app.js` (v4, no read/write of `price`); migrations `003_drop_price.up/down.sql`; `test/app.test.js` (11/11 pass); CLAUDE.md `migrate:down` sequence (`seed` fails after 003).
Rejected: the old `migrate:down` sequence in CLAUDE.md; v3 code on schema 003 (crashes at start, shown in the rehearsal).
By hand: I answered open decision 2 (next entry); the real 003 under traffic and the `migrate:down` x3 evidence are mine to run.

## 2026-10-14 — decision: check after v4 (open decision 2)
Tool: Claude Code (Opus 5.5), multiple-choice question.
Prompt: answered the assistant's question "check after v4 says INCONSISTENT; how to record it?" by choosing
"Ghi thật + drop ngay (Recommended)".
Response (summary): recorded in CLAUDE.md.
- Run check after v4 and keep the INCONSISTENT output with a label that explains it.
- Apply 003 immediately after, then check again (CONSISTENT).
- MIGRATION.md will say `price` is a dead column once v4 is on both instances.

The alternative (skip the v4 check) was rejected: the PDF asks for a check "after every step".
By hand: the choice.

## 2026-10-14 — step 7: runbook for the one real run
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 6

Response (summary): wrote `RUNBOOK.md`, the exact command sequence for the single real run (4 terminals, worktrees `../v1`…`../v4`).
- Schema 001 is created from `../v1`, 002 is applied from `../v2`, 003 from `../v4`, so each migration happens under traffic.
- `step` / `logrun` shell helpers add labelled, UTC-timed entries to `check-log.txt`.
- `new-clients.txt` gets 0.3 after v2 is on both instances.
- The backfill is interrupted on purpose, then rerun.
- v3 → v2 → v3 rollback with checks before and after.
- The v4 check is labelled "EXPECTED INCONSISTENT", then 003 is applied right after.
- The `migrate:down` evidence uses a separate DB.

CLAUDE.md now points to RUNBOOK.md.

Rehearsal by the assistant of the whole sequence, in compressed form (scratchpad DB and logs, `git archive` copies instead of worktrees,
about 35 s of traffic; deleted after):
- 0 CONSISTENT
- 1 "CONSISTENT, but … no price_vnd yet"
- 2 INCONSISTENT (`disagree 5`). This is exactly the v1-overwrites-v2 case found in step 1, and it confirms the backfill must fix
  disagreeing rows, not only NULLs.
- 3a interrupted, partial
- 3 CONSISTENT
- 4 / 4R / 4F CONSISTENT
- 5 INCONSISTENT (expected)
- 6 CONSISTENT

Traffic: 20 down/back lines, `new clients 0 -> 0.3` logged, `RESULT: zero failed requests`, 0 server errors.
The real run has NOT been done; that is mine to do.
Asked for: the next step.
Kept: the 4-terminal layout, worktrees `../v1`..`../v4`, `step`/`logrun` helpers, 002 and 003 applied under traffic, the v4 check labelled "EXPECTED INCONSISTENT", a separate DB for `migrate:down`.
Changed: new `RUNBOOK.md`; CLAUDE.md now points to it.
Rejected: treating the compressed rehearsal as run evidence; it is only a rehearsal.
By hand: the real run itself, with every command typed in the four terminals by me.

## 2026-10-14 — "xong bước 7", but no run evidence found
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 7

Response (summary): looked before writing anything, with read-only commands (`git log`, `git status`, `git worktree list`, `ls`, `find`).
- No `traffic-log.txt` or `check-log.txt` in the repo (nor in the parent folder).
- No worktrees `../v1`…`../v4`.
- `data/app.db` is 4 KB, which means empty: never seeded, no 20,000 items.

So the real run has not happened, at least not in this folder. The assistant wrote no MIGRATION.md or SELF_ASSESSMENT from
non-existent logs, and asked me to check.
Files changed: this log only.

## 2026-10-14 — question about RUNBOOK.md: "T4 (control) only"
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> T4 Control only là sao?

Response (summary): explained the 4 terminals.
- T1 = instance A (:3001), T2 = instance B (:3002), T3 = traffic, T4 = control (migrate, backfill, check).
- "T4 (control) only" means the `step` / `logrun` helpers are defined only in T4. Shell functions exist only in the
  terminal where they are defined, and only T4 runs checks.
- `export DB_PATH=…` must be run in all 4 terminals.

Files changed: this log only.

## 2026-10-14 — question about RUNBOOK.md section 6 (which terminal?)
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> phần số 6 này là sao? chạy trên teminar nào? [pasted RUNBOOK section 6]

Response (summary): explained that section 6 is three rolling restarts in a row: v2→v3, rollback v3→v2, v2→v3 again.
Each round: T1 Ctrl+C + start, wait for "3001 back" in T3, then T2 the same, then a `step` in T4.
Rewrote RUNBOOK sections 4, 6 and 7 as a 5-action table that names the terminal for every action. Same commands, clearer layout.
Files changed: `RUNBOOK.md`, this log.

## 2026-10-14 — first real run: 28,894 failed requests, diagnosis + RUNBOOK hardening
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> ở mục số 10, tôi thựuc hiện thì nó báo lỗi" [pasted output of RUNBOOK section 10, ending in `Error: no such table: menu_items`]

Response (summary):
- **Section 10 error.** Expected: after reverting 001 there is no table, and the D3 label already says so. The D1/D2 outputs
  are good `migrate:down` evidence.
- **The real problem: my first real run failed.** The assistant read (did not edit) `traffic-log.txt` and `check-log.txt`.
  The log ends `RESULT: 28894 failed requests` (unavailable 682, stale 28070, contract 142).
  Diagnosis, from log times (traffic started 11:09:30Z):
  1. Migration 002 was applied at ~11:08:40Z, **before** traffic started. Steps 0/1 appear twice; the second "step 0"
     already shows `price_vnd`. So 002 is not covered by the log.
  2. At 145.8 s / 146.6 s **both** instances went down within 0.8 s → 682 `UNAVAILABLE`, during the backfill.
     Then they came back at 166.7 s / 202.4 s, apparently as v3, since step 4 is labelled v3.
     Also, the backfill was not interrupted (it ran to the end in 18 s), so "3a" is not an interruption.
  3. Rollback v3→v2 at 301–325 s was fine.
  4. "4F · FORWARD again" was written at 342 s with **no restart** between 4R and 4F. The next rolling (351–393 s) put
     A on v4 while B was still **v2**.

     Proof: every STALE / CONTRACT line comes via `:3002` between 363.9 s and 385.9 s. The contract body
     `{"price":null,"priceVnd":null}` has v2's shape: v2 reads `price`, which v4 no longer writes, and v4-created rows have
     `price` NULL. With v3 next to v4 this cannot happen.

  Conclusion: operational mistakes, not code bugs. The code was rehearsed clean in the same sequence.
- **RUNBOOK.md hardened.**
  - `who` shows the real worktree of each port's process (tested by the assistant); every `step` now records `who` too.
  - Checkpoint: traffic must be running before 002.
  - Never Ctrl+C T1 and T2 together.
  - The backfill is interrupted automatically with SIGINT after 4 s (tested in zsh on a scratch DB: stopped with 12,200 NULLs left).
  - Each rollback round must show 2 new down/back pairs.
  - `rm` without zsh globs.
- **Recommendation.** Redo the run from scratch: the criteria 4/5 top bands need zero failures. Keep the failed logs outside the
  repo, and mention the failed first attempt honestly.

The assistant did not delete, move or edit any log.
Kept: the diagnosis that the failures were operational mistakes, not code bugs; the recommendation to redo the run from scratch; mentioning the failed first attempt honestly in the documents.
Changed: `RUNBOOK.md` only: `who` check and `who` recorded in every `step`, traffic-running checkpoint before 002, never Ctrl+C T1 and T2 together, automatic SIGINT for the backfill after 4 s, 2 new down/back pairs required per rollback round, `rm` without zsh globs. No logs and no code were touched.
Rejected: submitting the run with 28,894 failed requests as final; editing or deleting the failed logs; blaming the code.
By hand: I ran the first attempt myself (it failed); I redid the run from scratch with the hardened runbook, and the committed logs from that run show zero failed requests.

## 2026-10-14 — step 8: MIGRATION.md + SELF_ASSESSMENT_REPORT.md drafts
Tool: Claude Code (Opus 5.5).
Prompt (verbatim):
> xong bước 7

Response (summary): read my committed `traffic-log.txt` (45 lines, `RESULT: zero failed requests`, 5 rolling restarts
one instance at a time, new clients 0 → 0.3 at line 11) and `check-log.txt` (every step labelled, with `who` confirming versions).
Drafted from them:
- `MIGRATION.md`:
  - version table, and the plan table (7 steps × 4 columns);
  - proposed point of no return = step 6 (003). The final sentence is marked **TODO (student)**;
  - why v3 → v2 is safe and v4 → v2 is not;
  - explanation of the two expected INCONSISTENT checks (step 2 `disagree 9`, step 5 `disagree 1926`);
  - backfill notes, an evidence map with line numbers;
  - disclosures: traffic.js patch, live-run.sh, failed first attempt; a PostgreSQL lock note.
- `SELF_ASSESSMENT_REPORT.md`: one row per criterion with evidence line ranges, and "what I did not manage".
  The marks (18/19/14/17/14/9 = 91) are the assistant's **suggestion**, kept conservative (C4 lowered because of the
  traffic.js patch). I must review them, add my student ID, and name the zip with the final total.

`npm test` 11/11 on the current main.
Kept: the structure of `MIGRATION.md` (version table, 7-step plan, why v3 -> v2 is safe and v4 -> v2 is not, the two expected INCONSISTENT checks, evidence map with line numbers, disclosures) and the one-row-per-criterion layout of the self-assessment.
Changed: new `MIGRATION.md` and `SELF_ASSESSMENT_REPORT.md`, drafted from my committed logs; no code change.
Rejected: inventing evidence or numbers not present in `traffic-log.txt` / `check-log.txt`; leaving the marks as final without my review.
By hand: still to do: write the point-of-no-return sentence (marked TODO), review the suggested marks (91 total), add my student ID, name the zip with the final total.
