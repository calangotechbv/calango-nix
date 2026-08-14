#!/bin/sh
# Suspends this machine after hypridle says it has been idle long enough --
# but only if it is a laptop, and only if it is running on its own battery.
#
# hypr/hypridle.conf calls this at 900 seconds and cancels it on resume. The
# listener there carries no policy at all, and this is why: hypridle.conf is
# one file on every host, copied around by Syncthing, and hypridle has no
# includes and no conditionals. The repo's per-host mechanism --
# hypr/hosts/<hostname>.lua, picked by hyprland.lua reading /etc/hostname -- is
# not reachable from hypridle either.
#
# So the decision is made here, at runtime, from /sys and logind. That is not a
# workaround for the above; it is the better answer. suffer should sleep
# because it has a battery, not because of what it is called, and epiphany
# should decide for itself rather than be told by a file that arrived over
# Syncthing.
#
# What is deliberately NOT here: holding off the sleep while the stay-awake
# pill is up. That is already covered. The pill holds a wayland idle inhibitor
# on the bar surface (quickshell/bar/Bar.qml), the compositor then stops
# reporting idle, and hypridle's timers -- all of them, including the one that
# calls this file -- never start counting. This script is not run at all.
#
# Every probe root is an environment variable and every external command is
# reached through PATH, so tests/idle-sleep.sh can fake all of it.
set -u

# Only the two this task uses. The other four arrive in the tasks that first
# read them -- ASOUND in Task 2, INTERVAL and MAX_WAIT in Task 3, PIDFILE in
# Task 4. Declaring all six here would be SC2034 (assigned but never used) at
# the end of this task, and `make lint` is a gate after every task, not only
# after the last one.
SYSFS=${IDLE_SLEEP_SYSFS:-/sys/class/power_supply}
DRY_RUN=${IDLE_SLEEP_DRY_RUN:-0}
ASOUND=${IDLE_SLEEP_ASOUND:-/proc/asound}
INTERVAL=${IDLE_SLEEP_INTERVAL:-60}

# A zero or non-numeric interval would leave _waited standing still while the
# loop below span, so the give-up would never fire: a busy loop with no way
# out. One second is the smallest honest floor. The tests pass 0 on purpose --
# they stub `sleep` itself, so their waiting is free either way -- and this
# keeps the counter advancing for them too.
[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=1

MAX_WAIT=${IDLE_SLEEP_MAX_WAIT:-14400}

# Clamped for the same reason INTERVAL is, and it is the same failure. A
# non-numeric MAX_WAIT makes the give-up test below throw `[: illegal number` on
# stderr every single poll and then evaluate false, so the loop never gives up:
# an unbreakable loop plus a line of noise a minute into hypridle's log. Zero is
# a legitimate value -- it means give up on the first pass, which the tests use --
# so the floor is zero and not one.
[ "$MAX_WAIT" -ge 0 ] 2>/dev/null || MAX_WAIT=14400

PIDFILE=${IDLE_SLEEP_PIDFILE:-${XDG_RUNTIME_DIR:-/tmp}/idle-sleep.pid}

report() {
    printf 'idle-sleep: %s\n' "$1"
}

# on-resume calls this. Kill by PID rather than by name: `pkill -f` on a script
# path would also match a second, unrelated checkout, and the pidfile is the
# same thing that stops two loops stacking anyway.
#
# The removal hangs off the kill succeeding. Clearing the file after a kill that
# failed would leave a loop still polling with nothing left pointing at it: it
# could not be cancelled again, and the next on-timeout would see no pidfile and
# start a second one alongside it. A kill that fails is either a stale pidfile,
# which the startup check below already steps over, or a live process this user
# may not signal -- and neither is improved by forgetting the PID.
cancel() {
    [ -r "$PIDFILE" ] || return 0
    _pid=$(cat "$PIDFILE" 2>/dev/null || true)
    [ -n "$_pid" ] && { kill "$_pid" 2>/dev/null || return 0; }
    rm -f "$PIDFILE"
    return 0
}

# Is $1 a battery this machine actually runs on? Read type= rather than globbing
# BAT*, because suffer's tree also holds two ucsi-source-psy-USBC000:* entries
# and the next machine may not call its battery BAT1 either. A scope=Device
# supply is a peripheral -- a wireless mouse, a headset, the bluetooth devices
# quickshell/bluetooth already draws battery levels for -- and is not it.
#
# One helper for both callers below, because the two must agree. When on_battery
# had its own copy of this filter, deleting the scope line from it left every
# test passing and turned a discharging laptop with a mouse reading Full into
# "skip: on ac" -- a machine that never sleeps on battery while a peripheral is
# charged.
system_battery() {
    [ "$(cat "$1/type" 2>/dev/null || true)" = Battery ] || return 1
    [ "$(cat "$1/scope" 2>/dev/null || true)" = Device ] && return 1
    return 0
}

has_battery() {
    for _d in "$SYSFS"/*; do
        system_battery "$_d" && return 0
    done
    return 1
}

# Every system battery must read Discharging. Anything else -- Charging, Full,
# Not charging -- means power is arriving from somewhere and this machine can
# afford to stay up.
#
# Read the battery and not ACAD/online, because a laptop charging over USB-C
# Power Delivery does not always raise the Mains supply. On suffer the charger
# appears as ucsi-source-psy-USBC000:001, which is type=USB.
on_battery() {
    _found=0
    for _b in "$SYSFS"/*; do
        system_battery "$_b" || continue
        [ -r "$_b/status" ] || continue
        _found=1
        [ "$(cat "$_b/status")" = Discharging ] || return 1
    done
    [ "$_found" = 1 ]
}

# Two probes, because neither covers the other. /proc/asound is kernel-level
# and dependency-free, and catches a program talking to the hardware directly.
# It cannot see a bluetooth sink, which has no ALSA card, so pactl covers that
# where it is installed -- an optional dependency, not a required one.
#
# pcm*p, not pcm*c: `p` is playback and `c` is capture. A capture stream is a
# microphone, and an app that leaves one open would otherwise hold this gate
# until the four-hour cap. A video call opens both and holds its own wayland
# idle inhibitor anyway, so none of this runs during one.
audio_active() {
    for _s in "$ASOUND"/card*/pcm*p/sub*/status; do
        [ -r "$_s" ] || continue
        grep -q RUNNING "$_s" && return 0
    done
    command -v pactl >/dev/null 2>&1 || return 1
    pactl list short sinks 2>/dev/null | grep -q RUNNING
}

# Class=user skips the `manager` session systemd opens for the user, and State
# skips one that is closing. The ids come from the first column of
# list-sessions, read into a for-list rather than piped into a `while` loop,
# because a pipeline runs its right-hand side in a subshell and a `return` in
# there returns from nothing.
remote_session() {
    for _id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        _p=$(loginctl show-session "$_id" -p Remote -p State -p Class 2>/dev/null || true)
        case $_p in *Remote=yes*) ;; *) continue ;; esac
        case $_p in *Class=user*) ;; *) continue ;; esac
        case $_p in *State=active*|*State=online*) return 0 ;; esac
    done
    return 1
}

