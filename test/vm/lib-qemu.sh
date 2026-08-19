# Sourced by every script here. One device list for all of them, so PCI
# enumeration -- and therefore the predictable interface name -- cannot differ
# between the install and the boot.
#
# Configuration, all overridable from the environment:
#
#   CALANGO_VM_DIR   where the disk, logs and console socket live. NOT the repo:
#                    the disk is 30G. Default ~/vm/calango-runbook.
#   CALANGO_VM_ISO   a Debian netinst image.
#   CALANGO_VM_HOST  the hostname the VM gets, and the flake host you add in
#                    Stage B. Default calango-vm.
#   CALANGO_VM_PW    the throwaway password for the VM account. It is typed into
#                    a scratch VM over a serial console; it is not a secret and
#                    must not be reused anywhere.
#   CALANGO_VM_PORT  host port forwarded to the guest's 22. Nothing listens
#                    there -- the generated preseed installs no sshd -- but a
#                    distinct port keeps two harness copies from colliding.
#
# The ACCOUNT NAME is deliberately not configurable: it comes from the rendered
# preseed, which gets it from the flake's home.username. See vm_username below.

: "${CALANGO_VM_DIR:=$HOME/vm/calango-runbook}"
: "${CALANGO_VM_ISO:=$HOME/Downloads/debian-13.6.0-amd64-netinst.iso}"
: "${CALANGO_VM_HOST:=calango-vm}"
: "${CALANGO_VM_PW:=rehearsal}"
: "${CALANGO_VM_PORT:=2622}"

# The repo this harness tests, found from the harness's own location rather than
# hard-coded, so a clone anywhere works.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$CALANGO_VM_DIR"

qemu_common() {
  echo -n " -enable-kvm -machine q35 -cpu host -m 6G -smp 4"
  echo -n " -drive file=$D/disk.qcow2,if=virtio,cache=writeback"
  echo -n " -cdrom $CALANGO_VM_ISO"
  # -vga none is load-bearing: with qemu's default VGA present as well, Hyprland
  # opens the bochs device (pci id 1234:1111, driver (null)) and crashes in
  # pixman -- a convincing false failure.
  echo -n " -vga none -device virtio-gpu-gl-pci"
  echo -n " -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$CALANGO_VM_PORT-:22"
  echo -n " -device virtio-net-pci,netdev=n0"
}

# The five nixGL variables must not reach qemu: it is Debian's binary and a
# calango session exports Nix's mesa paths, which makes Debian's GTK load a Nix
# libEGL and abort in epoxy --
#   qemu: GtkGLArea console lacks DMABUF support.
#   epoxy_get_proc_address: Assertion `0 && "Couldn't find current GLX or EGL
#   context."' failed.
# A STRING, not a function: `exec` cannot run a shell function, and these
# scripts exec qemu so the window belongs to the process you started.
NIXGL_STRIP="env -u LD_LIBRARY_PATH -u LIBGL_DRIVERS_PATH -u GBM_BACKENDS_PATH -u LIBVA_DRIVERS_PATH -u __EGL_VENDOR_LIBRARY_FILENAMES"

# Build the bootstrap package and print its store path.
vm_bootstrap() {
  (cd "$REPO" && sg nix-users -c \
    'nix build --no-link --print-out-paths .#calangoBootstrap' | tail -1)
}

# The account name, read out of the artifact under test rather than configured
# here. The generated preseed answers `d-i passwd/username` from the flake's
# home.username, so this is the one true source and a mismatch is impossible.
vm_username() {
  local b; b="${1:-$(vm_bootstrap)}"
  /usr/bin/grep '^d-i passwd/username string ' "$b/preseed.cfg" | awk '{print $NF}'
}

vm_require_no_running_vm() {
  # qemu holds a write lock on the image, so a leftover headless run makes the
  # next script fail with `Failed to get "write" lock`, which reads like a
  # corrupt disk and is really two VMs for one file.
  if pgrep -x qemu-system-x86 > /dev/null; then
    echo "A VM is already running and holds $D/disk.qcow2." >&2
    echo "Shut it down first:  pkill -x qemu-system-x86" >&2
    return 1
  fi
}
