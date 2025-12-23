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

# Optional: path to write the created branch name. Default to a temp file.
BRANCH_OUTPUT_FILE=${BRANCH_OUTPUT_FILE:-.tmp_branch_name}

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
declare -A SUBMODULE_URL

# Prep SHAs for each submodule
for sm in "${SUBMODULES[@]}"; do
  OLD_SHA["$sm"]=$(git ls-tree HEAD "$sm" | awk '{print $3}' || true)
  url=$(git config --file .gitmodules "submodule.$sm.url")
  branch=$(git config --file .gitmodules "submodule.$sm.branch" || echo "")

  SUBMODULE_URL["$sm"]="$url"

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
: > "$TO_BUMP"
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

  CHANGED=$(git -C ".tmp/subs/$sm" diff --name-only "$old" "$new" -- "$pat" || true)
  if [[ -n "$CHANGED" ]]; then
    # Accumulate changed files per submodule (relative to submodule root)
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      echo "$f" >> ".tmp/subs_changed/${sm}.txt"
    done <<< "$CHANGED"
    # Ensure each submodule is only added once to the bump list
    if [[ -z ${__SM_ADDED_ONCE__+x} ]]; then
      declare -A __SM_ADDED_ONCE__
    fi
    if [[ -z "${__SM_ADDED_ONCE__[$sm]:-}" ]]; then
      echo "$sm $new" >> "$TO_BUMP"
      __SM_ADDED_ONCE__[$sm]=1
    fi
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

# Convert submodule git URL to GitHub HTML URL
to_html_url() {
  local u="$1"
  if [[ "$u" =~ ^git@github\.com:(.*)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$u" =~ ^git@github\.com:(.*)$ ]]; then
    local path_part="${BASH_REMATCH[1]}"
    echo "https://github.com/${path_part%/}"
    return
  fi
  if [[ "$u" =~ ^https://github\.com/ ]]; then
    u="${u%.git}"
    echo "${u%/}"
    return
  fi
  echo "$u"
}

# Emit changed files list enhanced with links
emit_changed_files_with_links() {
  local sm="$1"
  local old_sha="$2"
  local new_sha="$3"
  local repo_url_html="$4"
  local uniq_file=".tmp/subs_changed/${sm}.uniq"
  [[ -f "$uniq_file" ]] || return 0
  echo "  Changed files (used):"
  local count=0
  local total
  total=$(wc -l < "$uniq_file" | xargs)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "    - $f"
    echo "      - old: ${repo_url_html}/blob/${old_sha}/${f}"
    echo "      - new: ${repo_url_html}/blob/${new_sha}/${f}"
    echo "      - diff: ${repo_url_html}/compare/${old_sha}...${new_sha}?diff=split#files_bucket"
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

# Update custom/*_mine*.css files based on upstream changes
MINE_UPDATE_SCRIPT="scripts/update-mine-css-from-submodules.sh"
if [[ -x "$MINE_UPDATE_SCRIPT" ]]; then
  echo "Updating custom mine CSS files..." >&2
  "$MINE_UPDATE_SCRIPT" "$TO_BUMP" || true
fi

BRANCH="chore/bump-submodules-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH"

while IFS= read -r line; do
  sm=$(echo "$line" | awk '{print $1}')
  new=$(echo "$line" | awk '{print $2}')
  git update-index --add --cacheinfo 160000 "$new" "$sm"
done < "$TO_BUMP"

# Helper to emit mine CSS updates for commit message
emit_mine_updates_commit() {
  local updates_file=".tmp_mine_updates.txt"
  [[ -f "$updates_file" && -s "$updates_file" ]] || return 0
  echo
  echo "Custom mine CSS updates:"
  while IFS='|' read -r mine_path submodule upstream_path old_sha new_sha status; do
    [[ -n "$mine_path" ]] || continue
    if [[ "$status" == "clean" ]]; then
      echo "  - $mine_path: merged cleanly ($old_sha -> $new_sha)"
    else
      echo "  - $mine_path: CONFLICTS - needs manual resolution"
    fi
  done < "$updates_file"
}

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
  emit_mine_updates_commit
} > "$COMMIT_MSG_FILE"

# Helper to emit mine CSS updates for PR body (with links)
emit_mine_updates_pr() {
  local updates_file=".tmp_mine_updates.txt"
  [[ -f "$updates_file" && -s "$updates_file" ]] || return 0
  echo
  echo "## Custom mine CSS updates"
  echo
  local has_conflicts=false
  while IFS='|' read -r mine_path submodule upstream_path old_sha new_sha status; do
    [[ -n "$mine_path" ]] || continue
    local repo_html_url
    repo_html_url=$(to_html_url "${SUBMODULE_URL[$submodule]:-}")
    if [[ "$status" == "clean" ]]; then
      echo "- **$mine_path**: :white_check_mark: merged cleanly"
      echo "  - Based on: \`$old_sha\` -> \`$new_sha\`"
      echo "  - Upstream: \`$upstream_path\`"
      if [[ -n "$repo_html_url" ]]; then
        echo "  - [View upstream diff](${repo_html_url}/compare/${old_sha}...${new_sha})"
      fi
    else
      has_conflicts=true
      echo "- **$mine_path**: :eyes: upstream changed, needs manual review"
      echo "  - Current base: \`$old_sha\`"
      echo "  - New upstream: \`$new_sha\`"
      echo "  - Upstream file: \`$upstream_path\`"
      echo "  - **File NOT modified** - your custom colors are safe"
      if [[ -n "$repo_html_url" ]]; then
        echo "  - [View upstream changes](${repo_html_url}/compare/${old_sha}...${new_sha})"
      fi
    fi
    echo
  done < "$updates_file"
  
  if [[ "$has_conflicts" == "true" ]]; then
    echo "---"
    echo
    echo "### Manual update instructions"
    echo
    echo "For files marked with :eyes:, the upstream CSS structure changed in a way that couldn't be auto-merged with your color customizations."
    echo
    echo "To update manually:"
    echo "1. Review the upstream changes using the diff link above"
    echo "2. Apply any relevant structural changes to your \`*_mine*.css\` file"
    echo "3. Update the \`/* Based on <sha> */\` comment to the new SHA"
    echo
  fi
}

# Build PR body mirroring changed files
{
  echo "## Submodule updates"
  echo
  while IFS= read -r line; do
    sm=$(echo "$line" | awk '{print $1}')
    new=$(echo "$line" | awk '{print $2}')
    old=${OLD_SHA[$sm]:-}
    echo "- $sm: $old -> $new"
    repo_html_url=$(to_html_url "${SUBMODULE_URL[$sm]}")
    echo "  - repo: ${repo_html_url}"
    echo "  - old commit: ${repo_html_url}/commit/${old}"
    echo "  - new commit: ${repo_html_url}/commit/${new}"
    echo "  - compare: ${repo_html_url}/compare/${old}...${new}"
    emit_changed_files_with_links "$sm" "$old" "$new" "$repo_html_url"
    echo
  done < "$TO_BUMP"
  emit_mine_updates_pr
} > "$PR_BODY_FILE"

# Stage submodule changes and any updated mine CSS files
git add .gitmodules || true
git add custom/*.css 2>/dev/null || true
git commit -F "$COMMIT_MSG_FILE"
git push -u origin "$BRANCH"

# Persist and print only the branch name for the workflow step.
printf '%s\n' "$BRANCH" > "$BRANCH_OUTPUT_FILE"

