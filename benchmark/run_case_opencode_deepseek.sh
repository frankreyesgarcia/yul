#!/usr/bin/env bash
# Runs one benchmark case under one condition (hook|nohook), same as
# run_case_opencode.sh, but against DeepSeek's API via OpenCode's built-in
# "deepseek" provider (models.dev catalog) instead of a self-hosted,
# OpenAI-compatible endpoint - no custom provider config needed.
#
# The actual `opencode run` happens inside a fresh container per invocation
# (only this run's own WORKDIR bind-mounted) - a model's bash/read tools
# can't see sibling runs' directories at all, unlike the un-sandboxed
# version, where a run was caught `cat`-ing a completed sibling
# repetition's manifest instead of doing the task itself.
#
# Runtime is auto-detected (apptainer preferred, docker as fallback) or
# forced via CONTAINER_RUNTIME=apptainer|docker. Build the image once:
#   apptainer build benchmark/opencode-sandbox.sif benchmark/opencode-sandbox.def
#   docker build -t yul-opencode-sandbox -f benchmark/Dockerfile.opencode-sandbox benchmark/
#
# Credentials come from OpenCode's own store (`opencode auth login`, saved
# to ~/.local/share/opencode/auth.json), not an env var - this script never
# reads or holds the API key, so it can't leak it. (Earlier versions passed
# DEEPSEEK_API_KEY through the environment; a run's bash tool dumped its own
# env and the real key ended up in a committed transcript. See the
# opencode-deepseek branch history.)
#
# Usage:
#   run_case_opencode_deepseek.sh <cases.json> <case_id> <hook|nohook> <output_dir> [model_id] [repeat_index]
#
#   model_id      opencode model spec provider/model (default:
#                 deepseek/deepseek-flash - `opencode models deepseek` is the
#                 source of truth here, the catalog has renamed this before).
#   repeat_index  if set, run output goes to <condition>/run-<repeat_index>/
#                 instead of directly under <condition>/ - use for repeated
#                 runs of the same case/condition.
#
# Env vars:
#   YUL_BIN            path to the yul binary the hook condition execs
#                       (default: "yul" on PATH; build one with `go build -o yul .`)
#   OPENCODE_BIN        path to the opencode binary (default: "opencode" on PATH)
#   CONTAINER_RUNTIME   "apptainer" or "docker" - forces which one to use
#                       instead of auto-detecting (apptainer preferred when
#                       both are on PATH, since that's what the cluster runs)
set -euo pipefail

CASES_JSON="$1"
CASE_ID="$2"
CONDITION="$3"   # hook | nohook
OUT_DIR="$4"
MODEL_ID="${5:-deepseek/deepseek-flash}"
REPEAT_INDEX="${6:-}"

YUL_BIN="${YUL_BIN:-yul}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
command -v "$OPENCODE_BIN" >/dev/null 2>&1 || { echo "opencode not found (set OPENCODE_BIN or put it on PATH)" >&2; exit 1; }
if [ "$CONDITION" = "hook" ]; then
  command -v "$YUL_BIN" >/dev/null 2>&1 || { echo "yul not found (set YUL_BIN or put it on PATH)" >&2; exit 1; }
fi

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${CONTAINER_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  if command -v apptainer >/dev/null 2>&1; then
    RUNTIME="apptainer"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  else
    echo "neither apptainer nor docker found on PATH (set CONTAINER_RUNTIME to force one)" >&2
    exit 1
  fi
fi

case "$RUNTIME" in
  apptainer)
    command -v apptainer >/dev/null 2>&1 || { echo "apptainer not found on PATH" >&2; exit 1; }
    SIF_IMAGE="$BENCH_DIR/opencode-sandbox.sif"
    [ -f "$SIF_IMAGE" ] || { echo "$SIF_IMAGE not found - build it with: apptainer build $SIF_IMAGE $BENCH_DIR/opencode-sandbox.def" >&2; exit 1; }
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH" >&2; exit 1; }
    DOCKER_IMAGE="${DOCKER_IMAGE:-yul-opencode-sandbox}"
    # `docker image inspect` (not `docker images -q`) reports "No such
    # image" for a name that `docker run`/`docker images` resolves fine -
    # seen live on Docker Desktop's containerd image store, where a build
    # with provenance/SBOM attestations produces a manifest list `inspect`
    # doesn't resolve by name the same way `images`/`run` do.
    [ -n "$(docker images -q "$DOCKER_IMAGE" 2>/dev/null)" ] || { echo "docker image '$DOCKER_IMAGE' not found - build it with: docker build -t $DOCKER_IMAGE -f $BENCH_DIR/Dockerfile.opencode-sandbox $BENCH_DIR" >&2; exit 1; }
    ;;
  *)
    echo "unknown CONTAINER_RUNTIME '$RUNTIME' (expected apptainer or docker)" >&2
    exit 1
    ;;
