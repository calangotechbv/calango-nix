#!/usr/bin/env bash
# Validate every rendered apt source against its real repository, unprivileged.
#
# An inline Signed-By: key that does not match the repository produces exit 100
# and "The repository ... is not signed", naming the key it wanted. A stanza
# that is merely well-formed proves nothing, so this fetches InRelease for real.
#
# APT::Sandbox::User=root disables apt's drop to the _apt user, which cannot
# read a directory under $TMPDIR. Nothing here runs as root.
set -euo pipefail

B="${1:?usage: test/apt-sources.sh <path from nix build .#calangoBootstrap>}"
src="$B/etc/apt/sources.list.d"
[ -d "$src" ] || { echo "no sources.list.d under $B" >&2; exit 1; }

n=$(find "$src" -name '*.sources' | wc -l)
[ "$n" -gt 0 ] || { echo "no .sources files -- a vacuous pass" >&2; exit 1; }
echo "validating $n source(s)"

fail=0
for f in "$src"/*.sources; do
  t=$(mktemp -d); mkdir -p "$t/sources.list.d" "$t/lists/partial" "$t/cache"
  cp "$f" "$t/sources.list.d/"
  if apt-get -o Dir::Etc::sourceparts="$t/sources.list.d" \
             -o Dir::Etc::sourcelist=/dev/null \
             -o Dir::State::lists="$t/lists" \
             -o Dir::Cache="$t/cache" \
             -o APT::Sandbox::User=root \
             -o Acquire::Languages=none \
             update >"$t/log" 2>&1; then
    echo "ok   $(basename "$f")"
  else
    echo "FAIL $(basename "$f")" >&2
    sed 's/^/     /' "$t/log" >&2
    fail=$((fail + 1))
  fi
  rm -rf "$t"
done

[ "$fail" -eq 0 ] || { echo "$fail source(s) failed to verify" >&2; exit 1; }
echo "all $n source(s) verified"
