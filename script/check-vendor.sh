#!/usr/bin/env bash
#
# Vendor drift gate for lib/openzeppelin/.
#
# Three questions, because answering only the first lets a whole file disappear:
#
#   1. Does VENDOR.md's Tag resolve to VENDOR.md's Commit?   (the pin agrees with itself)
#   2. Is the SET of files exactly MANIFEST?                 (catches a deletion, and a
#                                                             stray file that never came
#                                                             from upstream)
#   3. Is every file byte-identical to that commit?          (catches an edit)
#
# The first version of this gate asked only (3), by walking the files that happen to be
# present — so deleting ECDSA.sol printed "vendor OK" and exited 0. Enumerating what is
# there can never answer "is anything missing"; that needs a list written down in advance,
# which is what MANIFEST is.
#
# SCOPE: this detects LOCAL drift only. It says nothing about upstream evolution — the
# pinned commit does not move, so an upstream change to OpenZeppelin is invisible here by
# design. Noticing that is a dependency-bump review, not this script.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$HERE/lib/openzeppelin"
UPSTREAM=https://github.com/OpenZeppelin/openzeppelin-contracts

COMMIT=$(awk '/^Commit:/ {print $2}' "$VENDOR/VENDOR.md")
TAG=$(awk '/^Tag:/ {print $2}' "$VENDOR/VENDOR.md")
[ -n "$COMMIT" ] || { echo "vendor: VENDOR.md has no Commit: line"; exit 1; }
[ -n "$TAG" ]    || { echo "vendor: VENDOR.md has no Tag: line"; exit 1; }
[ -s "$VENDOR/MANIFEST" ] || { echo "vendor: MANIFEST is missing or empty"; exit 1; }

rc=0

# 1. The pin must agree with itself: the tag has to point at the commit.
TAG_COMMIT=$(git ls-remote "$UPSTREAM" "refs/tags/$TAG^{}" | awk '{print $1}')
[ -n "$TAG_COMMIT" ] || TAG_COMMIT=$(git ls-remote "$UPSTREAM" "refs/tags/$TAG" | awk '{print $1}')
if [ -z "$TAG_COMMIT" ]; then
  echo "vendor: tag $TAG does not exist upstream"; rc=1
elif [ "$TAG_COMMIT" != "$COMMIT" ]; then
  echo "vendor: pin disagrees with itself — $TAG is $TAG_COMMIT, VENDOR.md says $COMMIT"; rc=1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git clone -q "$UPSTREAM" "$TMP/oz"
git -C "$TMP/oz" checkout -q "$COMMIT"

# 2. The set of files on disk must equal the set MANIFEST names — both directions.
(cd "$VENDOR" && find . -name '*.sol' | sed 's|^\./||' | LC_ALL=C sort) > "$TMP/present"
LC_ALL=C sort "$VENDOR/MANIFEST" > "$TMP/expected"
while IFS= read -r rel; do
  [ -n "$rel" ] && { echo "vendor MISSING (in MANIFEST, not on disk): $rel"; rc=1; }
done < <(comm -23 "$TMP/expected" "$TMP/present")
while IFS= read -r rel; do
  [ -n "$rel" ] && { echo "vendor UNEXPECTED (on disk, not in MANIFEST): $rel"; rc=1; }
done < <(comm -13 "$TMP/expected" "$TMP/present")

# 3. Every file present must be byte-identical to the pinned commit.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ ! -f "$TMP/oz/contracts/$rel" ]; then
    echo "vendor drift: $rel (no such file at $COMMIT)"; rc=1
  elif ! diff -q "$VENDOR/$rel" "$TMP/oz/contracts/$rel" >/dev/null 2>&1; then
    echo "vendor drift: $rel"; rc=1
  fi
done < "$TMP/present"

if [ $rc -eq 0 ]; then
  echo "vendor OK ($TAG = $COMMIT, $(wc -l < "$TMP/expected" | tr -d ' ') files)"
fi
exit $rc
