#!/usr/bin/env bash
# Drives RUNBOOK.md's stages in order against a booted machine, stopping at the
# first one that fails.
#
# Stage 0 is install.sh, before this: it drives the installer, not a login.
# Gate D's last two lines are not here -- they read loginctl and Hyprland's own
# /proc/<pid>/environ, so they need a person at tuigreet.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"

# drive.py reads these three. The account name comes out of the rendered
# preseed, so it cannot disagree with the account the installer created.
export CALANGO_VM_SOCK="$D/console.sock"
export CALANGO_VM_USER="$(vm_username)"
export CALANGO_VM_PW
export CALANGO_VM_HOST
echo "driving as $CALANGO_VM_USER@$CALANGO_VM_HOST over $CALANGO_VM_SOCK"

pass=0; fail=0
for f in "$H"/steps/*.txt; do
  n=$(basename "$f" .txt)
  printf '\n================ %s ================\n' "$n"
  if python3 -u "$H/drive.py" "$f" > "$D/out-$n.log" 2>&1; then
    printf 'PASS  %s\n' "$n"; pass=$((pass+1))
  else
    printf 'FAIL  %s   (see %s/out-%s.log)\n' "$n" "$D" "$n"
    tail -25 "$D/out-$n.log"; fail=$((fail+1)); break
  fi
done
printf '\n---- %d passed, %d failed ----\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
