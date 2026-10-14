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
# which code each instance REALLY runs: the directory (worktree) of the process listening on the port
who() { for p in 3001 3002; do pid=$(lsof -ti tcp:$p -sTCP:LISTEN);
          if [ -n "$pid" ]; then echo ":$p → $(basename "$(lsof -a -d cwd -p $pid -Fn | sed -n 's/^n//p')")";
          else echo ":$p → DOWN"; fi; done; }
# a labelled check, with a UTC time to match the ISO start time in traffic-log.txt,
# plus the real version of each instance (so the label can be verified)
step() { { echo; echo "=== STEP $1 · $(date -u +%H:%M:%S)Z"; who; } | tee -a "$R/check-log.txt";
         npm run -s check 2>&1 | tee -a "$R/check-log.txt"; }
# run a command and keep its output in check-log.txt too
logrun() { echo "\$ $*" | tee -a "$R/check-log.txt"; "$@" 2>&1 | tee -a "$R/check-log.txt"; }
```

**Rules for the whole run:**
- Restart **one instance at a time**. **Never press Ctrl+C in T1 and T2 at the same time** (first attempt: both down → 682 `UNAVAILABLE`).
- Before every `step`, run `who` in T4. It must show the versions the label says (e.g. `:3001 → v3`, `:3002 → v3`).
  If not, fix the instances first. Never write a label you have not seen in `who`.
- Before touching B, wait for both:
  1. A's terminal shows `menu service on :3001`;
  2. T3 shows `http://localhost:3001 back`.

  Never stop B while A is down. That counts as `unavailable` (downtime).
- If an instance crashes on start with `database is locked`, just start it again; the other instance keeps serving.
  This is starter `db.js`: WAL is set before `busy_timeout`.
- Do **not** stop or restart traffic (T3) until the end.

## 1. Fresh database, schema 001 only (T4)

```bash
who                                          # both must be DOWN; if not, Ctrl+C them in T1/T2 first
rm -f "$R"/data/app.db{,-wal,-shm} "$R/traffic-log.txt" "$R/check-log.txt" "$R/new-clients.txt"
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

**CHECKPOINT. Do not go on until T3 shows `=== traffic start …` AND at least two `ok=` lines.**
In the first attempt, 002 was applied ~50 s before traffic started, so that migration was not covered by the log.

Then in T4:

```bash
who                                          # :3001 → v1, :3002 → v1
step "0 · baseline · schema 001 · A=v1 B=v1"
```

## 3. Step 1: migration 002, under traffic (T4)

```bash
(cd ../v2 && npm run migrate) 2>&1 | tee -a check-log.txt   # must print only "applied 002_add_price_vnd"
step "1 · schema 002 (price_vnd added, nullable) · A=v1 B=v1"
```

Expected: `CONSISTENT, but 20000+ rows have no price_vnd yet`.

## 4. Step 2: rolling restart v1 → v2

**Rolling restart to `v2`, the same 5 actions every time:**

| # | Terminal | Action |
|---|---|---|
| 0 | **T4** | `who`: note what runs now |
| 1 | **T1** | press `Ctrl+C` (A stops; T3 prints `http://localhost:3001 down`; B serves everything) |
| 2 | **T1** | `cd "$R/../v2" && PORT=3001 npm start` and wait for `menu service on :3001` |
| 3 | **T3** | just look: wait for `http://localhost:3001 back` |
| 4 | **T2** | press `Ctrl+C`, then `cd "$R/../v2" && PORT=3002 npm start` and wait for `menu service on :3002` |
| 5 | **T3** | just look: wait for `http://localhost:3002 back` |
| 5b | **T4** | `who` must show both on the new version, before the `step` |

Then in **T4**:

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

The interruption is automatic: the backfill is stopped with SIGINT after 4 s. No Ctrl+C needed, so no risk of pressing it
in the wrong terminal.

