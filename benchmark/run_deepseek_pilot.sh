#!/usr/bin/env bash
# Orchestrates the full DeepSeek pilot: N repetitions x 2 conditions
# (hook|nohook) x the case list below, run_case_opencode_deepseek.sh per
# unit, fanned out with xargs -P, with a real-dollar cost cap enforced by
# a watchdog that polls actual usage.json cost_usd (not an estimate) and
# kills the whole process tree the instant the cap is crossed.
#
# Usage:
#   REPS=3 OUT_DIR=/path/to/output benchmark/run_deepseek_pilot.sh
#
# Env vars (all optional except OUT_DIR):
#   OUT_DIR        where results go (required - no default, so a run can
#                  never silently land somewhere unintended)
#   REPS           repetitions per case/condition (default: 10)
#   JOBS           parallel workers (default: 4)
#   COST_CAP_USD   hard spend cap in real dollars (default: 10)
#   MODEL_ID       opencode model spec (default: deepseek/deepseek-flash -
#                  `opencode models deepseek` is the source of truth, this
#                  catalog has been renamed before)
#
# Requires (see README.md in this directory for the full setup):
#   - this branch checked out (the script pins itself to opencode-deepseek
#     so results are never accidentally attributed to a different harness
#     version)
#   - go build -o yul . run once at the repo root
#   - apptainer build benchmark/opencode-sandbox.sif benchmark/opencode-sandbox.def
#   - opencode auth login -p deepseek (interactively, on the host - this
#     script and run_case_opencode_deepseek.sh never read or hold the key)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "opencode-deepseek" ]; then
  echo "ABORT: expected branch opencode-deepseek, got $CURRENT_BRANCH" >&2
  exit 1
fi

: "${OUT_DIR:?OUT_DIR is required - e.g. OUT_DIR=/path/to/output $0}"
REPS="${REPS:-10}"
JOBS="${JOBS:-4}"
COST_CAP_USD="${COST_CAP_USD:-10}"
MODEL_ID="${MODEL_ID:-deepseek/deepseek-flash}"

export YUL_BIN="$REPO/yul"
export OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
export CASES_JSON="$REPO/benchmark/cases_top.json"
export OUT_DIR MODEL_ID

command -v "$OPENCODE_BIN" >/dev/null 2>&1 || { echo "opencode not found (set OPENCODE_BIN or put it on PATH)" >&2; exit 1; }
[ -x "$YUL_BIN" ] || { echo "$YUL_BIN not built - run: go build -o yul . at the repo root" >&2; exit 1; }

CASES=(
  pypi-top-01-requests
  pypi-top-05-urllib3
  maven-top-01-junit
  maven-top-06-spring-data-jpa
  npm-top-04-to-regex-range
  npm-top-10-fresh
  go-top-06-x-net
  cargo-top-01-libc
  ghactions-top-01-checkout
  ghactions-top-09-docker-buildx
)

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/progress.log"
: > "$LOG"

total_cost() {
  find "$OUT_DIR" -name usage.json -exec jq -r '.cost_usd // 0' {} \; 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

# The one xargs unit of work: run_case_opencode_deepseek.sh for one
# (case, condition, rep), logging START/OK/FAIL to stdout (redirected to
# $LOG by the caller below).
worker() {
  local CASE_ID="$1" CONDITION="$2" REP="$3"
  echo "START $CASE_ID $CONDITION rep$REP $(date +%H:%M:%S)"
  if bash "$REPO/benchmark/run_case_opencode_deepseek.sh" "$CASES_JSON" "$CASE_ID" "$CONDITION" "$OUT_DIR" "$MODEL_ID" "$REP"; then
    echo "OK $CASE_ID $CONDITION rep$REP $(date +%H:%M:%S)"
  else
    echo "FAIL $CASE_ID $CONDITION rep$REP $(date +%H:%M:%S)"
  fi
}
export -f worker
export REPO CASES_JSON YUL_BIN OPENCODE_BIN MODEL_ID OUT_DIR

pipeline() {
  for CASE_ID in "${CASES[@]}"; do
    for CONDITION in nohook hook; do
      for REP in $(seq 1 "$REPS"); do
        echo "$CASE_ID $CONDITION $REP"
      done
    done
  done | xargs -P "$JOBS" -n 3 bash -c 'worker "$@"' _
}

# `set -m` (job control) makes the backgrounded pipeline its own real
# process group, with $! as its live, correctly-tracked PID - verified
# empirically against a fake harness before ever trusting it with real
# spend. (setsid without -w was tried first: it forks/execs and returns
# immediately, so $! ends up pointing at an already-dead wrapper and a
# kill against it is a silent no-op on the actual live workers.)
set -m
pipeline >> "$LOG" 2>&1 &
MAIN_PID=$!
set +m
PGID=$(ps -o pgid= -p "$MAIN_PID" 2>/dev/null | tr -d " ")

echo "pipeline pid=$MAIN_PID pgid=$PGID cost_cap_usd=$COST_CAP_USD reps=$REPS jobs=$JOBS model=$MODEL_ID" >> "$LOG"

while kill -0 "$MAIN_PID" 2>/dev/null; do
  sleep 15
  COST=$(total_cost)
  echo "watchdog: cumulative cost_usd=$COST" >> "$LOG"
  if awk -v c="$COST" -v cap="$COST_CAP_USD" 'BEGIN{exit !(c>=cap)}'; then
    echo "ABORT_COST_LIMIT: cost_usd=$COST >= cap=$COST_CAP_USD - killing pgid=$PGID" >> "$LOG"
    kill -TERM -- "-$PGID" 2>/dev/null
    sleep 3
    kill -KILL -- "-$PGID" 2>/dev/null
    echo "ALL_DONE (aborted, cost cap hit) $(date) final_cost_usd=$(total_cost)" >> "$LOG"
    exit 1
  fi
done

echo "ALL_DONE $(date) final_cost_usd=$(total_cost)" >> "$LOG"
