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
Kept: (to fill in after review)
Changed: (to fill in)
Rejected: (to fill in)
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
Kept: (to fill in)
Changed: (to fill in)
Rejected: (to fill in)
By hand: (to fill in)

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
Kept: (to fill in)
Changed: (to fill in)
Rejected: (to fill in)
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
Kept: (to fill in)
Changed: (to fill in)
Rejected: (to fill in)
By hand: (to fill in)

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
Kept: (to fill in)
Changed: (to fill in)
Rejected: (to fill in)
By hand: (to fill in)
