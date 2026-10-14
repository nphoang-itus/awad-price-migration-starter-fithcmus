# SELF_ASSESSMENT_REPORT.md — IA#2 zero-downtime migration

Student ID: 23120264 · zip name: `23120264_91.zip` (the total in the table below)

| # | Criterion | Max | Claimed | Evidence |
|---|---|---|---|---|
| 1 | The plan | 20 | 18 | `MIGRATION.md` "The plan": 7 rows × 4 columns (schema after · code per instance · exact undo command · versions that can still run). Point of no return = step 6 / `003_drop_price`, with the reason. Rows match tags `v1`–`v4` and `migrations/002_*`, `003_*` |
| 2 | Expand and dual write | 20 | 19 | `migrations/002_add_price_vnd.up.sql` (own migration, nullable). v1 keeps serving on it: check-log step 1 (lines 10–18), traffic-log lines 4–9. Tag `v2`, `src/app.js`: `INSERT … (name, price, price_vnd)` and `UPDATE … SET price = ?, price_vnd = ?`. Tests "PATCH with price writes both columns", "POST /menu writes both columns…" at tag v2. `priceVnd` offered and `price` still returned. `.down.sql` for 001/002/003. `migrate:down` run once for each on `data/scratch.db`: check-log lines 122–190 |
| 3 | Backfill | 15 | 14 | `scripts/backfill.js`: 200/500-row batches, each its own `BEGIN IMMEDIATE … COMMIT`, pause between. Run under traffic only with v2 on both (`who` lines in check-log 35–37, 53–55). Interrupted (step 3a, 14,249 NULL left, lines 29–43) and rerun (lines 44–51). `CONSISTENT` right after (step 3, lines 53–61) |
| 4 | Zero failed requests | 20 | 17 | `traffic-log.txt` lines 2–45: one continuous run from v1 to 30 s after 003, `RESULT: zero failed requests` (line 45). Down/back for one instance at a time at lines 6–9, 15–19, 21–25, 27–31, 33–37. New clients 0 → 0.3 right after v2 is on both (line 11) |
| 5 | The way back | 15 | 14 | Under traffic, v3 (reads `price_vnd`) → v2 → v3: traffic-log lines 21–25 (rollback) and 27–31 (forward), zero failures. Check `CONSISTENT` before (step 4, check-log 63–71) and after (4R 73–81, 4F 83–91). `MIGRATION.md` "Why the rollback v3 → v2 is safe…" names v4 → v2 as unsafe |
| 6 | Contract | 10 | 9 | `price` dropped only with v4 on both: check-log step 5 / 6 headers show `:3001 → v4`, `:3002 → v4` (lines 93–111). 003 under traffic, log clean to the end (traffic-log 38–45). Tag `v4` test "every endpoint still returns a numeric price after the drop" |
| | **Total** | **100** | **91** | |

## What I did not manage, or what may cost marks

- **Patched `scripts/traffic.js`.** A small change, disclosed in MIGRATION.md and AI-LOG.md: the new-client share is re-read
  from a file. Without it, one continuous log with `NEW_CLIENTS > 0` after v2 is impossible. If the patch is not accepted,
  criterion 4 drops to the 11–16 band. That is why I claim 17 there, not 20.
- **The first manual run failed** (28,894 failed requests: 002 applied before traffic, both instances stopped together,
  v4 deployed next to v2). The submitted logs are a second run, driven by `scripts/live-run.sh`, an automated version of
  my runbook written with Claude Code (AI-LOG.md).
- **Check after step 2 shows `disagree 9` (INCONSISTENT)**, from the short v1/v2 overlap. The backfill fixed it, and this
  is explained in MIGRATION.md.
- **Check after step 5 is INCONSISTENT by design** (v4 stops writing `price`). I dropped the column right after.
- **The `003` down migration restores values from `price_vnd`, not the original column.**
