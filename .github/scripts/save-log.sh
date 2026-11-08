#!/usr/bin/env bash
# Saves a result file to the build-logs branch, trying again if two jobs collide.
# Usage: save-log.sh <source file> <name on the branch> <commit message>
set -u
SRC="$1"
NAME="$2"
MESSAGE="$3"
CONTENT="$(mktemp)"
cp "$SRC" "$CONTENT"
git config user.name "plant-cam-bot"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
for attempt in 1 2 3 4 5; do
  git fetch origin build-logs 2>/dev/null || true
  if git rev-parse --verify origin/build-logs >/dev/null 2>&1; then
    git checkout -f -B build-logs origin/build-logs
  else
    git checkout -f --orphan build-logs
    git rm -rf --quiet . 2>/dev/null || true
  fi
  cp "$CONTENT" "$NAME"
  git add "$NAME"
  git commit -m "$MESSAGE" || true
  if git push origin build-logs; then
    exit 0
  fi
  sleep $((attempt * 3))
done
echo "Couldn't save the log"
exit 0
