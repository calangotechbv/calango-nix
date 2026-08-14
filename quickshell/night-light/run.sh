#!/bin/sh
# The night light, as one decision: which gammastep to run, or none at all.
#
# hypr/systemd/night-light.service execs this. It is a wrapper for a reason:
# the unit needs flags chosen from two files quickshell rewrites at runtime,
# and an ExecStart cannot read a file. The alternative -- $ARGS out of an
# EnvironmentFile -- leans on systemd's word-splitting rules, which are a
# footnote most readers do not know, and would put the only branching this
# feature has somewhere tests/night-light.sh cannot reach.
#
# Exits 0 without running anything when there is nothing to do: mode=off, or
# mode=auto before the first location fix. That is what lets the unit be
# ENABLED -- it starts at login, decides for itself, and needs nothing from
# quickshell to be correct. The unit carries no Restart= at all (see its own
# comment for why), so this exit code only matters for `systemctl --user
# status` reading `inactive (dead)` rather than `failed`.
#
# Both paths come from the environment and gammastep is reached through PATH,
# so tests/night-light.sh can fake all of it.
set -u

CONF=${NIGHT_LIGHT_CONF:-$HOME/.config/quickshell/night-light.conf}
LOCATION=${NIGHT_LIGHT_LOCATION:-$HOME/.config/quickshell/night-light-location.conf}
DRY_RUN=${NIGHT_LIGHT_DRY_RUN:-0}

# Not a knob. auto's daytime half means "do not touch the screen", and 6500K is
# what an untouched gamma table already is.
DAY_TEMP=6500

report() {
    printf 'night-light: %s\n' "$1"
}

# The last assignment of a key wins, which is what a conf rewritten twice in
# quick succession -- a double-click on the glyph -- should read as.
conf_get() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^$1=//p" "$CONF" | tail -n 1
}

mode=$(conf_get mode)
temp=$(conf_get temp)

# An unknown mode is auto, not an error. This file is machine state the shell
# writes; a hand-edited typo should still warm the screen on a schedule rather
# than leave the unit dead with a message nobody reads.
case $mode in
    on|auto|off) : ;;
    *)           mode=auto ;;
esac

# Same argument. The bounds are gammastep's own accepted range.
#
# An `if` rather than `[ ... ] && [ ... ] || temp=3000`, which shellcheck flags
# as SC2015 -- and here it would genuinely be wrong: with A && B || C, a temp
# that passes the first test and fails the second still runs C, but so does one
# that fails the first, and the two paths are not the same shape. Spelling it
# out costs two lines and cannot be misread.
if ! [ "$temp" -ge 1000 ] 2>/dev/null || ! [ "$temp" -le 25000 ] 2>/dev/null; then
    temp=3000
fi

if [ "$mode" = off ]; then
    report 'off'
    exit 0
fi

# Read once, for both modes. `on` only needs it to pick the fading form below;
# it still works without one.
lat=
lon=
[ -s "$LOCATION" ] && read -r lat lon < "$LOCATION"

if [ "$mode" = on ]; then
    if [ -n "$lat" ] && [ -n "$lon" ]; then
        # Equal day and night temperatures: constant warm, whatever the sun is
        # doing -- verified with `gammastep -p`, which reports 3000K at
        # "Period: Daytime" for -t 3000:3000.
        #
        # This spelling rather than the obvious `-O` because -O is one-shot
        # manual mode: redshift.c sets the temperature once and pause()s, and
        # the fade loop lives in the continual path it never enters, so -O
        # snaps. Continual mode fades over FADE_LENGTH 40 steps of 100ms -- four
        # seconds -- which is the whole point of spelling it this way.
        #
        # Continual mode needs a location even when the temperature cannot
        # depend on it, which is why this is the branch and not the rule.
        set -- gammastep -m wayland -l "$lat:$lon" -t "$temp:$temp"
    else
        # No fix, so continual mode is unavailable and `on` snaps instead of
        # fading. Deliberately still works: the spec's point is that a machine
        # which has never reached the network can still force a warm screen.
        set -- gammastep -m wayland -O "$temp"
    fi
else
    # auto with no fix has no schedule to follow, so there is nothing to run.
    # quickshell draws the glyph muted and says why; the next successful
    # locate.sh rewrites the file below and restarts this unit.
    if [ -z "$lat" ] || [ -z "$lon" ]; then
        report 'auto, but no location yet'
        exit 0
    fi
    set -- gammastep -m wayland -l "$lat:$lon" -t "$DAY_TEMP:$temp"
fi

report "$*"

[ "$DRY_RUN" = 0 ] || exit 0

# exec, so gammastep is this unit's own main PID: `systemctl stop` then kills
# the gamma client directly rather than a shell that happens to be holding it.
exec "$@"
