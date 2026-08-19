#!/usr/bin/env bash
# Validate every rendered apt source against its real repository, unprivileged.
#
# An inline Signed-By: key that does not match the repository produces exit 100
# and "The repository ... is not signed", naming the key it wanted. A stanza
# that is merely well-formed proves nothing, so this fetches InRelease for real.
#
# `apt-get update`'s own exit status cannot be the check. An unresolvable host
# -- or an offline machine generally -- prints "W: Failed to fetch ... Could
# not resolve '...'" and STILL EXITS 0: that condition is a warning to apt, not
# an error, so a check keyed on exit status calls it verified. Measured:
#
#   URIs: https://no-such-host.invalid/debian   -> apt-get update exits 0,
#   and $t/lists holds nothing but its own lock file -- no InRelease fetched.
#
# So this asserts the POSITIVE outcome instead: an InRelease file for the
# source must actually land in $t/lists. A real fetch against
# dl.google.com's repository puts
# dl.google.com_linux_chrome-stable_deb_dists_stable_InRelease there; the
# unreachable case puts nothing. Grepping the log for "^Err:" or "^W: Failed
# to fetch" was the other option and was rejected: a negative pattern list
# goes stale the moment apt's wording changes, where "no InRelease exists"
# cannot go stale in the same way.
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
             update >"$t/log" 2>&1 \
     && [ -n "$(find "$t/lists" -maxdepth 1 -name '*_InRelease')" ]; then
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
