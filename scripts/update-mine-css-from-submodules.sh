#!/usr/bin/env bash

set -euo pipefail

# This script updates custom/*_mine*.css files based on upstream changes
# in submodules. It performs a 3-way merge to preserve local color
# customizations while incorporating upstream structural changes.
#
# Usage:
#   scripts/update-mine-css-from-submodules.sh <TO_BUMP_FILE>
#
# Where TO_BUMP_FILE contains lines of: "<submodule_path> <new_sha>"
#
# Requires:
#   - The submodule temporary clones in .tmp/subs/<submodule>/ (created
#     by bump-submodules-conditionally.sh) with relevant SHAs fetched.
#
# Output:
#   - Modified custom/*_mine*.css files in the working tree.
#   - Appends update info to .tmp_mine_updates.txt for commit/PR messages.

REPO_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT_DIR"

TO_BUMP_FILE="${1:-.tmp_to_bump.txt}"
MINE_UPDATES_FILE=".tmp_mine_updates.txt"
MINE_CONFLICTS_FILE=".tmp_mine_conflicts.txt"

# Clean up previous outputs
: > "$MINE_UPDATES_FILE"
: > "$MINE_CONFLICTS_FILE"

# Define the mapping of mine files to their upstream sources
# Format: "MINE_PATH|SUBMODULE|UPSTREAM_REL_PATH"
MINE_MAPPINGS=(
  "custom/ac_popup_megabar_result_highlighting_mine.css|CustomCSSforFx|current/css/locationbar/ac_popup_megabar_result_highlighting_aero.css"
  "custom/popup_items_hover_appearance_mine.css|CustomCSSforFx|current/css/generalui/popup_items_hover_appearance_aero.css"
  "custom/buttons_on_bookmarks_toolbar_mine_appearance.css|CustomCSSforFx|current/css/buttons/buttons_on_bookmarks_toolbar_aero_appearance.css"
  "custom/buttons_on_navbar_mine_appearance.css|CustomCSSforFx|current/css/buttons/buttons_on_navbar_aero_appearance.css"
  "custom/urlbar_icons_mine_appearance.css|CustomCSSforFx|current/css/locationbar/urlbar_icons_aero_appearance.css"
  "custom/loading_indicator_bouncing_line_mine.css|firefox-csshacks|chrome/loading_indicator_bouncing_line.css"
)

if [[ ! -f "$TO_BUMP_FILE" ]]; then
  echo "No TO_BUMP file found at $TO_BUMP_FILE; nothing to update" >&2
  exit 0
fi

# Parse TO_BUMP_FILE into associative array: submodule -> new_sha
declare -A BUMP_SHAS
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  sm=$(echo "$line" | awk '{print $1}')
  new_sha=$(echo "$line" | awk '{print $2}')
  BUMP_SHAS["$sm"]="$new_sha"
done < "$TO_BUMP_FILE"