```bash
who                                          # :3001 → v2, :3002 → v2 (no v1 left)
echo '$ backfill, stopped with SIGINT after 4 s (on purpose)' | tee -a check-log.txt
{ BATCH=200 PAUSE_MS=100 node scripts/backfill.js & BF=$!; sleep 4; kill -INT $BF; wait $BF; } 2>&1 | tee -a check-log.txt
step "3a · backfill interrupted on purpose · A=v2 B=v2"   # must still show price_vnd_null > 0
logrun npm run -s backfill                  # rerun: finishes the rest
step "3 · after backfill · A=v2 B=v2"        # must be plain CONSISTENT
```

## 6. Step 4: v2 → v3, then the rollback v3 → v2, then v2 → v3 again (C5)

There are three rounds. Each round is the same rolling restart as in section 4 (T1 → wait → T2 → wait), only the
directory changes. Each round ends with one `step` in **T4**.
**Each round must add 2 down/back pairs in T3.** If a `step` would follow no new down/back, you skipped a round.
In the first attempt, "4F" was written without the forward restart, then v4 went next to v2 → 28,000+ `STALE` + `CONTRACT`.

**Round 1: up to v3** (the version that reads `price_vnd`)

**Rolling restart to `v3`:**

| # | Terminal | Action |
|---|---|---|
| 0 | **T4** | `who`: note what runs now |
| 1 | **T1** | press `Ctrl+C` (A stops; T3 prints `http://localhost:3001 down`; B serves everything) |
| 2 | **T1** | `cd "$R/../v3" && PORT=3001 npm start` and wait for `menu service on :3001` |
| 3 | **T3** | just look: wait for `http://localhost:3001 back` |
| 4 | **T2** | press `Ctrl+C`, then `cd "$R/../v3" && PORT=3002 npm start` and wait for `menu service on :3002` |
| 5 | **T3** | just look: wait for `http://localhost:3002 back` |
| 5b | **T4** | `who` must show both on the new version, before the `step` |

Then **T4**: `step "4 · schema 002 · A=v3 B=v3 (reads price_vnd) · before rollback"` → must be `CONSISTENT`

**Round 2: ROLLBACK to v2.** Same 5 actions with `../v2` instead of `../v3`:
`cd "$R/../v2" && PORT=3001 npm start` in T1, then `cd "$R/../v2" && PORT=3002 npm start` in T2.

Then **T4**: `step "4R · ROLLBACK · schema 002 · A=v2 B=v2"` → must be `CONSISTENT`

**Round 3: FORWARD to v3 again.** Same 5 actions with `../v3`.

Then **T4**: `step "4F · FORWARD again · schema 002 · A=v3 B=v3"` → must be `CONSISTENT`

At the end, T3 shows 6 new down/back pairs, one instance at a time, with no `ERROR` / `STALE` / `UNAVAILABLE` lines.
Note their T3 times for SELF_ASSESSMENT.

## 7. Step 5: rolling v3 → v4, then drop right away (C6)

**Rolling restart to `v4`:**

| # | Terminal | Action |
|---|---|---|
| 0 | **T4** | `who`: note what runs now |
| 1 | **T1** | press `Ctrl+C` (A stops; T3 prints `http://localhost:3001 down`; B serves everything) |
| 2 | **T1** | `cd "$R/../v4" && PORT=3001 npm start` and wait for `menu service on :3001` |
| 3 | **T3** | just look: wait for `http://localhost:3001 back` |
| 4 | **T2** | press `Ctrl+C`, then `cd "$R/../v4" && PORT=3002 npm start` and wait for `menu service on :3002` |
| 5 | **T3** | just look: wait for `http://localhost:3002 back` |
| 5b | **T4** | `who` must show both on the new version, before the `step` |

Then **T4**: `step "5 · schema 002 · A=v4 B=v4 · EXPECTED INCONSISTENT: v4 no longer writes price, so price is now a dead column"`

Go straight on to section 8.

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
export DB_PATH="$R/data/scratch.db"; rm -f "$R"/data/scratch.db{,-wal,-shm}
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
