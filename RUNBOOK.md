# RUNBOOK — the one real run (IA#2)

The exact sequence behind `traffic-log.txt` and `check-log.txt`. One traffic run, from v1 to after migration 003.
The student runs every command. This file was drafted by Claude Code (see AI-LOG.md).

Rubric points it is built to show:
- **C4:** one continuous log covering every deploy **and every migration**, down/back for one instance at a time, `NEW_CLIENTS > 0` after v2.
- **C3:** backfill only when no v1 is serving, stopped once and restarted, `CONSISTENT` right after it.
- **C5:** v3 → v2 → v3 under traffic, `CONSISTENT` before and after.
- **C6:** drop only with v4 on both instances.
- **C2:** `migrate:down` for each migration, in check-log.

## 0. Before you start (once)

```bash
cd ~/Developer/hcmus/advanced-web/IA02/awad-price-migration-starter-fithcmus
R=$PWD
git status                                  # clean, HEAD = tag v4
for v in v1 v2 v3 v4; do git worktree add ../$v $v; done   # one directory per deployed version
git worktree list
```

**Which directory is used for what:**
- `../v2`: applies **only 002**. Tag v2 contains 001 and 002, but not 003.
- `../v4`: applies **003**.
- `$R` (main = v4 + scripts): runs `traffic`, `backfill` and `check`. Its `traffic.js` is the patched one; `../v1` still has the old one.

**Open 4 terminals.** Run this in **each** of them:

```bash
R=~/Developer/hcmus/advanced-web/IA02/awad-price-migration-starter-fithcmus
export DB_PATH="$R/data/app.db"             # absolute: every version uses this one file
```

**T4 (control) only:**

```bash
cd "$R"
# a labelled check, with a UTC time to match the ISO start time in traffic-log.txt
step() { { echo; echo "=== STEP $1 · $(date -u +%H:%M:%S)Z"; } | tee -a "$R/check-log.txt";
         npm run -s check 2>&1 | tee -a "$R/check-log.txt"; }
# run a command and keep its output in check-log.txt too
logrun() { echo "\$ $*" | tee -a "$R/check-log.txt"; "$@" 2>&1 | tee -a "$R/check-log.txt"; }
```

**Rules for the whole run:**
- Restart **one instance at a time**.
- Before touching B, wait for both:
  1. A's terminal shows `menu service on :3001`;
  2. T3 shows `http://localhost:3001 back`.

  Never stop B while A is down. That counts as `unavailable` (downtime).
- If an instance crashes on start with `database is locked`, just start it again; the other instance keeps serving.
  This is starter `db.js`: WAL is set before `busy_timeout`.
- Do **not** stop or restart traffic (T3) until the end.

## 1. Fresh database, schema 001 only (T4)

```bash
rm -f "$R"/data/app.db* "$R/traffic-log.txt" "$R/check-log.txt" "$R/new-clients.txt"
(cd ../v1 && npm run migrate && npm run seed)   # NOT from $R: main would also apply 002 and 003
```

## 2. Start v1 on both instances and start traffic

```bash
# T1
cd "$R/../v1" && PORT=3001 npm start
# T2 (only after T1 printed "menu service on :3001")
cd "$R/../v1" && PORT=3002 npm start
# T3: leave running to the end; new-clients.txt does not exist yet, so the new-client share is 0
cd "$R" && npm run traffic
```

Wait ~15 s for a few `ok=` lines, then in T4:

```bash
step "0 · baseline · schema 001 · A=v1 B=v1"
```

## 3. Step 1: migration 002, under traffic (T4)

```bash
(cd ../v2 && npm run migrate) 2>&1 | tee -a check-log.txt   # must print only "applied 002_add_price_vnd"
step "1 · schema 002 (price_vnd added, nullable) · A=v1 B=v1"
```

Expected: `CONSISTENT, but 20000+ rows have no price_vnd yet`.

## 4. Step 2: rolling restart v1 → v2

```bash
# T1: Ctrl+C, then:
cd "$R/../v2" && PORT=3001 npm start
# wait for "3001 back" in T3, then T2: Ctrl+C, then:
cd "$R/../v2" && PORT=3002 npm start
# wait for "3002 back" in T3
```

T4:

```bash
step "2 · schema 002 · A=v2 B=v2 (dual write on both)"
echo 0.3 > "$R/new-clients.txt"            # both instances now offer priceVnd
```

- Check T3 for `new clients 0 -> 0.3`.
- The check in step 2 may show `disagree > 0` (`INCONSISTENT`). A row that v2 wrote and v1 then re-priced, in the few
  seconds when A=v2 and B=v1, keeps a stale `price_vnd`. That is expected and the backfill fixes it.
  **Keep the output as is**; MIGRATION.md explains it.

