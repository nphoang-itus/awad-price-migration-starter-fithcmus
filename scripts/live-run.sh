#!/bin/bash
# The whole IA#2 sequence of RUNBOOK.md, automated, for ONE continuous traffic run:
#   v1 → 002 → v2 → backfill (interrupted + rerun) → v3 → rollback v2 → v3 → v4 → 003,
# then the migrate:down evidence on a separate DB. Written by Claude Code (see AI-LOG.md);
# the student runs it:   bash scripts/live-run.sh
#
# Needs the worktrees ../v1 ../v2 ../v3 ../v4 (git worktree add ../vN vN) and ports 3001/3002 free.
# OUT (default: repo root) is where traffic-log.txt / check-log.txt go; DB defaults to data/app.db.
# It refuses to start if those logs already exist (traffic.js appends; one clean run only).
set -u
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
OUT=${OUT:-$R}; DB=${DB:-$R/data/app.db}; SCRATCH=${SCRATCH:-$R/data/scratch.db}
TL=$OUT/traffic-log.txt; CL=$OUT/check-log.txt; NC=$OUT/new-clients.txt; ILOG=$OUT/instances.log
W=$(cd "$R/.." && pwd)
export DB_PATH=$DB

die() { echo "ABORT: $*" | tee -a "$CL"; [ -n "${T:-}" ] && kill -INT $T 2>/dev/null; sleep 1; stop_port 3001; stop_port 3002; exit 1; }
pidof_port() { lsof -ti tcp:$1 -sTCP:LISTEN 2>/dev/null | head -1; }
ver_of_port() { local pid; pid=$(pidof_port $1); [ -z "$pid" ] && { echo DOWN; return; }
  basename "$(lsof -a -d cwd -p $pid -Fn | sed -n 's/^n//p')"; }
who() { echo ":3001 → $(ver_of_port 3001)"; echo ":3002 → $(ver_of_port 3002)"; }
stop_port() { local pid; pid=$(pidof_port $1); [ -z "$pid" ] && return 0; kill -TERM $pid
  for i in $(seq 1 50); do [ -z "$(pidof_port $1)" ] && return 0; sleep 0.2; done; return 1; }
start_port() { # start_port v3 3001 : start, retry on the starter's "database is locked" race, wait for /health
  for try in 1 2 3; do
    (cd "$W/$1" && exec env PORT=$2 node src/server.js >>"$ILOG" 2>&1) &
    for i in $(seq 1 25); do curl -sf localhost:$2/health >/dev/null && return 0; sleep 0.2; done
    echo "  (start of $1 on :$2 failed, try $try)"; done
  return 1; }
count() { local n; n=$(grep -c "$1" "$TL" 2>/dev/null); echo "${n:-0}"; }
backs() { count "localhost:$1 back"; }
roll_one() { local v=$1 p=$2 before; before=$(backs $p)
  stop_port $p || die "could not stop :$p"
  start_port $v $p || die "could not start $v on :$p"
  for i in $(seq 1 75); do [ "$(backs $p)" -gt "$before" ] && break; sleep 0.2; done
  [ "$(backs $p)" -gt "$before" ] || echo "  (warning: no 'back' line for :$p yet; it answers /health)"
  [ "$(ver_of_port $p)" = "$v" ] || die ":$p runs $(ver_of_port $p), expected $v"
  sleep 2; }
roll() { echo ">>> rolling restart to $1"; roll_one $1 3001; roll_one $1 3002; }
step() { # step "label" expected-version : refuse a label that `who` does not confirm
  if [ -n "${2:-}" ]; then for p in 3001 3002; do
    [ "$(ver_of_port $p)" = "$2" ] || die "step '$1': :$p runs $(ver_of_port $p), expected $2"; done; fi
  { echo; echo "=== STEP $1 · $(date -u +%H:%M:%S)Z"; who; } | tee -a "$CL"
  npm run -s check 2>&1 | tee -a "$CL"; }
logrun() { echo "\$ $*" | tee -a "$CL"; "$@" 2>&1 | tee -a "$CL"; }

# ---- preflight ---------------------------------------------------------------
for v in v1 v2 v3 v4; do
  [ -d "$W/$v" ] || { echo "missing worktree ../$v (git worktree add ../$v $v)"; exit 1; }
  [ "$(git -C "$W/$v" rev-parse HEAD)" = "$(git rev-parse $v^{commit})" ] || { echo "../$v is not at tag $v"; exit 1; }