esac

case_json() {
  jq -c --arg id "$CASE_ID" '.[] | select(.id == $id)' "$CASES_JSON"
}

C="$(case_json)"
if [ -z "$C" ]; then
  echo "case $CASE_ID not found" >&2
  exit 1
fi

# .manifest is usually a single path, but a case may instead give an array
# of candidate paths - only meaningful for "fresh" cases, since an
# "existing" case needs one fixed path to seed.
MANIFEST=$(echo "$C" | jq -r 'if (.manifest|type)=="array" then .manifest[0] else .manifest end')
TYPE=$(echo "$C" | jq -r '.type')
PROMPT=$(echo "$C" | jq -r '.prompt')
SEED=$(echo "$C" | jq -r '.seed // empty')

WORKDIR="$OUT_DIR/$CASE_ID/$CONDITION"
if [ -n "$REPEAT_INDEX" ]; then
  WORKDIR="$WORKDIR/run-$REPEAT_INDEX"
fi
# Same read-only-directory trap as $CONTAINER_HOME's cleanup below, but for
# WORKDIR itself: a crashed or interrupted prior attempt (e.g. the
# apptainer SIGABRT seen live during the pilot) can leave a partially
# populated Go module cache under here (a case's toolchain download dir
# lives inside WORKDIR, not just CONTAINER_HOME), and rm -rf chokes on its
# read-only module directories every single retry, since the leftover
# never actually gets removed. chmod first so retries can't get stuck on
# their own prior failure.
chmod -R u+w "$WORKDIR" 2>/dev/null || true
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/.opencode/plugins"

if [ "$TYPE" = "existing" ]; then
  mkdir -p "$(dirname "$WORKDIR/$MANIFEST")"
  printf '%s' "$SEED" > "$WORKDIR/$MANIFEST"
fi

# "deepseek" is a built-in OpenCode provider (models.dev catalog); it reads
# the credential from OpenCode's own store (see the top of this file), not
# an env var. write/edit checking is the published "opencode-yul" npm
# package (chains-project/yul's own opencode-yul/ subdirectory) instead of
# a hand-rolled copy - it downloads and caches its own pinned yul release
# binary (currently v0.0.14), independent of $YUL_BIN below.
if [ "$CONDITION" = "hook" ]; then
  cat > "$WORKDIR/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-yul"]
}
EOF
else
  cat > "$WORKDIR/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json"
}
EOF
fi

if [ "$CONDITION" = "hook" ]; then
  # opencode-yul (above) is now the published npm package, v0.0.17 - it
  # covers Write, Edit, and Bash natively (PR #60), with the narrower
  # write-target-aware bash regex (PR #65) - so this local plugin no longer
  # needs to duplicate any of that. All it still adds is the auth-store-read
  # block, which isn't upstream anywhere yet: the run's DeepSeek API key
  # lives in OpenCode's own credential store (auth login, not an env var -
  # see the top of this script), so this is the one exfiltration path a
  # model could still go looking for.
  cat > "$WORKDIR/.opencode/plugins/yul-auth-guard.js" <<'EOF'
const AUTH_STORE_RE = /\.local[/\\]share[/\\]opencode[/\\]auth\.json|opencode[/\\]auth\.json/i

