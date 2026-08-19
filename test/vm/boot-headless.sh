#!/usr/bin/env bash
# Boots the installed machine with its console on a unix socket, which is how
# drive.py talks to it.
#
# There is no ssh here on purpose: the generated preseed's tasksel line is
# `standard` only, so this machine has no sshd. Spec 18's rehearsal added
# ssh-server as a harness deviation, and a 9p share as well -- and the share is
# why its Stage B passed while the `git clone` in the document was broken. If the
# harness supplies something, the runbook is not being tested on it.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"
vm_require_no_running_vm
rm -f "$D/console.sock"
exec $NIXGL_STRIP qemu-system-x86_64 $(qemu_common) -boot order=c \
  -display egl-headless,gl=on \
  -serial unix:"$D/console.sock",server=on,wait=off
