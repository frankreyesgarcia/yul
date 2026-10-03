#!/usr/bin/env bash
# Runs every case in <cases.json> under both conditions (hook|nohook),
# <reps> times each, via run_case_opencode_deepseek.sh - one isolated
# container per run, <jobs> runs at a time, in shuffled order so a
# partial batch is spread across ecosystems instead of being one block.
#
# Resumable: a run whose transcript.jsonl already exists is skipped, so
# re-invoking with the same <output_dir> picks up where it left off.
#
# Usage:
#   run_all_opencode_deepseek.sh <cases.json> <output_dir> [jobs] [reps] [timeout_secs]
#
# GITHUB_TOKEN is read from the environment, or from `gh auth token` if
# unset, once up front - and handed to workers through a chmod 600 file
# rather than re-running gh per worker.
# Portable on macOS: no shuf/timeout (coreutils) needed.
set -euo pipefail

CASES_JSON="$1"
OUT_DIR="$2"
JOBS="${3:-8}"
REPS="${4:-3}"
TIMEOUT_SECS="${5:-900}"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$BENCH_DIR")"
CASES_JSON="$(cd "$(dirname "$CASES_JSON")" && pwd)/$(basename "$CASES_JSON")"
# docker -v needs an absolute host path; a relative one is taken as a
# named volume.
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

export CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

TOKEN_FILE="$(mktemp)"
chmod 600 "$TOKEN_FILE"
trap 'rm -f "$TOKEN_FILE"' EXIT
printf '%s' "${GITHUB_TOKEN:-$(gh auth token)}" > "$TOKEN_FILE"
[ -s "$TOKEN_FILE" ] || { echo "no GITHUB_TOKEN and \`gh auth token\` returned nothing" >&2; exit 1; }

{
  echo "started: $(date -u +%FT%TZ)"
  echo "git: $(git -C "$REPO_DIR" rev-parse HEAD)$(git -C "$REPO_DIR" diff --quiet || echo ' (dirty)')"
  echo "opencode-yul: ${OPENCODE_YUL_VERSION:-0.0.21}"
  echo "image: $(docker images -q "${DOCKER_IMAGE:-yul-opencode-sandbox}" | head -1)"
  echo "jobs=$JOBS reps=$REPS timeout=${TIMEOUT_SECS}s"
} >> "$OUT_DIR/batch_meta.txt"

run_one() {
  local case_id="$1" cond="$2" rep="$3"
  local dir="$OUT_DIR/$case_id/$cond/run-$rep"
  if [ -f "$dir/transcript.jsonl" ]; then
    echo "skip: $case_id [$cond] run-$rep"
    return 0
  fi
  GITHUB_TOKEN="$(cat "$TOKEN_FILE")" \
    bash "$BENCH_DIR/run_case_opencode_deepseek.sh" "$CASES_JSON" "$case_id" "$cond" "$OUT_DIR" deepseek/deepseek-flash "$rep" &
  local pid=$!
  ( sleep "$TIMEOUT_SECS"; kill -TERM "$pid" 2>/dev/null ) &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  if [ "$rc" -eq 143 ]; then
    echo "TIMEOUT: $case_id [$cond] run-$rep"
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL($rc): $case_id [$cond] run-$rep"
  fi
}
export -f run_one
export OUT_DIR CASES_JSON BENCH_DIR TOKEN_FILE TIMEOUT_SECS

jq -r '.[].id' "$CASES_JSON" | while read -r id; do
  for cond in hook nohook; do
    for r in $(seq 1 "$REPS"); do
      printf '%s %s %02d\n' "$id" "$cond" "$r"
    done
  done
done \
  | awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort -n | cut -f2- \
  | xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _ \
  2>&1 | tee -a "$OUT_DIR/batch.log"

echo "finished: $(date -u +%FT%TZ)" >> "$OUT_DIR/batch_meta.txt"
