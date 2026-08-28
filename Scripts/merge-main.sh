#!/usr/bin/env bash
# @file merge-main.sh
# @brief Bring a shader branch up to date with main, regenerating instead of resolving
# @description
#   Every branch that adds a shader touches the same three places: its own
#   .glsl, a row in the README table, and Generated/Shaders.swift. Two such
#   branches therefore conflict with each other on the last two, and the
#   conflicts are not worth reading: the README wants both rows, and the
#   generated file is not edited by hand at all.
#
#   This merges the upstream ref into the current branch and resolves those
#   two files the way they should be resolved - both README rows kept, in
#   upstream's order first, and Generated/Shaders.swift rebuilt from
#   shaders/ by Scripts/build-shaders.sh. Anything else in conflict is left
#   for a person, and the merge is not committed.
#
#   Before committing it prints what the branch now changes against
#   upstream, and the lines of Generated/Shaders.swift that changed outside
#   the named shader. That list should be the hash line and the `all` array;
#   anything more means the conversion tools differ from the ones that
#   produced the committed file, and the merge should not be pushed.
#
#   Nothing here pushes.
#
# @section Usage
#   Scripts/merge-main.sh <shader-name> [<upstream-ref>]
#
#   <shader-name>   the shader this branch adds or edits, as named in
#                   shaders/<name>.glsl; used to filter the generated diff
#   <upstream-ref>  what to merge in; origin/main unless given
#
# @exitcode 0 merged, regenerated, tests passed and committed
# @exitcode 1 a conflict outside README/Generated, or a test failed
# @exitcode 2 not on a branch, or the tree was not clean to begin with

set -euo pipefail

name="${1:?usage: Scripts/merge-main.sh <shader-name> [<upstream-ref>]}"
upstream="${2:-origin/main}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

branch="$(git branch --show-current)"
if [ -z "$branch" ]; then
    echo "not on a branch" >&2
    exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "the working tree is not clean; commit or stash first" >&2
    exit 2
fi

git fetch -q origin
if git merge --no-edit "$upstream" > /dev/null 2>&1; then
    echo "merged $upstream cleanly"
else
    echo "merging $upstream conflicts; resolving README.md and Generated/Shaders.swift"
fi

# The README table: both sides added a row at the same place. Keep both,
# upstream's first so the table stays in merge order.
if grep -q '^<<<<<<<' README.md; then
    python3 - <<'EOF'
import re
path = "README.md"
text = open(path).read()
pattern = re.compile(r"<<<<<<< [^\n]*\n(.*?)(?:\|\|\|\|\|\|\| [^\n]*\n.*?)?=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
while True:
    match = pattern.search(text)
    if not match:
        break
    text = text.replace(match.group(0), match.group(2) + match.group(1))
open(path, "w").write(text)
EOF
fi

unresolved="$(git status --porcelain | grep -E '^(UU|AA|DU|UD) ' | grep -vE 'README.md|Generated/Shaders.swift' || true)"
if [ -n "$unresolved" ]; then
    echo "conflicts outside README.md and Generated/Shaders.swift; resolve these by hand:" >&2
    echo "$unresolved" >&2
    exit 1
fi

# The generated file is never merged, only rebuilt.
Scripts/build-shaders.sh > /dev/null
Scripts/check-shaders-fresh.sh > /dev/null
git add README.md Generated/Shaders.swift

echo
echo "changes against $upstream:"
git --no-pager diff --no-ext-diff --cached --stat "$upstream"
echo
echo "Generated/Shaders.swift lines changed outside $name (expect the hash line and the 'all' array):"
git --no-pager diff --no-ext-diff --cached "$upstream" -- Generated/Shaders.swift \
    | grep -E '^[-+]' | grep -vE '^[-+]{2}' | grep -vi "$name" \
    | grep -E '^-|static let|all: \[' || true
echo

swift build
swift test

if git diff --cached --quiet && git diff --quiet; then
    echo "nothing to commit; $branch already contained $upstream"
else
    git commit -q --no-edit
    git --no-pager log --oneline -1
fi