# BlockInhibited is one colon-separated string and it answers exactly the
# question being asked. `systemd-inhibit --list` is the other way to ask, and
# it is eight space-separated columns of which one -- the reason -- is free
# text with spaces in it.
#
# Note BlockInhibited and not DelayInhibited. delay inhibitors are how
# NetworkManager and 1Password get their few seconds before the machine goes
# down; they are not a veto and must not be read as one.
#
# hypridle honours dbus and systemd inhibits already, but it applies that to
# the idle *event*, upstream of this script. An inhibitor taken out at minute
# fourteen would otherwise reach a `systemctl suspend` that fails into a log
# nobody reads.
sleep_blocked() {
    _b=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
             org.freedesktop.login1.Manager BlockInhibited 2>/dev/null || true)
    case $_b in *sleep*) return 0 ;; esac
    return 1
}

# Ask logind at the moment of acting rather than deciding at install time.
# Hibernation is unavailable on suffer today -- Secure Boot puts the kernel in
# `integrity` lockdown, which drops `disk` from /sys/power/state -- so this
# answers "na" and the machine suspends instead. Turn Secure Boot off and it
# starts hibernating with no edit here. "challenge" means logind would demand a
# polkit authentication, which nothing can answer on an idle machine, so only
# "yes" counts.
sleep_action() {
    _can=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
               org.freedesktop.login1.Manager CanSuspendThenHibernate 2>/dev/null || true)
    case $_can in
        *'"yes"'*) printf 'suspend-then-hibernate\n' ;;
        *)         printf 'suspend\n' ;;
    esac
}

# hypridle fires on-timeout exactly once per idle period. So a soft gate that
# exits does not mean "sleep later", it means "do not sleep until someone
# touches this machine and then leaves it again" -- music started before the
# timer would keep the laptop up all night, long after the album ended.
#
# Poll instead, and let hypridle's on-resume kill this with --cancel when the
# session comes back. Video needs none of it: mpv and browsers hold their own
# wayland idle inhibitors, so the compositor never reports idle and the 900
# second timer never starts. The loop is for the players that do not.
main() {
    has_battery || { report "skip: no battery"; return 0; }
    on_battery  || { report "skip: on ac"; return 0; }

    _waited=0
    while :; do
        if audio_active; then
            _reason=audio
        elif remote_session; then
            _reason="remote session"
        elif sleep_blocked; then
            _reason=inhibitor
        else
            _action=$(sleep_action)
            report "$_action"
            [ "$DRY_RUN" = 1 ] && return 0
            systemctl "$_action"
            return 0
        fi

        report "wait: $_reason"

        # A dry run answers the question and stops. It is for a human at a
        # prompt asking "what would you do now", not a way to watch the loop.
        [ "$DRY_RUN" = 1 ] && return 0

        if [ "$_waited" -ge "$MAX_WAIT" ]; then
            report "give up: $_reason"
            return 0
        fi

        sleep "$INTERVAL"
        _waited=$((_waited + INTERVAL))
    done
}

case ${1:-} in
    --cancel) cancel; exit 0 ;;
    "")       ;;
    *)        report "usage: $0 [--cancel]" >&2; exit 2 ;;
esac

# hypridle can fire on-timeout again after a resume this script did not see, so
# a second instance stands down rather than starting a second loop.
if [ -r "$PIDFILE" ]; then
    _other=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$_other" ] && kill -0 "$_other" 2>/dev/null; then
        report "skip: already waiting (pid $_other)"
        exit 0
    fi
fi

# The trap goes on only after the file is ours. Arming it before the check
# above would make the instance that correctly stands down delete the running
# instance's pidfile as it exits, which is precisely backwards.
printf '%s\n' "$$" > "$PIDFILE"

# Two traps and not one. A non-EXIT trap in POSIX sh resumes execution where the
# signal arrived once the handler returns, so a shared handler that only removes
# the pidfile would let --cancel's kill land, tidy the file away, and leave the
# loop polling -- with the pidfile gone, so nothing could ever kill it again.
# That is the failure this listener exists to avoid: you come back, hypridle
# fires on-resume, and the machine suspends under your hands a minute later. The
# signal handler has to exit itself. 143 is 128+SIGTERM, what a shell reports for
# a process killed by one.
trap 'rm -f "$PIDFILE"' EXIT
trap 'rm -f "$PIDFILE"; exit 143' INT TERM

main
