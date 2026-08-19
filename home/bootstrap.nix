# The root-owned half of the bootstrap, declared so it can be guarded.
#
# Seventeen specs moved this machine from apt to Nix and not one of them can be
# run forwards on a new machine. The knowledge was in three places: README.md,
# system/README.md, and /etc/greetd/config.toml -- which was calango-desktop's
# reference copy, comments included, naming ../install.sh in its own header. So
# the file deciding whether this machine can log in was defined by a repository
# README.md says is "not an input to this build". This module owns that content.
#
# Two things are deliberately NOT declared here, and the distinction is the
# whole design:
#
#   DURABLE      /etc/greetd/config.toml, the group memberships. These must
#                never drift, and the activation hook below watches them.
#
#   SCAFFOLDING  the apt sources in Task 2. They exist so that ONE apt install
#                can succeed. Afterwards each vendor package writes its own
#                copy from its own postinst -- Chrome's from cron -- so the
#                files here become a duplicate source apt warns about. The
#                runbook says to delete them. Watching them forever would
#                assert something false.
{ config, lib, pkgs, ... }:

let
  cfg = config.calango.bootstrap;

  # NOTE: greetdConfig is used here only as a STRING. Task 2 turns it into a
  # store file. Do not add `pkgs.writeText` to home.packages to "reference" it:
  # home.packages goes through pkgs.buildEnv, which refuses a single-file store
  # path outright, measured against this flake's own pkgs --
  #
  #   pkgs.buildEnv error: The store path /nix/store/...-x is a file and
  #   can't be merged into an environment using pkgs.buildEnv!
  #
  # Task 2 puts the file inside a runCommand output instead, where it is copied
  # rather than merged.

  # The directories greetdConfig's command= line hands to tuigreet's --sessions.
  #
  # Parsed rather than declared twice: a second option holding the same list is
  # a second thing to keep in step, and the point of this guard is that two
  # declarations already in this flake have never been compared.
  #
  # If the line is missing or the match fails this yields [ ], every session
  # directory reads as missing, and the assertion fires. That is the correct
  # direction to fail in.
  sessionsArg =
    let
      lines = lib.splitString "\n" cfg.greetdConfig;
      line = lib.findFirst (l: lib.hasPrefix "command = " l) "" lines;
      m = builtins.match ".*--sessions ([^ \"]+).*" line;
    in
    if m == null then [ ] else lib.splitString ":" (builtins.head m);

  # The directories home/session.nix (and anything else) ships a wayland
  # session entry into, taken from the .deb manifest's own keys.
  sessionDirs = lib.unique (
    map (p: "/" + builtins.dirOf p) (
      lib.filter (p: lib.hasInfix "wayland-sessions/" p) (
        builtins.attrNames config.calango.deb.files
      )
    )
  );

  missingSessionDirs = lib.subtractLists sessionsArg sessionDirs;
in
{
  options.calango.bootstrap = {
    greetdConfig = lib.mkOption {
      type = lib.types.lines;
      description = "The whole /etc/greetd/config.toml. Content, never a path.";
    };
    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Unix groups the desktop account must hold.";
    };
  };

  config.calango.bootstrap = {
    greetdConfig = builtins.readFile ./../bootstrap/greetd-config.toml;

    # nix-users opens the daemon socket directory, which is 0770 root:nix-users.
    # video opens the DRM device and input the keyboard and pointer.
    #
    # render is NOT here, and system/README.md's instruction to add it is
    # unnecessary: `id` on the working account shows video, input and nix-users
    # and no render.
    groups = [ "nix-users" "video" "input" ];
  };

  config.assertions = [
    {
      # Vacuity anchor. An empty declaration makes the file check below compare
      # the live file against nothing and report agreement.
      assertion = cfg.greetdConfig != "";
      message = ''
        calango.bootstrap.greetdConfig is empty. The activation hook would
        compare /etc/greetd/config.toml against an empty file and report a
        difference it cannot explain, and a machine installing that file would
        have no greeter at all.
      '';
    }
    {
      # Vacuity anchor for the group half of the hook.
      assertion = cfg.groups != [ ];
      message = ''
        calango.bootstrap.groups is empty, so the activation hook's group
        check iterates nothing and prints nothing. Without nix-users no nix
        command works; without video and input the compositor opens neither
        the DRM device nor the keyboard.
      '';
    }
    {
      # Vacuity anchor for the guard below: with no session entry in the
      # manifest, subtractLists returns [ ] and the guard passes while the
      # machine has no way to start a session at all.
      assertion = sessionDirs != [ ];
      message = ''
        No calango.deb.files entry ships a file under wayland-sessions/, so
        the session-path guard below has nothing to check and greetd would
        offer no calango-nix session. home/session.nix is what declares it.
      '';
    }
    {
      # The guard this module exists for. home/session.nix says WHERE the
      # session entry goes; greetdConfig says WHERE the greeter looks. Nothing
      # has ever compared them, and a disagreement gives a working greeter
      # that cannot offer its own session -- which looks like a greetd fault.
      assertion = missingSessionDirs == [ ];
      message = ''
        A wayland session entry is shipped into a directory that
        calango.bootstrap.greetdConfig's --sessions does not name:

          shipped into : ${lib.concatStringsSep " " sessionDirs}
          --sessions   : ${lib.concatStringsSep " " sessionsArg}
          unreachable  : ${lib.concatStringsSep " " missingSessionDirs}

        greetd would start, tuigreet would draw, and the calango-nix session
        would not be in the list. Either add the directory to the command=
        line in bootstrap/greetd-config.toml, or ship the entry into a
        directory already named there.
      '';
    }
  ];

  # No home.packages entry in this task, deliberately -- see the NOTE at the top
  # of the let block. Task 2 adds `config.home.packages = [ bootstrapDir ]`, a
  # directory, which buildEnv accepts.
}
