#!/usr/bin/env sh
# Generate a quickshell "wallpaper" theme from an image, using matugen or wallust.
#
# It only writes the palette to wallpaper-theme.json — it does NOT switch the
# shell into wallpaper mode. quickshell live-reloads the file and, if you're in
# wallpaper mode, repaints instantly.
#
# To both regenerate the palette AND switch into wallpaper mode, call the IPC
# instead, which runs this script for you:
#     qs ipc call theme wallpaper <image>
#
# This script is the lower-level entry point if you only want to refresh the
# palette without changing mode (e.g. a wallpaper-daemon hook). For awws:
#     [daemon]
#     on_change = "<store path>/theme-switcher/wallpaper-theme/set.sh %w"
#     (find it with: systemctl --user cat quickshell | grep ExecStart)
#
# Force a specific tool with WALLPAPER_THEME_TOOL=matugen|wallust (default: auto).
set -eu

img=${1:-}
[ -n "$img" ] || { echo "set.sh: usage: set.sh <image>" >&2; exit 1; }
[ -f "$img" ] || { echo "set.sh: no such image: $img" >&2; exit 1; }

dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tool=${WALLPAPER_THEME_TOOL:-auto}

# Two deliberate deviations from calango-desktop's matugen invocation, both
# forced by matugen 4.0.0:
#
# - `--prefer saturation` is gone; a scheme is now chosen with -t/--type
#   <scheme-*> (default: scheme-tonal-spot). No --type is passed here: that
#   picks an aesthetic on the user's behalf, and the working, reversible
#   default is left alone. If you want saturation-leaning colors back, the
#   successor is `-t scheme-vibrant`, added deliberately, not by default.
#
# - `--source-color-index 0` IS added, and is load-bearing, not
#   cosmetic: do not "clean it up". set.sh is invoked by quickshell as a
#   systemd-managed Process with no controlling tty. When source-color
#   extraction finds more than one candidate colour, matugen either asks
#   an interactive terminal to pick one or, with none available, fails
#   outright with "IO error: not a terminal" -- every time, in production,
#   not just under test. --source-color-index picks a candidate by index
#   instead of prompting; 0 is the first/dominant one, which is what any
#   headless run has to assume. This is mechanical, not aesthetic -- pick
#   a different index if a particular wallpaper's dominant candidate is
#   wrong, but the flag itself must stay for matugen to run at all here.
run_matugen() { matugen image "$img" -c "$dir/matugen/config.toml" -m dark -q --source-color-index 0; }
run_wallust() { wallust run "$img" -d "$dir/wallust" -s -q; }

case "$tool" in
  matugen) run_matugen ;;
  wallust) run_wallust ;;
  auto)
    if command -v matugen >/dev/null 2>&1; then run_matugen
    elif command -v wallust >/dev/null 2>&1; then run_wallust
    else echo "set.sh: need matugen or wallust installed" >&2; exit 1
    fi ;;
  *) echo "set.sh: unknown WALLPAPER_THEME_TOOL=$tool" >&2; exit 1 ;;
esac
