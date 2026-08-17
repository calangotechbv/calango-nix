{ lib, pkgs, ... }:

{
  # Warn when apt considers packages unnecessary.
  #
  # This exists because 137 of them accumulated silently. Four specs removed
  # packages, each printed a "no longer required" list, and none of them was
  # acted on -- so a single `apt autoremove` became able to sweep 137 packages
  # at once, at which point the breakage would look like whatever changed most
  # recently. CLAUDE.md recorded that hazard twice, with rtkit and
  # pulseaudio-utils, before this happened anyway.
  #
  # Non-fatal, and the reason is the same one home/apps.nix's mimeappsIds gives:
  # this is apt's state, not this flake's. A switch must never abort because the
  # Debian side has cruft on it.
  #
  # Activation and not a flake check, because a flake check cannot see
  # /var/lib/dpkg -- the Nix sandbox has no view of apt at all. Same two-layer
  # conclusion spec 10 reached for .desktop identity: the fatal half asserts
  # what the flake ships, and only the activation half can observe the machine.
  #
  # `|| true` on the count, and this is load-bearing rather than defensive:
  # `grep -c` prints 0 and exits 1 when it matches nothing, and the activation
  # script runs with `set -eu` and `set -o pipefail` both on (activate lines
  # 2-3). Without it, a machine with a clean orphan list would abort its own
  # switch, and the failure would arrive with no message at all. This is the
  # same trap spec 11 hit inside a Nix builder; it applies here for the same
  # reason.
  #
  # Costs about one second per switch, measured: `apt-get -s autoremove` took
  # 989 ms. It needs no privileges -- verified as uid 1000, exit 0.
  config.home.activation.aptOrphanWarning =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.bash}/bin/sh -c '
        [ -x /usr/bin/apt-get ] || exit 0
        n=$(/usr/bin/apt-get -s autoremove 2>/dev/null | grep -c "^Remv " || true)
        [ -n "$n" ] || n=0
        [ "$n" -eq 0 ] && exit 0
        echo "apt: $n package(s) are autoremovable." >&2
        echo "  Read \`apt-get -s autoremove\` before anything runs it for you." >&2
        echo "  An unmarked orphan gets swept at some later moment, and the" >&2
        echo "  breakage then looks like whatever changed most recently." >&2
        echo "  See docs/2026-08-17-results-suffer-apt-orphan-backlog.md." >&2
      ' || true
    '';
}
