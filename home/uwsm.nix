{ lib, pkgs, ... }:

let
  # Every unit template uwsm 0.26.4 ships, in LC_ALL=C order. Written out by
  # name rather than read from the store directory with builtins.readDir: that
  # would be import-from-derivation, and it would trade a loud build failure
  # for a silent change in what gets installed. The uwsmUnits derivation below
  # cross-checks this list against the real directory, so a list that goes
  # stale is a build error rather than a unit that quietly stops existing.
  #
  # This project's signature defect is incomplete enumeration -- cataloguing by
  # one syntactic form and missing the rest. A hardcoded list with no
  # cross-check is that defect in a new place, which is why the check exists.
  #
  # C collation is not incidental. Under the machine's locale `ls` returns
  # wayland-session@.target before wayland-session-waitenv.service; under C it
  # does not, because '-' (0x2D) sorts before '@' (0x40). A list transcribed
  # from unsorted `ls` output would fail the check on a correct tree.
  unitNames = [
    "app-graphical.slice"
    "background-graphical.slice"
    "fumon.service"
    "session-graphical.slice"
    "wayland-session-bindpid@.service"
    "wayland-session-envelope@.target"
    "wayland-session-pre@.target"
    "wayland-session-shutdown.target"
    "wayland-session-waitenv.service"
    "wayland-session-xdg-autostart@.target"
    "wayland-session@.target"
    "wayland-wm-app-daemon.service"
    "wayland-wm-env@.service"
    "wayland-wm@.service"
  ];

  # A copy of uwsm's unit directory that refuses to build if the set of units
  # has changed. The files are copied rather than symlinked so the check sits
  # in the path of the files themselves -- nothing can consume the units
  # without having passed it. Copying preserves the absolute /nix/store paths
  # written inside each unit, which is the entire point of using Nix's copies
  # instead of Debian's: the only difference between the two sets is that
  # Debian's say /usr/bin/uwsm where these say the store path.
  #
  # With one exception, patched below. Thirteen of the fourteen units carry a
  # fully substituted store path; fumon.service alone ships `ExecStart=fumon`,
  # a bare name. systemd does NOT resolve those against the manager's PATH --
  # it uses a search path fixed when systemd was compiled, which on Debian is
  # /usr/local/bin:/usr/bin:/bin and friends and contains no /nix/store. The
  # bug is invisible on NixOS, whose systemd is patched to search the system
  # profile, and it was invisible here too for as long as apt's uwsm supplied
  # /usr/bin/fumon -- the unit came from Nix while the binary it ran came from
  # Debian. Removing the apt package is what exposed it.
  uwsmUnits = pkgs.runCommand "uwsm-session-units" { } ''
    expected="${lib.concatStringsSep " " unitNames}"
    actual="$(cd ${pkgs.uwsm}/share/systemd/user && LC_ALL=C ls -1 | LC_ALL=C sort | tr '\n' ' ')"
    actual="''${actual% }"
    if [ "$expected" != "$actual" ]; then
      echo "uwsm's unit set has changed." >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      echo "Update unitNames in home/uwsm.nix, then check that every added or" >&2
      echo "removed unit is accounted for in the session before shipping it." >&2
      exit 1
    fi
    mkdir -p "$out"
    cp ${pkgs.uwsm}/share/systemd/user/* "$out/"
    chmod -R u+w "$out"

    # --replace-fail, so that upstream fixing this is a build error here rather
    # than a silent no-op that leaves a stale patch in place forever. Same
    # contract as the unit-set check above: we are told when the input moves.
    substituteInPlace "$out/fumon.service" \
      --replace-fail 'ExecStart=fumon' 'ExecStart=${pkgs.uwsm}/bin/fumon'
  '';

  unitLinks = lib.listToAttrs (map
    (n: lib.nameValuePair ".config/systemd/user/${n}" {
      source = "${uwsmUnits}/${n}";
    })
    unitNames);
in
{
  # The fourteen templates at ~/.config/systemd/user -- position 5 on the user
  # manager's UnitPath, against /usr/lib/systemd/user at position 15. That
  # ordering is what makes these win; nothing has to be removed for them to
  # take effect, which is what makes the switch reversible.
  #
  # home.file rather than systemd.user.*, to avoid re-describing fourteen
  # upstream units in Nix and drifting from them.
  #
  # This does NOT keep them away from sd-switch. sd-switch is invoked on
  # $generation/home-files/.config/systemd/user, which is precisely where
  # home.file entries land, so it sees all fourteen as newly added and acts on
  # them. That matters because wayland-session-shutdown.target carries
  # Conflicts=graphical-session.target: if sd-switch starts it, systemd tears
  # the session down to satisfy the conflict. The protection is sequencing --
  # a dry run that is read, then a first switch from a TTY with no session to
  # lose. See the plan's Task 2 and Task 3.
  home.file = unitLinks // {
    # fumon.service's enablement, owned here rather than inherited.
    #
    # It is currently enabled by a root-owned symlink at
    # /etc/systemd/user/graphical-session.target.wants/fumon.service, written
    # by apt's 80-fumon.preset and pointing into /usr/lib/systemd/user.
    # Removing the package either deletes that link or leaves it dangling, and
    # neither outcome should decide whether fumon runs.
    #
    # The copy linked here is the patched one, so it runs Nix's fumon. Note
    # that this link is what actually enables the unit now: the /etc symlink
    # survived the package removal and dangles, and ~/.config wins anyway at
    # position 5 against /etc at position 6.
    ".config/systemd/user/graphical-session.target.wants/fumon.service".source =
      "${uwsmUnits}/fumon.service";
  };
}