function mentionsAuthStore(args) {
  if (typeof args === "string") return AUTH_STORE_RE.test(args)
  if (Array.isArray(args)) return args.some(mentionsAuthStore)
  if (args && typeof args === "object") return Object.values(args).some(mentionsAuthStore)
  return false
}

export const YulAuthGuardPlugin = async () => {
  return {
    "tool.execute.before": async (_input, output) => {
      if (mentionsAuthStore(output.args)) {
        throw new Error("yul: reading OpenCode's credential store is not permitted")
      }
    },
  }
}
EOF
fi

cd "$WORKDIR"

# Cap `git rev-parse --show-toplevel` at WORKDIR so the model can't wander
# up into the real yul checkout and find real files that make it think the
# task's already done.
git init -q
git config user.email "benchmark@example.com"
git config user.name "benchmark"

# Captured to a tempfile outside WORKDIR, not directly to transcript.jsonl/
# stderr.log - the model's cwd is WORKDIR itself, so writing the live log
# there means the model can see (and, observed in practice, delete) its own
# run's log mid-session. Moved into place only after the run finishes.
TRANSCRIPT_TMP=$(mktemp)
STDERR_TMP=$(mktemp)

# One fresh container per run (apptainer or docker, see RUNTIME above):
# binding only this run's own WORKDIR means the model's bash/read tools
# can't see sibling runs' directories at all (a real cross-run
# contamination bug found by review - a model literally
# `cat ../run-1/pom.xml`'d another repetition's already-corrected
# manifest instead of doing the task). The apptainer-specific rationale
# below (--containall/--no-mount bind-paths/resolv.conf) doesn't apply to
# the docker branch - see the comment there instead.
#
# --containall --no-mount bind-paths are load-bearing, not decorative: this
# cluster's system-wide apptainer.conf has `bind path = /proj`, which
# Apptainer auto-mounts into every container at the same absolute path
# regardless of the explicit --bind list below - without opting out, the
# model could still `cat /proj/.../run-1/pom.xml` and see a sibling rep,
# same bug as before just via an absolute path instead of a relative one.
# Verified empirically: /proj is unreachable inside the container with
# these two flags, present without them.
#
# --containall's minimal /etc also drops the host's /etc/resolv.conf, which
# breaks DNS for the actual DeepSeek API call - bound back in explicitly
# below (read-only) since it doesn't reintroduce any of the /proj exposure
# the two flags above are closing.
#
# Cache dirs: yul's release binary and the opencode-yul plugin package are
# shared read-write across all containers (safe to race on - worst case is
# a redundant re-download, no per-run data in either). Everything under
# .local/share/opencode (sessions, snapshots, its own log) is NOT shared -
# each run gets a throwaway one, with only auth.json bind-mounted in
# read-only from the real one, so the container can authenticate without
# ever seeing another run's session state or writing into the real one.
SHARED_CACHE="$OUT_DIR/.container-shared-cache"
mkdir -p "$SHARED_CACHE/yul" "$SHARED_CACHE/opencode-pkg"
CONTAINER_HOME=$(mktemp -d)
mkdir -p "$CONTAINER_HOME/.local/share/opencode"
if [ -f "$HOME/.local/share/opencode/auth.json" ]; then
  cp "$HOME/.local/share/opencode/auth.json" "$CONTAINER_HOME/.local/share/opencode/auth.json"
fi

# --thinking makes OpenCode's --format json stream emit {"type":"reasoning",
# "part":{...,"text":...}} events, same as it already does for "text" - by
# default that part type is only tracked internally as a tokens.reasoning
# count (step-finish), the actual content is dropped before it reaches the
# JSON stream. Without this flag, transcript.jsonl has no way to show what
# the model actually reasoned through before writing a manifest.
if [ "$RUNTIME" = "apptainer" ]; then
  apptainer exec \
    --containall \
    --no-mount bind-paths \
    --home "$CONTAINER_HOME:/home/sandbox" \
    --bind "$WORKDIR:/work" \
    --bind /etc/resolv.conf:/etc/resolv.conf:ro \
    --bind "$SHARED_CACHE/yul:/home/sandbox/.cache/yul" \
    --bind "$SHARED_CACHE/opencode-pkg:/home/sandbox/.cache/opencode" \
    --bind "$(command -v "$OPENCODE_BIN"):/usr/local/bin/opencode:ro" \
    --bind "$(command -v "$YUL_BIN"):/usr/local/bin/yul:ro" \
    --env YUL_BIN=/usr/local/bin/yul \
    --pwd /work \
    "$SIF_IMAGE" \
    opencode run "$PROMPT" \
    --model "$MODEL_ID" \
    --auto \
    --format json \
    --thinking \
    > "$TRANSCRIPT_TMP" 2> "$STDERR_TMP" || true
