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
      # Print only the difference. Two 14-item lines exceed Nix's default log
      # tail and leave the reader to diff them by eye; the added and removed
      # names are what the fix actually needs.
      echo "uwsm's unit set has changed." >&2
      echo "$expected" | tr ' ' '\n' | LC_ALL=C sort > expected.txt
      echo "$actual"   | tr ' ' '\n' | LC_ALL=C sort > actual.txt
      LC_ALL=C comm -13 expected.txt actual.txt | sed 's/^/  added:   /' >&2
      LC_ALL=C comm -23 expected.txt actual.txt | sed 's/^/  removed: /' >&2
      echo "Update unitNames in home/uwsm.nix, then check that every added or" >&2
      echo "removed unit is accounted for in the session before shipping it." >&2
      exit 1
    fi
    mkdir -p "$out"
    cp ${pkgs.uwsm}/share/systemd/user/* "$out/"
    chmod -R u+w "$out"

    # --replace-fail, so that upstream fixing this is a build error here rather
    # than a silent no-op that leaves a stale patch in place forever.
    test -x ${pkgs.uwsm}/bin/fumon
    substituteInPlace "$out/fumon.service" \
      --replace-fail 'ExecStart=fumon' 'ExecStart=${pkgs.uwsm}/bin/fumon'

    # The two checks above are both exact: one on the set of unit *names*, one
    # on a single byte string. Neither says anything about the other thirteen
    # files' contents, and the defect that reached a reboot lived precisely
    # there -- inside a file whose name the check had already approved. So
    # assert the actual property we depend on, over every unit at once: after
    # patching, no Exec directive anywhere may be a relative program name.
    #
    # `^Exec[A-Za-z]*=` rather than a list of directive names. Enumerating the
    # directives by hand is what produced the bug: a hand-written list here
    # missed ExecStopPost=, which happens to be absolute, and would equally
    # have missed a relative one. The prefix characters @ - : + ! are systemd's
    # exec modifiers and are stripped before the path is examined.
    relative="$(
      grep -hE '^Exec[A-Za-z]*=' "$out"/* \
        | sed -E 's/^Exec[A-Za-z]*=//; s/^[@:+!-]+//' \
        | awk 'NF && $1 !~ /^\// { print }'
    )" || true
    if [ -n "$relative" ]; then
      echo "uwsm ships an Exec directive that is not an absolute path:" >&2
      echo "$relative" | sed 's/^/  /' >&2
      echo "systemd resolves these against a compile-time search path, not" >&2
      echo "the manager's PATH, and no /nix/store entry is on it. Patch the" >&2
      echo "directive in home/uwsm.nix the way ExecStart=fumon is patched." >&2
      exit 1
    fi
  '';

  unitLinks = lib.listToAttrs (map
    (n: lib.nameValuePair "systemd/user/${n}" {
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
  # xdg.configFile rather than systemd.user.*, to avoid re-describing fourteen
  # upstream units in Nix and drifting from them. xdg.configFile rather than
  # home.file.".config/...": home-manager's own systemd module writes user
  # units through xdg.configFile, and sd-switch follows xdg.configHome, not a
  # literal ".config" -- identical today since xdg.configHome defaults to
  # ~/.config, but a literal path would silently stop being seen if
  # xdg.configHome were ever set elsewhere.
  #
  # This does NOT keep them away from sd-switch. sd-switch is invoked on
  # $generation/home-files/.config/systemd/user, which is precisely where
  # xdg.configFile entries land, so it sees all fourteen as newly added and
  # acts on them. That matters because wayland-session-shutdown.target carries
  # Conflicts=graphical-session.target: if sd-switch starts it, systemd tears
  # the session down to satisfy the conflict. The protection is sequencing --
  # a dry run that is read, then a first switch from a TTY with no session to
  # lose. See the plan's Task 2 and Task 3.
  xdg.configFile = unitLinks // {
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
    "systemd/user/graphical-session.target.wants/fumon.service".source =
      "${uwsmUnits}/fumon.service";
  };
}
