#!/usr/bin/env bash
# nidhogg-line.sh ARTIFACT...: Nidhogg's integration line for drgnx-tiers.yml's `nidhogg: line`. Resolves the branch
# named in .github/ci/nidhogg-line to its head, then finds Nidhogg's newest successful build run (build.yml) of that
# commit that still holds every ARTIFACT (tarball-fedora-45, tarball-macos). Prints `commit=SHA` and `run=ID` (for
# GITHUB_OUTPUT). No such run: one error line and exit 1, never the release instead.
# GH_TOKEN: a token that reads Nidhogg's Actions (an App token with Actions: read; an artifact download needs one even
# on a public repository). docs/develop/ci.md, "Nidhogg's integration line"
set -euo pipefail
repo=${NIDHOGG_REPO:-Black-Dragon-Foundation/nidhogg}
[ $# -gt 0 ] || { echo "usage: nidhogg-line.sh ARTIFACT..." >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
branch=$(grep -v '^[[:space:]]*\(#\|$\)' "$here/nidhogg-line" | head -n 1 | tr -d '[:space:]')
[ -n "$branch" ] || { echo "::error::.github/ci/nidhogg-line names no branch"; exit 1; }
sha=$(git ls-remote "https://github.com/$repo.git" "refs/heads/$branch" | cut -f1)
[ -n "$sha" ] || { echo "::error::Nidhogg has no branch $branch (.github/ci/nidhogg-line); push it, or name the line there"; exit 1; }
for run in $(gh api "repos/$repo/actions/workflows/build.yml/runs?head_sha=$sha&status=success&per_page=20" --jq '.workflow_runs[].id'); do
  have=$(gh api "repos/$repo/actions/runs/$run/artifacts?per_page=100" --jq '.artifacts[] | select(.expired | not) | .name')
  ok=1
  for a in "$@"; do grep -qx -- "$a" <<< "$have" || ok=0; done
  if [ "$ok" = 1 ]; then
    echo "commit=$sha"
    echo "run=$run"
    exit 0
  fi
done
echo "::error::no successful Nidhogg build run of $branch's head ${sha:0:12} holds $* (expired, missing or still running): run Nidhogg's Build on it; drgnx's line mode never falls back to the release"
exit 1
