#!/bin/sh
# Asks beacondb where this machine is, and writes it where run.sh will look.
#
# quickshell runs this at startup and on `qs ipc call nightlight locate`.
#
# Not geoclue. Geoclue's per-app authorization lives in
# /etc/geoclue/geoclue.conf, and install.sh never writes outside $HOME; the
# agent that would avoid that file never remembers its answer, so every toggle
# would re-prompt. See docs/superpowers/specs/2026-08-13-night-light-design.md.
#
# The fix comes from the source IP, so the request body is empty: no wifi scan,
# no BSSID list, and strictly less leaked than the wifi route would leak. 25km
# of accuracy is about one minute of sunset.
set -u

LOCATION=${NIGHT_LIGHT_LOCATION:-$HOME/.config/quickshell/night-light-location.conf}
URL=${NIGHT_LIGHT_URL:-https://api.beacondb.net/v1/geolocate}

report() {
    printf 'night-light-locate: %s\n' "$1"
}

# -f so an HTTP error is a non-zero exit rather than an error page parsed as a
# fix; -m so a hung endpoint cannot hold a session's startup open.
body=$(curl -sf -m 10 -X POST "$URL" -H 'Content-Type: application/json' -d '{}') || {
    report 'lookup failed'
    exit 1
}

# The validation is jq's rather than a second pass in shell: jq is already
# parsing, and POSIX sh cannot compare floats without pulling in another tool.
# The selects reject a string latitude too -- jq orders numbers before strings,
# so a quoted value fails `<= 90` instead of sneaking past `>= -90`.
fix=$(printf '%s' "$body" | jq -er '
    .location
    | select(.lat >= -90 and .lat <= 90)
    | select(.lng >= -180 and .lng <= 180)
    | select(.lat != 0 or .lng != 0)
    | "\(.lat) \(.lng)"
' 2>/dev/null) || {
    report 'no usable fix in the response; keeping the last one'
    exit 1
}

# Written through a temp file and renamed, because quickshell watches this path
# with a FileView: a truncate-then-write would show it an empty file first, and
# empty is how run.sh spells "no location yet".
# An `if` rather than `A && B || C`: shellcheck flags that as SC2015 and would
# fail `make lint`, and it is right to -- C runs when the printf succeeds and
# the mv fails, which is exactly the case this needs to catch, but it also runs
# when the printf itself fails, and the two want the same cleanup for different
# reasons. Spelling it out says so.
tmp=$(mktemp "$LOCATION.XXXXXX") || exit 1
if ! printf '%s\n' "$fix" > "$tmp" || ! mv -f "$tmp" "$LOCATION"; then
    rm -f "$tmp"
    report 'could not write the location'
    exit 1
fi

report "$fix"
