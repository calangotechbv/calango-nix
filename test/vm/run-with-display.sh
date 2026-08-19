#!/usr/bin/env bash
# The same machine in a window. Run it from a graphical session, not a tty.
#
# Log in with the account the preseed created and pick "Hyprland (Nix)" at
# tuigreet. This is the only way to answer Gate D's last two lines and the only
# way to see whether the desktop is right: no harness here can do either.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"
vm_require_no_running_vm
echo "account: $(vm_username)   password: $CALANGO_VM_PW"
exec $NIXGL_STRIP qemu-system-x86_64 $(qemu_common) -boot order=c \
  -display gtk,gl=on
