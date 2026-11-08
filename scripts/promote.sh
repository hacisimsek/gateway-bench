#!/usr/bin/env bash
# Promote what runs in one environment to the next, as a pull request: test -> preprod -> prod.
# Merging the PR is the deployment; Argo CD applies it within a minute.
# Usage: scripts/promote.sh test preprod | scripts/promote.sh preprod prod
set -euo pipefail
cd "$(dirname "$0")/.."

from=${1:?from}; to=${2:?to}
case "$from>$to" in "test>preprod" | "preprod>prod") ;; *) echo "only test>preprod or preprod>prod" >&2; exit 2 ;; esac
[[ -z $(git status --porcelain) ]] || { echo "commit or stash your changes first" >&2; exit 1; }

git fetch -q origin main
tag_of() { git show "origin/main:deploy/overlays/$1/kustomization.yaml" | grep -m1 -oE 'newTag: \S+' | cut -d' ' -f2; }
tag=$(tag_of "$from"); current=$(tag_of "$to")
[[ $tag != "$current" ]] || { echo "$to already runs $tag"; exit 0; }

back=$(git rev-parse --abbrev-ref HEAD)
branch="promote/$to-$tag"
git switch -q -c "$branch" origin/main
perl -pi -e "s/(newTag: ).*/\${1}$tag/" "deploy/overlays/$to/kustomization.yaml"
git commit -q -am "deploy($to): $tag (from $from)"
git push -q -u origin "$branch"
gh pr create --base main --head "$branch" --title "deploy($to): $tag" \
  --body "Promotes \`$tag\` from **$from** to **$to** (was \`$current\`). Merging deploys it: Argo CD syncs \`deploy/overlays/$to\`.

Commits in this promotion: https://github.com/hacisimsek/gateway-bench/compare/${current#sha-}...${tag#sha-}"
git switch -q "$back"
