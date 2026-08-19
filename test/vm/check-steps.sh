#!/usr/bin/env bash
# Does this harness still test the document it claims to test?
#
# steps/*.txt transcribe RUNBOOK.md's commands by hand -- they have to, because
# each one is wrapped in a marker, a timeout and a redirect. That transcription
# is the one place the harness can silently disagree with the document: edit the
# runbook, and the harness goes on happily testing the old wording.
#
# So every step line that mirrors a runbook command carries the runbook's own
# text above it:
#
#     #= sudo apt update
#     sudo apt update 2>&1 | tail -5
#
# This asserts each `#=` line appears VERBATIM in the rendered RUNBOOK.md. Lines
# with no `#=` are the harness's own -- accommodations, counts, probes -- and are
# commented as such in the step files.
#
# Run it before a pass; final-pass.sh does.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"

B=$(vm_bootstrap)
R="$B/RUNBOOK.md"
[ -f "$R" ] || { echo "no RUNBOOK.md in $B" >&2; exit 1; }

total=0
missing=0
while IFS= read -r line; do
  total=$((total + 1))
  # -F: the runbook is full of $, ", * and \n, none of it a regex here.
  if ! /usr/bin/grep -qF -- "$line" "$R"; then
    printf 'MISSING from RUNBOOK.md:\n  %s\n' "$line"
    missing=$((missing + 1))
  fi
done < <(sed -n 's/^#= //p' "$H"/steps/*.txt)

# The vacuity anchor. Without it, deleting every `#=` line -- or renaming the
# steps directory -- makes this print "0 of 0 verified" and exit 0, which is
# exactly what "the property holds" looks like for a check with nothing in it.
if [ "$total" -eq 0 ]; then
  echo "no '#=' lines found in $H/steps -- this check asserted nothing" >&2
  exit 1
fi

if [ "$missing" -ne 0 ]; then
  printf '\n%d of %d step lines no longer appear in RUNBOOK.md.\n' "$missing" "$total" >&2
  echo "Either the document changed and the steps must follow, or a step was" >&2
  echo "  written against a runbook that no longer exists." >&2
  exit 1
fi

printf 'ok  %d step lines all appear verbatim in %s\n' "$total" "$R"