if [[ ${#BUMP_SHAS[@]} -eq 0 ]]; then
  echo "TO_BUMP file is empty; nothing to update" >&2
  exit 0
fi

# Create temp directory for merge operations
MERGE_TMP_DIR=".tmp/mine-updates"
mkdir -p "$MERGE_TMP_DIR"

# Extract the "Based on <sha>" hash from a mine file
extract_base_sha() {
  local file="$1"
  grep -oE 'Based on [0-9a-f]{7,40}' "$file" 2>/dev/null | head -1 | awk '{print $3}' || true
}

# Update the "Based on <sha>" comment in a mine file
update_base_sha() {
  local file="$1"
  local old_sha="$2"
  local new_sha="$3"
  sed -i "s/Based on $old_sha/Based on $new_sha/" "$file"
}

# Process each mine mapping
for mapping in "${MINE_MAPPINGS[@]}"; do
  IFS='|' read -r mine_path submodule upstream_rel_path <<< "$mapping"

  # Check if this submodule is being bumped
  if [[ -z "${BUMP_SHAS[$submodule]:-}" ]]; then
    echo "Skipping $mine_path: submodule $submodule not being bumped" >&2
    continue
  fi

  new_sha="${BUMP_SHAS[$submodule]}"

  # Check if the mine file exists
  if [[ ! -f "$mine_path" ]]; then
    echo "Warning: mine file $mine_path does not exist; skipping" >&2
    continue
  fi

  # Extract the base SHA from the mine file
  base_sha=$(extract_base_sha "$mine_path")
  if [[ -z "$base_sha" ]]; then
    echo "Warning: no 'Based on <sha>' found in $mine_path; skipping" >&2
    continue
  fi

  echo "Processing $mine_path (base: $base_sha, target: $new_sha)" >&2

  # Check if the submodule temp clone exists
  sub_clone=".tmp/subs/$submodule"
  if [[ ! -d "$sub_clone/.git" ]]; then
    echo "Warning: submodule clone not found at $sub_clone; skipping $mine_path" >&2
    continue
  fi

  # Fetch the base SHA if not already available
  if ! git -C "$sub_clone" cat-file -e "$base_sha" 2>/dev/null; then
    echo "Fetching base SHA $base_sha for $submodule..." >&2
    git -C "$sub_clone" fetch --depth=1 origin "$base_sha" 2>/dev/null || {
      echo "Warning: could not fetch base SHA $base_sha; skipping $mine_path" >&2
      continue
    }
  fi

  # Check if the upstream file changed between base_sha and new_sha
  changed=$(git -C "$sub_clone" diff --name-only "$base_sha" "$new_sha" -- "$upstream_rel_path" 2>/dev/null || true)
  if [[ -z "$changed" ]]; then
    echo "No changes in upstream $upstream_rel_path between $base_sha and $new_sha; skipping" >&2
    continue
  fi

  echo "Upstream $upstream_rel_path changed; performing 3-way merge..." >&2

  # Prepare temp files for the merge
  base_file="$MERGE_TMP_DIR/base.css"
  remote_file="$MERGE_TMP_DIR/remote.css"
  local_file="$MERGE_TMP_DIR/local.css"

  # Get base version (upstream at base_sha)
  if ! git -C "$sub_clone" show "$base_sha:$upstream_rel_path" > "$base_file" 2>/dev/null; then
    echo "Warning: could not retrieve base version of $upstream_rel_path; skipping" >&2
    continue
  fi

  # Get remote version (upstream at new_sha)
  if ! git -C "$sub_clone" show "$new_sha:$upstream_rel_path" > "$remote_file" 2>/dev/null; then
    echo "Warning: could not retrieve new version of $upstream_rel_path; skipping" >&2
    continue
  fi

  # Copy local mine file for merge
  cp "$mine_path" "$local_file"

  # Perform 3-way merge: git merge-file modifies local_file in-place
  # Returns 0 on clean merge, >0 on conflicts (number of conflicts), <0 on error
  merge_result=0
  git merge-file -L "mine" -L "base" -L "upstream" "$local_file" "$base_file" "$remote_file" || merge_result=$?

  if [[ $merge_result -lt 0 ]]; then
    echo "Error: merge-file failed for $mine_path" >&2
    continue
  fi

  if [[ $merge_result -eq 0 ]]; then
    # Clean merge - apply the result and update the Based on hash
    cp "$local_file" "$mine_path"
    update_base_sha "$mine_path" "$base_sha" "$new_sha"
    echo "Successfully merged $mine_path (no conflicts)" >&2
    echo "$mine_path|$submodule|$upstream_rel_path|$base_sha|$new_sha|clean" >> "$MINE_UPDATES_FILE"
  else
    # Merge had conflicts - DO NOT modify the original file!
    # Keep the mine file intact and just report the conflict for manual review
    echo "Merge conflicts in $mine_path ($merge_result conflict regions) - file NOT modified" >&2
    echo "$mine_path|$submodule|$upstream_rel_path|$base_sha|$new_sha|conflicts:$merge_result" >> "$MINE_UPDATES_FILE"
    echo "$mine_path" >> "$MINE_CONFLICTS_FILE"
    
    # Save the conflicted merge result for reference (user can review if needed)
    conflict_ref="$MERGE_TMP_DIR/$(basename "$mine_path").conflicted"
    cp "$local_file" "$conflict_ref"
    echo "  Conflicted merge saved to: $conflict_ref" >&2
  fi
done

# Summary
updated_count=$(wc -l < "$MINE_UPDATES_FILE" 2>/dev/null | xargs)
conflict_count=$(wc -l < "$MINE_CONFLICTS_FILE" 2>/dev/null | xargs)

echo "" >&2
echo "Mine CSS update summary:" >&2
echo "  Updated: $updated_count file(s)" >&2
echo "  With conflicts: $conflict_count file(s)" >&2

if [[ "$conflict_count" -gt 0 ]]; then
  echo "" >&2
  echo "Files with merge conflicts (original files NOT modified):" >&2
  cat "$MINE_CONFLICTS_FILE" >&2
  echo "" >&2
  echo "Conflicted merge attempts saved in: $MERGE_TMP_DIR/*.conflicted" >&2
  echo "These show what the merge WOULD look like - review manually." >&2
else
  # Only clean up if no conflicts (preserve conflicted files for review)
  rm -rf "$MERGE_TMP_DIR"
fi