else
  # Docker equivalent of the apptainer block above. --containall/--no-mount
  # bind-paths have no docker counterpart because they exist only to opt
  # out of a *cluster-wide* apptainer.conf auto-mount (`bind path = /proj`)
  # that doesn't apply here - docker never shares host paths unless you
  # pass -v, so there's nothing implicit to close off. Same reasoning for
  # dropping the /etc/resolv.conf bind: docker's own embedded DNS (the
  # bridge network's 127.0.0.11 resolver) already forwards to the host
  # correctly without it.
  #
  # --user "$(id -u):$(id -g)" mirrors apptainer's default (run as the
  # invoking host user, not root) - without it, docker runs as root and
  # everything written under the /work bind mount (the manifest files
  # run_case_opencode_deepseek.sh reads back afterward) ends up
  # root-owned on the host, which breaks the chmod/rm -rf cleanup on the
  # *next* run of this same case under an unprivileged user.
  #
  # opencode is NOT bind-mounted here (unlike the apptainer branch) - see
  # the Dockerfile.opencode-sandbox comment: it's baked into the image at
  # build time instead, since bind-mounting the host's own binary fails
  # with "exec format error" whenever the host isn't Linux/same-arch as
  # the image (verified live on macOS). $YUL_BIN is still bound in, but
  # nothing inside the container execs it (see the comment above the
  # apptainer bind for the same path), so it's harmless either way.
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/home/sandbox \
    -e YUL_BIN=/usr/local/bin/yul \
    -v "$CONTAINER_HOME:/home/sandbox" \
    -v "$WORKDIR:/work" \
    -v "$SHARED_CACHE/yul:/home/sandbox/.cache/yul" \
    -v "$SHARED_CACHE/opencode-pkg:/home/sandbox/.cache/opencode" \
    -v "$(command -v "$YUL_BIN"):/usr/local/bin/yul:ro" \
    -w /work \
    "$DOCKER_IMAGE" \
    opencode run "$PROMPT" \
    --model "$MODEL_ID" \
    --auto \
    --format json \
    --thinking \
    > "$TRANSCRIPT_TMP" 2> "$STDERR_TMP" || true
fi

# Belt-and-suspenders: the yul-auth-guard.js plugin above blocks reads of
# the auth store, but redact anything DeepSeek-key-shaped that slips through
# anyway (format is public: "sk-" + 32 hex chars) - this doesn't require
# knowing the actual configured key, so it still works after rotation.
sed -i -E 's/sk-[a-f0-9]{32}/***REDACTED-DEEPSEEK-API-KEY***/g' "$TRANSCRIPT_TMP" "$STDERR_TMP"

mv "$TRANSCRIPT_TMP" transcript.jsonl
mv "$STDERR_TMP" stderr.log

