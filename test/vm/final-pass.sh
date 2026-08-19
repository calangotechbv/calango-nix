#!/usr/bin/env bash
# THE final pass: one command, fresh disk, no fixes applied mid-run.
#
# Iterating against a live VM is how defects are found. This is the evidence: a
# machine that did not exist when the command started, taken through every stage
# of the PUSHED RUNBOOK.md. A sequence assembled out of fixes is not evidence
# that the sequence works.
#
# End every wrapper around this script with `exit "$rc"`. A wrapper that ended
# with `echo "exit=$?"` once reported success for a failed pass, because the
# echo's status won.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"
log() { printf '\n######## %s  (%s) ########\n' "$1" "$(date -u +%H:%M:%SZ)"; }

log "stop any running VM"
pkill -x qemu-system-x86 2>/dev/null || true
while pgrep -x qemu-system-x86 > /dev/null; do sleep 2; done

log "check the step files still match the document"
"$H/check-steps.sh" || exit 1

log "Stage 0 -- the generated preseed, served verbatim from the store"
"$H/install.sh" || exit 1

log "boot the installed machine"
"$H/boot-headless.sh" > "$D/qemu-boot.out" 2>&1 &
while [ ! -S "$D/console.sock" ]; do sleep 1; done

log "Gate A through Stage D"
"$H/run-all.sh"; rc=$?

log "result"
if [ "$rc" -eq 0 ]; then
  echo "GREEN: Stage 0 through Stage D, one uninterrupted pass."
  echo "Remaining: Gate D's last two lines, which need a login at tuigreet."
else
  echo "NOT GREEN -- see the FAIL line above."
fi
exit "$rc"