## 5. Step 3: backfill. Stop it once, then rerun (T4)

Only now: no v1 is serving.

```bash
BATCH=200 PAUSE_MS=100 npm run backfill 2>&1 | tee -a check-log.txt   # press Ctrl+C after 3-4 progress lines
step "3a · backfill interrupted on purpose · A=v2 B=v2"
logrun npm run -s backfill                  # rerun: finishes the rest
step "3 · after backfill · A=v2 B=v2"        # must be plain CONSISTENT
```

## 6. Step 4: rolling v2 → v3, then the rollback v3 → v2 → v3 (C5)

```bash
# T1: Ctrl+C → cd "$R/../v3" && PORT=3001 npm start ; wait "3001 back"
# T2: Ctrl+C → cd "$R/../v3" && PORT=3002 npm start ; wait "3002 back"
step "4 · schema 002 · A=v3 B=v3 (reads price_vnd) · before rollback"

# rollback, same pattern, to ../v2
# T1: Ctrl+C → cd "$R/../v2" && PORT=3001 npm start ; wait "3001 back"
# T2: Ctrl+C → cd "$R/../v2" && PORT=3002 npm start ; wait "3002 back"
step "4R · ROLLBACK · schema 002 · A=v2 B=v2"

# forward again to ../v3
# T1: Ctrl+C → cd "$R/../v3" && PORT=3001 npm start ; wait "3001 back"
# T2: Ctrl+C → cd "$R/../v3" && PORT=3002 npm start ; wait "3002 back"
step "4F · FORWARD again · schema 002 · A=v3 B=v3"
```

All three must be `CONSISTENT`. Note the T3 times of these six down/back lines, for SELF_ASSESSMENT.

## 7. Step 5: rolling v3 → v4, then drop right away (C6)

```bash
# T1: Ctrl+C → cd "$R/../v4" && PORT=3001 npm start ; wait "3001 back"
# T2: Ctrl+C → cd "$R/../v4" && PORT=3002 npm start ; wait "3002 back"
step "5 · schema 002 · A=v4 B=v4 · EXPECTED INCONSISTENT: v4 no longer writes price, so price is now a dead column"
```

## 8. Step 6: migration 003, under traffic, immediately after (T4)

```bash
(cd ../v4 && npm run migrate) 2>&1 | tee -a check-log.txt   # must print only "applied 003_drop_price"
step "6 · schema 003 (price dropped) · A=v4 B=v4 · POINT OF NO RETURN"
```

## 9. End

- Let traffic run **30–60 s more** after 003. The PDF says the log must go to "after the last migration".
- Then press **Ctrl+C in T3**. The last lines must be `FINAL …` and `RESULT: zero failed requests`.
- Stop T1 and T2 with Ctrl+C.
- T4: `step "end · traffic stopped"`.

## 10. `migrate:down` evidence on a separate DB (C2)

Run in T4. It uses a separate DB file, so the real one is untouched.

```bash
export DB_PATH="$R/data/scratch.db"; rm -f "$R"/data/scratch.db*
echo -e "\n=== MIGRATE:DOWN EVIDENCE · separate DB data/scratch.db" | tee -a check-log.txt
(cd ../v3 && npm run migrate) 2>&1 | tee -a check-log.txt       # 001 + 002 only
logrun npm run -s seed
logrun npm run -s backfill
logrun npm run -s migrate                                          # 003
step "D0 · scratch · schema 003"
logrun npm run -s migrate:down; step "D1 · scratch · after migrate:down (reverted 003)"
logrun npm run -s migrate:down; step "D2 · scratch · after migrate:down (reverted 002)"
logrun npm run -s migrate:down; step "D3 · scratch · after migrate:down (reverted 001) · 'no such table' expected"
export DB_PATH="$R/data/app.db"
```

## 11. After the run

```bash
grep -nE "down|back|new clients|RESULT|FINAL" traffic-log.txt   # line numbers for SELF_ASSESSMENT
grep -n "=== STEP" check-log.txt
git add traffic-log.txt check-log.txt
git commit -m "evidence: one continuous traffic run v1 -> v4 + 003, labelled checks"
for v in v1 v2 v3 v4; do git worktree remove ../$v; done   # optional, after the run
```

If anything fails mid-way (a FAIL line in T3): stop, do not edit any log, and bring the output back to the assistant.
Either explain it in MIGRATION.md (C4 band 4–10) or start everything over from step 1 with a clean log.
