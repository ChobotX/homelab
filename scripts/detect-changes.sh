#!/usr/bin/env bash
# Categorize changed files between BASE..HEAD into role-buckets so the deploy
# DAG can skip unchanged app roles.
#
# Buckets (written to $GITHUB_OUTPUT):
#   observability / traefik / vaultwarden / jellyfin / syncthing / homepage / backup — per-role
#   shared — set when anything outside a specific role touches the deploy
#            surface (playbooks, group_vars, common role, requirements,
#            deploy-tags action, smoke/prewarm scripts, ci.yml). When shared
#            is true, every app bucket is forced to true upstream.
#
# Fall-back behaviour:
#   - BASE is empty / zero-SHA (first push, branch re-creation): emit all true.
#   - GITHUB_EVENT_NAME=schedule: emit all true (weekly drift heal).
#   - Any git error while diffing: emit all true (conservative — we'd rather
#     run an extra job than silently skip a reconverge).
#
# Usage (CI):
#   scripts/detect-changes.sh "$BASE_SHA" "$HEAD_SHA"
#   (BASE_SHA comes from github.event.before on push; for schedule/dispatch the
#    caller passes an empty string and we force-full.)
set -euo pipefail

BASE="${1:-}"
HEAD="${2:-HEAD}"

out() {
  # shellcheck disable=SC2154
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
  printf '  %-18s %s\n' "$1" "$2" >&2
}

force_full() {
  local reason="$1"
  echo "detect-changes: forcing full fan-out — $reason" >&2
  for b in shared observability traefik vaultwarden jellyfin syncthing homepage backup; do
    out "$b" true
  done
  exit 0
}

# Drift heal + first-push + no-base + explicit dispatch → everything.
if [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; then
  force_full "schedule (weekly drift heal)"
fi
if [ -z "$BASE" ] || [ "$BASE" = "0000000000000000000000000000000000000000" ]; then
  force_full "empty/zero BASE (branch creation or first push)"
fi

# Diff. If git returns non-zero (e.g. BASE unreachable after a force-push or
# shallow-clone truncation), fall back to full.
if ! files=$(git diff --name-only "$BASE" "$HEAD" 2>/dev/null); then
  force_full "git diff $BASE..$HEAD failed"
fi

if [ -z "$files" ]; then
  # No file changes — nothing to deploy, but infra + backup + finalize still
  # run (they don't check this output). Emit all false.
  echo "detect-changes: no file changes in $BASE..$HEAD" >&2
  for b in shared observability traefik vaultwarden jellyfin syncthing homepage backup; do
    out "$b" false
  done
  exit 0
fi

shared=false
obs=false
traefik=false
vw=false
jellyfin=false
syncthing=false
hp=false
backup=false

# ── Shared surface — anything here forces every app bucket to run.
#    Kept in one regex so additions are obvious.
shared_re='^(ansible/playbooks/|ansible/group_vars/|ansible/requirements\.yml$|\.ansible-version$|ansible/roles/common/|\.github/actions/deploy-tags/|\.github/workflows/ci\.yml$|scripts/smoke-deploy\.sh$|scripts/prewarm-images\.sh$|scripts/detect-changes\.sh$|bootstrap\.sh$)'

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    ansible/roles/observability/*) obs=true ;;
    ansible/roles/traefik/*)       traefik=true ;;
    ansible/roles/vaultwarden/*)   vw=true ;;
    ansible/roles/jellyfin/*)      jellyfin=true ;;
    ansible/roles/syncthing/*)     syncthing=true ;;
    ansible/roles/homepage/*)      hp=true ;;
    ansible/roles/backup/*)        backup=true ;;
  esac
  # Shared check runs independently — a file can be both role-scoped and
  # shared (common/defaults triggers everything), and regex is the simpler
  # test for the "many possible paths" list.
  if echo "$f" | grep -Eq "$shared_re"; then
    shared=true
  fi
done <<< "$files"

# Shared implies every app bucket — simpler than repeating `|| shared` in
# every job's `if:`.
if [ "$shared" = true ]; then
  obs=true; traefik=true; vw=true; jellyfin=true; syncthing=true; hp=true; backup=true
fi

echo "detect-changes: $(echo "$files" | wc -l | tr -d ' ') files changed in $BASE..$HEAD" >&2
out shared "$shared"
out observability "$obs"
out traefik "$traefik"
out vaultwarden "$vw"
out jellyfin "$jellyfin"
out syncthing "$syncthing"
out homepage "$hp"
out backup "$backup"
