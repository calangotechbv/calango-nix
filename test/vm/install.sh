#!/usr/bin/env bash
# Stage 0 of RUNBOOK.md, for real: the GENERATED preseed, served verbatim out of
# the store, against a Debian netinst.
#
# Two things are deliberate:
#
#   * no priority=critical on the boot line. RUNBOOK.md's Stage 0 does not carry
#     it, and the point of this script is to boot the line the document prints.
#   * the served directory is the STORE PATH, not a copy. A copy can drift from
#     what .#calangoBootstrap ships, and then this rehearses a file nobody
#     installs.
#
# What a person would answer at the remaining prompts comes from
# human-answers.cfg, which rides in the initrd. See that file's own header for
# why it is not on the kernel command line.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; . "$H/lib-qemu.sh"
vm_require_no_running_vm

mkdir -p "$D"
[ -f "$CALANGO_VM_ISO" ] || { echo "no ISO at $CALANGO_VM_ISO" >&2; exit 1; }

# The installer's kernel and initrd come out of the ISO itself, so no netboot
# download is needed and the kernel matches the image being installed.
if [ ! -f "$D/vmlinuz" ] || [ ! -f "$D/initrd.gz" ]; then
  echo "extracting the installer kernel and initrd from the ISO"
  M=$(mktemp -d); trap 'fusermount -u "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
  if command -v bsdtar > /dev/null; then
    bsdtar -xOf "$CALANGO_VM_ISO" install.amd/vmlinuz > "$D/vmlinuz"
    bsdtar -xOf "$CALANGO_VM_ISO" install.amd/initrd.gz > "$D/initrd.gz"
  else
    echo "need bsdtar (libarchive-tools) to read the ISO, or drop" >&2
    echo "vmlinuz and initrd.gz into $D by hand" >&2
    exit 1
  fi
  trap - EXIT
fi

# The human's answers go into the initrd rather than onto the kernel command
# line. The command line was tried first and panicked the kernel at 30 of them:
#   Kernel panic - not syncing: Too many boot env vars at
#   `apt-setup/cdrom/set-first=false'
# d-i loads /preseed.cfg from the initrd root before it asks anything, then still
# fetches url= and applies that too. The two files answer disjoint questions,
# which is the property under test.
echo "building the preseeded initrd"
rm -rf "$D/initrd-extra"; mkdir -p "$D/initrd-extra"
# The hostname and the throwaway password come from the environment rather than
# from the file, so one copy of this harness cannot hard-code the machine it was
# written on. Everything else in human-answers.cfg is a real answer a person
# gives at the installer.
sed -e "s|^\(d-i netcfg/get_hostname string \).*|\1$CALANGO_VM_HOST|" \
    -e "s|^\(d-i netcfg/hostname string \).*|\1$CALANGO_VM_HOST|" \
    -e "s|^\(d-i passwd/root-password password \).*|\1$CALANGO_VM_PW|" \
    -e "s|^\(d-i passwd/root-password-again password \).*|\1$CALANGO_VM_PW|" \
    -e "s|^\(d-i passwd/user-password password \).*|\1$CALANGO_VM_PW|" \
    -e "s|^\(d-i passwd/user-password-again password \).*|\1$CALANGO_VM_PW|" \
    "$H/human-answers.cfg" > "$D/initrd-extra/preseed.cfg"
# Prove the substitution took: a stale hostname here would install a machine the
# steps cannot find, and a stale password would lock the driver out.
/usr/bin/grep -qF "d-i netcfg/get_hostname string $CALANGO_VM_HOST" \
  "$D/initrd-extra/preseed.cfg" || { echo "hostname substitution failed" >&2; exit 1; }
/usr/bin/grep -cF "password $CALANGO_VM_PW" "$D/initrd-extra/preseed.cfg" \
  | /usr/bin/grep -qx 4 || { echo "password substitution failed" >&2; exit 1; }
(cd "$D/initrd-extra" && printf 'preseed.cfg\n' | cpio -H newc -o --quiet | gzip -9) \
  > "$D/extra.cpio.gz"
cat "$D/initrd.gz" "$D/extra.cpio.gz" > "$D/initrd-preseeded.gz"

STORE=$(vm_bootstrap)
echo "serving $STORE"
sha256sum "$STORE/preseed.cfg"
echo "account the preseed will create: $(vm_username "$STORE")"

PORT=8${CALANGO_VM_PORT: -3}
(cd "$STORE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 \
  > "$D/http.log" 2>&1) &
HTTP=$!; trap 'kill $HTTP 2>/dev/null || true' EXIT
sleep 1
curl -sS -o /dev/null -w "preseed reachable on the host: HTTP %{http_code}\n" \
  "http://127.0.0.1:$PORT/preseed.cfg"

rm -f "$D/disk.qcow2"
qemu-img create -f qcow2 "$D/disk.qcow2" 30G > /dev/null

# The boot line is the one RUNBOOK.md prints, plus a serial console. 10.0.2.2 is
# the host as seen through qemu's user-mode networking.
$NIXGL_STRIP qemu-system-x86_64 $(qemu_common) \
  -kernel "$D/vmlinuz" -initrd "$D/initrd-preseeded.gz" \
  -append "auto=true url=http://10.0.2.2:$PORT/preseed.cfg console=ttyS0,115200n8 --- console=ttyS0,115200n8" \
  -display egl-headless,gl=on -serial file:"$D/install-serial.log" -no-reboot

if /usr/bin/grep -aq 'Installation step failed\|Kernel panic' "$D/install-serial.log"; then
  echo "STAGE 0 FAILED -- see $D/install-serial.log" >&2
  exit 1
fi
# Two GETs are expected: the curl above, then the installer's. One means the
# installer never fetched it. The host cannot tell them apart by address --
# slirp presents the guest as 127.0.0.1, same as a local curl -- so the count
# and the timestamps are the whole evidence.
echo "Stage 0 OK: $(/usr/bin/grep -ac 'GET /preseed.cfg' "$D/http.log") preseed fetches logged"