# Per-run token/cost summary, aggregated from each step's usage. cost_usd
# is DeepSeek's real dollar cost as OpenCode's pricing table reports it.
jq -s '
  [.[] | select(.type=="step_finish")] as $steps
  | {
      llm_calls: ($steps | length),
      tokens: {
        input: ($steps | map(.part.tokens.input // 0) | add // 0),
        output: ($steps | map(.part.tokens.output // 0) | add // 0),
        cache_read: ($steps | map(.part.tokens.cache.read // 0) | add // 0),
        cache_write: ($steps | map(.part.tokens.cache.write // 0) | add // 0)
      },
      cost_usd: ($steps | map(.part.cost // 0) | add // 0)
    }
' transcript.jsonl > usage.json

# Direct proof of which provider/model actually served this run: OpenCode's
# transcript never records it, but its own runtime log does. Each run has
# its own throwaway container $HOME now, so this log is already isolated
# to this run alone - the sessionID filter is just extra safety.
OPENCODE_LOG="$CONTAINER_HOME/.local/share/opencode/log/opencode.log"
# `jq ... | head -1` (the previous form here) is a `set -o pipefail` trap:
# head can close its end of the pipe right after reading one line, jq gets
# SIGPIPE, and pipefail turns that into a nonzero exit that kills the whole
# script under `set -e` - intermittently, depending on timing, which is
# exactly what silently dropped ~1/3 of a live pilot run's model_used.log/
# session_export.json/final_manifest before this got caught. jq's own
# `first(inputs | ...)` stays inside one process, so there's no pipe to race.
SESSION_ID=$(jq -rn 'first(inputs | select(.sessionID != null) | .sessionID) // empty' transcript.jsonl 2>/dev/null)
if [ -n "$SESSION_ID" ] && [ -f "$OPENCODE_LOG" ]; then
  grep -F "session.id=$SESSION_ID" "$OPENCODE_LOG" | grep -E "providerID=|llm\.provider=" > model_used.log || true
else
  : > model_used.log
fi

# Full session export, straight from this run's own throwaway OpenCode data
# dir - unlike transcript.jsonl (the printer's --format json stream, which
# --thinking only partially widens), the session storage on disk is
# OpenCode's own source of truth and already holds every part type
# untouched, reasoning included. $CONTAINER_HOME only ever held this run's
# data in the first place (see the apptainer/docker exec block above), so
# no sessionID filtering is needed here the way it is for model_used.log -
# there's nothing else in it to filter out. Run directly on the host (no
# container needed): this just reads local files already produced by
# the finished container run, no model-directed code executes here.
SESSION_EXPORT_TMP=$(mktemp)
if [ -n "$SESSION_ID" ]; then
  HOME="$CONTAINER_HOME" "$OPENCODE_BIN" export "$SESSION_ID" > "$SESSION_EXPORT_TMP" 2>/dev/null || true
fi
sed -i -E 's/sk-[a-f0-9]{32}/***REDACTED-DEEPSEEK-API-KEY***/g' "$SESSION_EXPORT_TMP"
mv "$SESSION_EXPORT_TMP" session_export.json

# Go's module cache (under $CONTAINER_HOME/go/pkg/mod for a go.mod case)
# marks downloaded module directories read-only by design - go clean
# -modcache is the only sanctioned way to remove it because of exactly
# this, plain rm -rf fails partway through with "Permission denied" on a
# read-only dir under set -e, silently killing the script right after
# session_export.json but before final_manifest ever got written. Caught
# live: every go-top-06-x-net rep in a pilot batch failed this way.
chmod -R u+w "$CONTAINER_HOME" 2>/dev/null || true
rm -rf "$CONTAINER_HOME"

# When .manifest listed several candidate paths, use whichever one the
# model actually wrote.
FOUND_MANIFEST=""
shopt -s nullglob
while IFS= read -r candidate; do
  if [[ "$candidate" == *"*"* ]]; then
    matches=( $candidate )
    if [ ${#matches[@]} -gt 0 ]; then
      FOUND_MANIFEST="${matches[0]}"
      break
    fi
  elif [ -f "$candidate" ]; then
    FOUND_MANIFEST="$candidate"
    break
  fi
done < <(echo "$C" | jq -r 'if (.manifest|type)=="array" then .manifest[] else .manifest end')
shopt -u nullglob

if [ -n "$FOUND_MANIFEST" ]; then
  cp "$FOUND_MANIFEST" "final_manifest"
  echo "$FOUND_MANIFEST" > "final_manifest_path"
else
  echo "MANIFEST_NOT_WRITTEN" > final_manifest
fi

# Removed below so the run output doesn't end up with a nested-repo
# gitlink when committed.
rm -rf .git

echo "done: $CASE_ID [$CONDITION] -> $WORKDIR"