done
[ -e "$TL" ] || [ -e "$CL" ] && { echo "traffic-log.txt / check-log.txt already exist in $OUT: move them away first"; exit 1; }
[ -n "$(pidof_port 3001)$(pidof_port 3002)" ] && { echo "ports 3001/3002 are in use: stop those instances first"; exit 1; }
rm -f "$NC" "$DB" "$DB-wal" "$DB-shm" "$ILOG"

# ---- 1. schema 001 + seed, v1 on both, traffic --------------------------------
(cd "$W/v1" && npm run -s migrate && npm run -s seed) || exit 1
start_port v1 3001 || die "v1 :3001"; start_port v1 3002 || die "v1 :3002"
LOG="$TL" NEW_CLIENTS_FILE="$NC" node scripts/traffic.js > /dev/null 2>&1 & T=$!
for i in $(seq 1 100); do [ "$(count 'ok=')" -ge 2 ] && break; sleep 0.2; done
grep -q "traffic start" "$TL" || die "traffic did not start"
step "0 · baseline · schema 001 · A=v1 B=v1" v1

# ---- 2. migration 002 under traffic (from ../v2: it has no 003) --------------
(cd "$W/v2" && npm run -s migrate) 2>&1 | tee -a "$CL"
step "1 · schema 002 (price_vnd added, nullable) · A=v1 B=v1" v1
sleep 5

# ---- 3. v1 → v2, then new clients on ----------------------------------------
roll v2
step "2 · schema 002 · A=v2 B=v2 (dual write on both)" v2
echo 0.3 > "$NC"; sleep 5

# ---- 4. backfill: interrupted on purpose, then rerun -------------------------
echo '$ backfill, stopped with SIGINT after 4 s (on purpose)' | tee -a "$CL"
{ BATCH=200 PAUSE_MS=100 node scripts/backfill.js & BF=$!; sleep 4; kill -INT $BF; wait $BF; } 2>&1 | tee -a "$CL"
step "3a · backfill interrupted on purpose · A=v2 B=v2" v2
logrun npm run -s backfill
step "3 · after backfill · A=v2 B=v2" v2
sleep 5

# ---- 5. v2 → v3, rollback v3 → v2, forward v2 → v3 ---------------------------
roll v3; step "4 · schema 002 · A=v3 B=v3 (reads price_vnd) · before rollback" v3; sleep 5
roll v2; step "4R · ROLLBACK · schema 002 · A=v2 B=v2" v2; sleep 5
roll v3; step "4F · FORWARD again · schema 002 · A=v3 B=v3" v3; sleep 5

# ---- 6. v3 → v4, then 003 right away -----------------------------------------
roll v4
step "5 · schema 002 · A=v4 B=v4 · EXPECTED INCONSISTENT: v4 no longer writes price, so price is now a dead column" v4
(cd "$W/v4" && npm run -s migrate) 2>&1 | tee -a "$CL"
step "6 · schema 003 (price dropped) · A=v4 B=v4 · POINT OF NO RETURN" v4

# ---- 7. traffic keeps going after the last migration, then stops -------------
echo ">>> traffic runs 30 s more after 003"; sleep 30
kill -INT $T; wait $T; TRC=$?
step "end · traffic stopped · A=v4 B=v4" v4
stop_port 3001; stop_port 3002

# ---- 8. migrate:down evidence on a separate DB -------------------------------
export DB_PATH=$SCRATCH; rm -f "$SCRATCH" "$SCRATCH-wal" "$SCRATCH-shm"
printf '\n=== MIGRATE:DOWN EVIDENCE · separate DB %s\n' "$(basename "$SCRATCH")" | tee -a "$CL"
(cd "$W/v3" && npm run -s migrate) 2>&1 | tee -a "$CL"
logrun npm run -s seed; logrun npm run -s backfill; logrun npm run -s migrate
step "D0 · scratch · schema 003"
logrun npm run -s migrate:down; step "D1 · scratch · after migrate:down (reverted 003)"
logrun npm run -s migrate:down; step "D2 · scratch · after migrate:down (reverted 002)"
logrun npm run -s migrate:down; step "D3 · scratch · after migrate:down (reverted 001) · 'no such table' expected"

echo; echo "================ SUMMARY"
grep -nE " (down|back)|new clients|FINAL|RESULT" "$TL"
grep -n "=== STEP" "$CL"
exit $TRC
