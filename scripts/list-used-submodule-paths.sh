#!/usr/bin/env bash

set -euo pipefail

# Lists paths inside git submodules that are actually used by this repo,
# based on @import url(...) statements in userChrome.css and userContent.css.
#
# Output format (one entry per line):
#   <submodule_path> PATH <relative_path_pattern>
#
# Where <relative_path_pattern> is an exact file path (e.g. chrome/foo.css).
#
# Usage:
#   scripts/list-used-submodule-paths.sh            # list for all submodules
#   scripts/list-used-submodule-paths.sh <SUBPATH>  # list only for given submodule path

REPO_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT_DIR"

declare -a CSS_SOURCES=("userChrome.css" "userContent.css")

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found; nothing to list" >&2
  exit 0
fi

# Collect submodule path list from .gitmodules
mapfile -t SUBMODULE_PATHS < <(awk '/^[[:space:]]*path[[:space:]]*=/ {print $3}' .gitmodules)

filter_submodule=${1:-}
if [[ -n "$filter_submodule" ]]; then
  # Validate requested submodule exists
  found=false
  for sm in "${SUBMODULE_PATHS[@]}"; do
    if [[ "$sm" == "$filter_submodule" ]]; then found=true; break; fi
  done
  if [[ "$found" != true ]]; then
    echo "Requested submodule '$filter_submodule' not declared in .gitmodules" >&2
    exit 1
  fi
  SUBMODULE_PATHS=("$filter_submodule")
fi

# Extract @import url(...) targets from known CSS entry points
# Note: strip CSS block comments first so commented-out @import lines are ignored
declare -a IMPORTS=()
for css in "${CSS_SOURCES[@]}"; do
  [[ -f "$css" ]] || continue
  # Remove /* ... */ comments (possibly multi-line), then extract content between url( and )
  while IFS= read -r line; do
    IMPORTS+=("$line")
  done < <(sed -E ':a; s@/\*[^*]*\*+([^/*][^*]*\*+)*/@@g; ta' "$css" \
           | grep -hoE '@import[[:space:]]+url\(([^)]+)\)' 2>/dev/null \
           | sed -E 's/.*url\(([^)]+)\).*/\1/')
done

# Build maps per submodule: unique files and directories
for sm in "${SUBMODULE_PATHS[@]}"; do
  declare -A uniq_files=()

  for imp in "${IMPORTS[@]:-}"; do
    [[ -n "$imp" ]] || continue
    # Trim surrounding whitespace
    imp="${imp#"${imp%%[![:space:]]*}"}"
    imp="${imp%"${imp##*[![:space:]]}"}"
    # Strip optional surrounding quotes (single or double)
    if [[ "$imp" == '"'*'"' ]]; then imp="${imp#\"}"; imp="${imp%\"}"; fi
    if [[ "$imp" == "'"*"'" ]]; then imp="${imp#\'}"; imp="${imp%\'}"; fi
    # Normalize ./ prefixes
    imp=${imp#./}
    # Only consider imports that live under this submodule
    case "$imp" in
      "$sm"/*)
        rel=${imp#"$sm"/}
        # Skip obvious anchors
        [[ -n "$rel" ]] || continue
        uniq_files["$rel"]=1
        # Only track exact files we import
        ;;
      *) ;;
    esac
  done

  # Emit exact file paths only
  for f in "${!uniq_files[@]}"; do
    printf "%s PATH %s\n" "$sm" "$f"
  done

  # Unset associative arrays before next iteration to avoid leakage across shells
  unset uniq_files
done


