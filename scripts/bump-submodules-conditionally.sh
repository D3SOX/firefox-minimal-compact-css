#!/usr/bin/env bash

set -euo pipefail

# This script:
# 1) Lists used paths within submodules via list-used-submodule-paths.sh
# 2) Fetches upstream HEAD for each submodule
# 3) Diffs old vs new SHAs restricted to used paths
# 4) If any used paths changed, updates gitlinks, commits, pushes a branch
# 5) Prints the created branch name on stdout

REPO_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT_DIR"

LIST_SCRIPT="scripts/list-used-submodule-paths.sh"

# Route all standard output to stderr by default so the workflow can safely
# capture only the final branch name from stdout without noise.
exec 3>&1
exec 1>&2

mapfile -t SUBMODULES < <(awk '/^[[:space:]]*path[[:space:]]*=/ {print $3}' .gitmodules)
if [[ ${#SUBMODULES[@]} -eq 0 ]]; then
  echo "No submodules found" >&2
  exit 0
fi

USED_FILE=".tmp_used_paths.txt"
mkdir -p .tmp/subs
"$LIST_SCRIPT" | tee "$USED_FILE" >/dev/null || true

if [[ ! -s "$USED_FILE" ]]; then
  echo "No used submodule paths detected; skipping" >&2
  exit 0
fi

declare -A OLD_SHA
declare -A NEW_SHA

# Prep SHAs for each submodule
for sm in "${SUBMODULES[@]}"; do
  OLD_SHA["$sm"]=$(git ls-tree HEAD "$sm" | awk '{print $3}' || true)
  url=$(git config --file .gitmodules "submodule.$sm.url")
  branch=$(git config --file .gitmodules "submodule.$sm.branch" || echo "")

  mkdir -p ".tmp/subs/$sm"
  if [[ ! -d ".tmp/subs/$sm/.git" ]]; then
    git -C ".tmp/subs/$sm" init
    git -C ".tmp/subs/$sm" remote add origin "$url" 2>/dev/null || true
  fi
  # Determine default branch if not specified in .gitmodules
  if [[ -z "$branch" ]]; then
    # Try to detect origin/HEAD symbolic ref
    head_ref=$(git -C ".tmp/subs/$sm" ls-remote --symref origin HEAD | awk '/^ref:/ {print $2}')
    branch=${head_ref#refs/heads/}
    if [[ -z "$branch" ]]; then
      # Fall back to common defaults
      for candidate in main master; do
        if git -C ".tmp/subs/$sm" ls-remote --exit-code --heads origin "$candidate" >/dev/null 2>&1; then
          branch="$candidate"
          break
        fi
      done
    fi
    [[ -n "$branch" ]] || branch="main"
  fi
  git -C ".tmp/subs/$sm" fetch --depth=1 origin "$branch"
  # Ensure old SHA is present for diff if it exists
  if [[ -n "${OLD_SHA[$sm]}" ]]; then
    git -C ".tmp/subs/$sm" fetch --depth=1 origin "${OLD_SHA[$sm]}" || true
  fi
  NEW_SHA["$sm"]=$(git -C ".tmp/subs/$sm" rev-parse "origin/$branch")
done

TO_BUMP=".tmp_to_bump.txt"
> "$TO_BUMP"
mkdir -p .tmp/subs_changed

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  sm=$(echo "$line" | awk '{print $1}')
  pathpat=$(echo "$line" | awk '{print $3}')
  old=${OLD_SHA[$sm]:-}
  new=${NEW_SHA[$sm]:-}
  [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || continue

  # Convert simple /** glob to git pathspec glob
  if echo "$pathpat" | grep -q '\*\*'; then
    pat=":(glob)$pathpat"
  else
    pat="$pathpat"
  fi

  CHANGED=$(git -C ".tmp/subs/$sm" diff --name-only "$old" "$new" -- $pat || true)
  if [[ -n "$CHANGED" ]]; then
    # Accumulate changed files per submodule (relative to submodule root)
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      echo "$f" >> ".tmp/subs_changed/${sm}.txt"
    done <<< "$CHANGED"
    echo "$sm $new" >> "$TO_BUMP"
  fi
done < "$USED_FILE"

if [[ ! -s "$TO_BUMP" ]]; then
  echo "No relevant changes in used paths; nothing to bump" >&2
  exit 0
fi

# Prepare deduplicated changed file lists per submodule (DRY for later output)
while IFS= read -r line; do
  sm=$(echo "$line" | awk '{print $1}')
  if [[ -f ".tmp/subs_changed/${sm}.txt" ]]; then
    sort -u ".tmp/subs_changed/${sm}.txt" > ".tmp/subs_changed/${sm}.uniq"
  fi
done < "$TO_BUMP"

# Helper to emit changed files list for a submodule
emit_changed_files() {
  local sm="$1"
  local uniq_file=".tmp/subs_changed/${sm}.uniq"
  [[ -f "$uniq_file" ]] || return 0
  echo "  Changed files (used):"
  local count=0
  local total
  total=$(wc -l < "$uniq_file" | xargs)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "    - $f"
    count=$((count+1))
    if [[ $count -ge 50 ]]; then
      local more=$(( total - count ))
      if [[ $more -gt 0 ]]; then
        echo "    ... ($more more)"
      fi
      break
    fi
  done < "$uniq_file"
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

BRANCH="chore/bump-submodules-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"

while IFS= read -r line; do
  sm=$(echo "$line" | awk '{print $1}')
  new=$(echo "$line" | awk '{print $2}')
  git update-index --add --cacheinfo 160000 "$new" "$sm"
done < "$TO_BUMP"

# Build commit message including changed files
COMMIT_MSG_FILE=".tmp_commit_message.txt"
PR_BODY_FILE=".tmp_pr_body.md"
{
  echo "chore: bump submodules conditionally"
  echo
  while IFS= read -r line; do
    sm=$(echo "$line" | awk '{print $1}')
    new=$(echo "$line" | awk '{print $2}')
    old=${OLD_SHA[$sm]:-}
    echo "- $sm: $old -> $new"
    emit_changed_files "$sm"
    echo
  done < "$TO_BUMP"
} > "$COMMIT_MSG_FILE"

# Build PR body mirroring changed files
{
  while IFS= read -r line; do
    sm=$(echo "$line" | awk '{print $1}')
    new=$(echo "$line" | awk '{print $2}')
    old=${OLD_SHA[$sm]:-}
    echo "- $sm: $old -> $new"
    emit_changed_files "$sm"
    echo
  done < "$TO_BUMP"
} > "$PR_BODY_FILE"

git add .gitmodules || true
git commit -F "$COMMIT_MSG_FILE"
git push -u origin "$BRANCH"

# Print only the branch name to original stdout (FD 3) for the workflow step.
printf '%s\n' "$BRANCH" >&3


