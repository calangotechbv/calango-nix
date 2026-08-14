{ config, lib, pkgs, ... }:

let
  # Written by quickshell's theme switcher on every theme change, so it must
  # live outside the read-only store. quickshell/common/Paths.qml names this
  # same path as footStateDir; the two must agree or the palette is written
  # somewhere foot never reads.
  footState = "${config.home.homeDirectory}/.local/state/foot";

  footConfig = pkgs.runCommand "foot-config" { } ''
    cp -r ${./../foot} "$out"
    chmod -R u+w "$out"

    substituteInPlace "$out/foot.ini" \
      --replace-fail '@footThemes@' "$out/themes" \
      --replace-fail '@footState@'  '${footState}'

    # foot's `include` takes one fixed absolute path -- no glob, no
    # environment expansion, no program to run -- which is why calango-desktop
    # had install.sh generate a foot/host.ini whose entire content was a line
    # pointing at another file. Resolved here instead, against the tree that
    # was just copied, so there is no generated file to go stale when the
    # machine is renamed.
    #
    # A machine with no hosts/<host>.ini gets no include line at all. foot
    # treats a missing include target as fatal, so an include pointing at a
    # file that is not there would stop foot starting altogether.
    if [ -f "$out/hosts/${config.calango.host}.ini" ]; then
      substituteInPlace "$out/foot.ini" \
        --replace-fail '@footHostInclude@' \
          "include=$out/hosts/${config.calango.host}.ini"
    else
      substituteInPlace "$out/foot.ini" \
        --replace-fail '@footHostInclude@' \
          "# no foot/hosts/${config.calango.host}.ini on this machine"
    fi

    # Same guard and same invariant as home/hyprland.nix: substitution tokens
    # are lowercase-alpha, so [a-zA-Z]* cannot match end to end against an
    # UPPERCASE placeholder. foot.ini's only literal @ is `kitten @` in a
    # comment -- one character, which cannot match a pair. Do not widen this
    # to digits or underscores.
    if grep -q '@[a-zA-Z]*@' "$out/foot.ini"; then
      echo "unsubstituted token left in foot.ini:" >&2
      grep -n '@[a-zA-Z]*@' "$out/foot.ini" >&2
      exit 1
    fi
  '';
in
{
  # No `calango.footState` option: nothing in Nix consumes this path. Its only
  # other reader is quickshell/common/Paths.qml, which is QML and cannot read a
  # Home Manager option. An exported option nothing evaluates would be dead
  # weight pretending to be a contract; the comment above footState is the
  # contract, and Task 4's verification is what enforces it.

  # pkgs.foot is already in home/default.nix's home.packages, where it is
  # documented as the shm-drawing control for the GL ladder. Not repeated here.

  config.xdg.configFile."foot".source = footConfig;

  # A .keep forces the parent to be created as a real directory. The palette
  # file itself must NOT be a home.file: that would make it a store symlink,
  # and Theme.qml writes it with `printf >`, which fails on a read-only store
  # path. This is the distinction spec 2's .keep pattern does not carry --
  # nothing ever writes to a .keep.
  config.home.file.".local/state/foot/.keep".text = "";

  # foot refuses to start when an `include` target is missing, so this file
  # must exist before the first launch; empty is a valid foot config.
  #
  # Deliberately NOT suffixed with `|| true`, unlike the other activation
  # hooks in this port. If a mkdir and a touch under $HOME cannot run, foot
  # will not start, and a switch that fails loudly leaves the previous
  # generation active -- which is better than one that succeeds and leaves no
  # terminal. The spec asks for non-fatal hooks as a general rule; this is the
  # one that is load-bearing rather than cosmetic.
  config.home.activation.footThemeColors =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${lib.escapeShellArg "${footState}/theme-colors.ini"} ]; then
        run mkdir -p ${lib.escapeShellArg footState}
        run touch ${lib.escapeShellArg "${footState}/theme-colors.ini"}
      fi
    '';
}
