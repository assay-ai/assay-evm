#!/usr/bin/env bash
#
# Vendor drift gate for lib/openzeppelin/ and lib/openzeppelin-upgradeable/.
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
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

# check_tree <vendored dir> <upstream url> <name>
# The three questions above, for one vendored tree. Two trees are vendored: the main package,
# and (D-17) three files of the upgradeable package at the same release.
check_tree() {
  local VENDOR="$1" UPSTREAM="$2" NAME="$3"
  local COMMIT TAG TAG_COMMIT
  COMMIT=$(awk '/^Commit:/ {print $2}' "$VENDOR/VENDOR.md")
  TAG=$(awk '/^Tag:/ {print $2}' "$VENDOR/VENDOR.md")
  [ -n "$COMMIT" ] || { echo "vendor($NAME): VENDOR.md has no Commit: line"; rc=1; return; }
  [ -n "$TAG" ]    || { echo "vendor($NAME): VENDOR.md has no Tag: line"; rc=1; return; }
  [ -s "$VENDOR/MANIFEST" ] || { echo "vendor($NAME): MANIFEST is missing or empty"; rc=1; return; }

  # 1. The pin must agree with itself: the tag has to point at the commit.
  TAG_COMMIT=$(git ls-remote "$UPSTREAM" "refs/tags/$TAG^{}" | awk '{print $1}')
  [ -n "$TAG_COMMIT" ] || TAG_COMMIT=$(git ls-remote "$UPSTREAM" "refs/tags/$TAG" | awk '{print $1}')
  if [ -z "$TAG_COMMIT" ]; then
    echo "vendor($NAME): tag $TAG does not exist upstream"; rc=1
  elif [ "$TAG_COMMIT" != "$COMMIT" ]; then
    echo "vendor($NAME): pin disagrees with itself — $TAG is $TAG_COMMIT, VENDOR.md says $COMMIT"; rc=1
  fi

  git clone -q "$UPSTREAM" "$TMP/$NAME"
  git -C "$TMP/$NAME" checkout -q "$COMMIT"

  # 2. The set of files on disk must equal the set MANIFEST names — both directions.
  (cd "$VENDOR" && find . -name '*.sol' | sed 's|^\./||' | LC_ALL=C sort) > "$TMP/$NAME.present"
  LC_ALL=C sort "$VENDOR/MANIFEST" > "$TMP/$NAME.expected"
  while IFS= read -r rel; do
    [ -n "$rel" ] && { echo "vendor($NAME) MISSING (in MANIFEST, not on disk): $rel"; rc=1; }
  done < <(comm -23 "$TMP/$NAME.expected" "$TMP/$NAME.present")
  while IFS= read -r rel; do
    [ -n "$rel" ] && { echo "vendor($NAME) UNEXPECTED (on disk, not in MANIFEST): $rel"; rc=1; }
  done < <(comm -13 "$TMP/$NAME.expected" "$TMP/$NAME.present")

  # 3. Every file present must be byte-identical to the pinned commit.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "$TMP/$NAME/contracts/$rel" ]; then
      echo "vendor($NAME) drift: $rel (no such file at $COMMIT)"; rc=1
    elif ! diff -q "$VENDOR/$rel" "$TMP/$NAME/contracts/$rel" >/dev/null 2>&1; then
      echo "vendor($NAME) drift: $rel"; rc=1
    fi
  done < "$TMP/$NAME.present"
  [ $rc -eq 0 ] && echo "vendor OK ($NAME $TAG = $COMMIT, $(wc -l < "$TMP/$NAME.expected" | tr -d ' ') files)"
}

check_tree "$HERE/lib/openzeppelin" https://github.com/OpenZeppelin/openzeppelin-contracts oz
check_tree "$HERE/lib/openzeppelin-upgradeable" \
  https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable ozu

# 4. The one redirected import (lib/openzeppelin-upgradeable/VENDOR.md): `remappings.txt` sends
#    the upgradeable package's `proxy/utils/Initializable.sol` to the main package's copy. That
#    is sound only while the two are byte-identical at the two pins, and this asks it.
if [ -d "$TMP/oz" ] && [ -d "$TMP/ozu" ]; then
  if ! diff -q "$TMP/ozu/contracts/proxy/utils/Initializable.sol" \
      "$TMP/oz/contracts/proxy/utils/Initializable.sol" >/dev/null 2>&1; then
    echo "vendor: the upgradeable package's Initializable differs from the main package's —"
    echo "        the remap in remappings.txt is no longer a no-op"; rc=1
  fi
fi
grep -qx 'lib/openzeppelin-upgradeable/proxy/utils/=lib/openzeppelin/proxy/utils/' \
  "$HERE/remappings.txt" || { echo "vendor: the Initializable remap is missing from remappings.txt"; rc=1; }

[ $rc -eq 0 ] && echo "vendor OK (both trees)"
exit $rc
