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
  # `|| true` on the count is DEFENSIVE here, not load-bearing, and an earlier
  # version of this comment claimed the opposite on the strength of a mutation
  # that tested a different program from the one this file ships.
  #
  # The reasoning was: `grep -c` prints 0 and exits 1 at zero matches, the
  # activation script runs `set -eu` with `set -o pipefail` (activate lines
  # 2-3), so without the clause a machine with a *clean* orphan list would abort
  # its own switch. Every clause of that is true except the one that matters.
  # This body does not run in the activation script's shell. It runs in a child
  # `sh -c`, and shell options are not inherited across an exec:
  #
  #   $-                      hBc          <- no `e`
  #   set -o | grep errexit   errexit  off
  #   set -o | grep pipefail  pipefail off
  #
  # `SHELLOPTS` is not exported by `activate`, so nothing carries them in.
  # Measured with the clause deleted and the census genuinely 0: the body runs
  # to the end and returns 0. The mutation that "proved" it necessary had been
  # run on the body *inlined* into a `set -eu`/`pipefail` shell, where it does
  # return 1 — a real measurement of a program this flake does not contain.
  #
  # The clause stays. It costs nothing and it is correct if this body is ever
  # inlined, which is the shape most activation hooks take. But it is not what
  # keeps this hook non-fatal. Three other things do: the child shell has no
  # errexit; `run … || true` puts the whole call in an OR list, which exempts it
  # from the caller's errexit; and `[ "$n" -eq 0 ] && exit 0` is not the last
  # command in the body, so its false branch cannot become the exit status.
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
