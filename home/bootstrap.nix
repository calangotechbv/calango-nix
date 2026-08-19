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

  greetdFile = pkgs.writeText "greetd-config.toml" cfg.greetdConfig;

  # deb822 continuation: every line of the armored block gets one leading
  # space, and an empty line becomes " .". Documented in `man 5 sources.list`,
  # which is the authority used here -- no apt version floor is claimed,
  # because none was measured. apt on suffer is 3.0.3.
  indentKey =
    key:
    lib.concatMapStrings (l: (if l == "" then " ." else " " + l) + "\n") (
      lib.splitString "\n" (lib.removeSuffix "\n" key)
    );

  keyFile = name: builtins.readFile (./../bootstrap/keys + "/${name}.asc");

  stanza =
    {
      uris,
      suites,
      key,
      components ? "main",
      architectures ? "amd64",
    }:
    ''
      Types: deb
      URIs: ${uris}
      Suites: ${suites}
      Components: ${components}
      Architectures: ${architectures}
      Signed-By:
    ''
    + indentKey (keyFile key);

  # A root-owned file must never name the Nix store: if the path is collected
  # the file points at nothing, and unlike everything else here that failure is
  # not recoverable from a running desktop. home/deb.nix's noStorePaths guards
  # the .deb manifest for the same reason.
  #
  # Scoped to etc/ deliberately. RUNBOOK.md is not root-owned and must name the
  # built directory to be useful; Task 3 has it use a shell variable anyway.
  #
  # The needle is built by concatenation, as home/deb.nix's is, because written
  # plainly this builder's own source contains it and the guard fails forever.
  noStorePathsInEtc =
    pkgs.runCommand "calango-bootstrap-no-store-paths"
      {
        inherit bootstrapTree;
        needle = "/nix" + "/store";
      }
      ''
        # A condition, not a bare command: a builder runs with errexit and a
        # grep matching nothing exits 1, which here is the PASSING case.
        if grep -rn -F -- "$needle" "$bootstrapTree/etc" >&2; then
          echo "" >&2
          echo "A file under etc/ names the Nix store." >&2
          echo "  These files are installed with root and outlive any" >&2
          echo "  generation. When the store path is collected the file" >&2
          echo "  points at nothing, and for /etc/greetd/config.toml that" >&2
          echo "  means no login." >&2
          exit 1
        fi
        touch "$out"
      '';

  bootstrapTree = pkgs.runCommand "calango-bootstrap-tree" { } ''
    mkdir -p "$out/etc/greetd" "$out/etc/apt/sources.list.d"
    cp ${greetdFile} "$out/etc/greetd/config.toml"
    ${lib.concatStrings (
      lib.mapAttrsToList (n: v: ''
        cp ${pkgs.writeText "apt-source-${n}" v} "$out/etc/apt/sources.list.d/${n}"
      '') cfg.aptSources
    )}
    cp ${runbook} "$out/RUNBOOK.md"
  '';

  # Substitution happens in NIX, not in the builder's shell, and that is
  # load-bearing rather than stylistic. substituteInPlace's replacement value is
  # interpolated into a SINGLE-QUOTED shell argument, so an apostrophe in a
  # reason string closes the quote. Measured against this flake's own pkgs:
  #
  #   line 2: unexpected EOF while looking for matching `'
  #
  # Four of the seventeen reasons contain one -- flake.nix's, Nix's, Debian's,
  # nixpkgs'. Fixing the strings instead is fragile: the next reason to gain an
  # apostrophe breaks the build, and nothing warns whoever wrote it.
  # builtins.replaceStrings has no shell anywhere in the path.
  #
  # This gives up ONE property substituteInPlace --replace-fail provided --
  # that the token exists -- because replaceStrings silently does nothing for an
  # absent token. requireToken restores it, and it throws at evaluation rather
  # than at build.
  #
  # home/hyprland.nix and home/gtk.nix use substituteInPlace, so this is a
  # second idiom in the tree. It is here because their substituted values are
  # store paths and hostnames, which cannot contain an apostrophe, and these
  # are English sentences, which routinely do.
  requireToken =
    tok: body:
    if lib.hasInfix tok body then
      body
    else
      throw "runbook token ${tok} is not in bootstrap/runbook.md.in";

  # A table row per entry, so the reason travels with the name. mapAttrsToList
  # gives them in Nix's sorted-key order, which is stable across builds.
  reasonTable =
    attrs:
    lib.concatStrings (lib.mapAttrsToList (n: why: "| `${n}` | ${why} |\n") attrs);

  substitutions = {
    "@basePackagesOneLine@" = lib.concatStringsSep " " (
      builtins.attrNames cfg.packages.base
    );
    "@basePackagesTable@" =
      "| package | why |\n|---|---|\n" + reasonTable cfg.packages.base;
    "@corpPackagesTable@" =
      "| package | source |\n|---|---|\n" + reasonTable cfg.packages.corp;
    # The two that come from no repository are installed from files, so they are
    # excluded from the one apt install line the runbook prints.
    "@corpRepoPackagesOneLine@" = lib.concatStringsSep " " (
      lib.filter (p: p != "slack-desktop" && p != "fresh-editor") (
        builtins.attrNames cfg.packages.corp
      )
    );
    "@groupsComma@" = lib.concatStringsSep "," cfg.groups;
    "@groupsGrepArgs@" = lib.concatStringsSep " " (map (g: "-e ${g}") cfg.groups);
    "@groupsCount@" = toString (builtins.length cfg.groups);
    "@aptSourceCount@" = toString (
      builtins.length (builtins.attrNames cfg.aptSources)
    );
  };

  # attrNames and attrValues return the same sorted order, so the two lists
  # replaceStrings receives are paired correctly.
  runbookText =
    builtins.replaceStrings (builtins.attrNames substitutions)
      (builtins.attrValues substitutions)
      (
        lib.foldl' (body: tok: requireToken tok body)
          (builtins.readFile ./../bootstrap/runbook.md.in)
          (builtins.attrNames substitutions)
      );

  runbook =
    pkgs.runCommand "calango-bootstrap-runbook"
      { src = pkgs.writeText "runbook-substituted.md" runbookText; }
      ''
        cp "$src" "$out"

        # The same token guard home/hyprland.nix and home/gtk.nix carry. Tokens
        # are lowercase-alpha; the runbook's reader-supplied placeholders are
        # <angle> and cannot match, which is why they are written that way.
        #
        # A CONDITION, not a bare command: a builder runs with errexit, and a
        # grep matching nothing exits 1 -- which here is the PASSING case.
        if grep -n '@[a-zA-Z]*@' "$out" >&2; then
          echo "" >&2
          echo "An unsubstituted token survived in the runbook." >&2
          echo "  Either add it to home/bootstrap.nix's substitutions" >&2
          echo "  attrset, or remove it from bootstrap/runbook.md.in." >&2
          exit 1
        fi
      '';
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
    aptSources = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "File name under /etc/apt/sources.list.d -> deb822 content.";
    };
    packages = {
      base = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Stage A apt package -> why the bootstrap needs it.";
      };
      corp = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Corp package -> where it comes from.";
      };
    };
  };

  options.calango.bootstrapDir = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The rendered root-owned tree. flake.nix exposes it.";
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

    # SCAFFOLDING, not state. Named calango-bootstrap-* so they are unambiguous
    # to delete once the vendor packages own their own copies -- the same trick
    # home/syncthing.nix used to sidestep a conffile handover.
    #
    # Four repositories, not five: 1password and 1password-cli share one. This
    # was miscounted twice during design before it was derived.
    aptSources = {
      "calango-bootstrap-google-chrome.sources" = stanza {
        uris = "https://dl.google.com/linux/chrome-stable/deb/";
        suites = "stable";
        key = "google-chrome";
      };
      "calango-bootstrap-microsoft.sources" = stanza {
        uris = "https://packages.microsoft.com/repos/code";
        suites = "stable";
        key = "microsoft";
      };
      "calango-bootstrap-1password.sources" = stanza {
        uris = "https://downloads.1password.com/linux/debian/amd64";
        suites = "stable";
        key = "1password";
      };
      # The only live source still in the one-line format
      # (endpoint-verification.list), and the only key under /etc/apt/keyrings
      # rather than /usr/share/keyrings. Both are normalised here.
      "calango-bootstrap-google-cloud.sources" = stanza {
        uris = "https://packages.cloud.google.com/apt";
        suites = "endpoint-verification";
        key = "google-cloud";
      };
    };

    # packages.base and calango.deb.keep answer DIFFERENT questions, which is
    # why this is its own option rather than a reuse of keep:
    #
    #   calango.deb.keep  what must not be removed, once here
    #   packages.base     what must be installed, to get here
    #
    # polkitd is the case that proves they differ. It owns
    # /usr/lib/polkit-1/polkit-agent-helper-1, which flake.nix's debianPolkit
    # overlay patches Nix's polkit to call, so the agent cannot authenticate
    # without it -- and it needs no keep entry, because network-manager,
    # udisks2, upower and systemd all hold it. On a bare install none of those
    # holders is present either. Same shape as runtimeDeps against appPath:
    # two lists, two questions, and merging them loses one.
    #
    # THIS LIST IS A HYPOTHESIS. It is reasoned from a machine holding 349
    # manual packages, where everything needed is present for reasons that
    # cannot be separated after the fact. The qemu rehearsal is what falsifies
    # it, and a missing package found there is an expected outcome of the
    # rehearsal rather than a defect in it.
    packages.base = {
      nix-bin = "The Nix client and the daemon binary. Nix comes from apt because nix-daemon is a root service and standalone Home Manager writes only user units.";
      nix-setup-systemd = "Installs and enables nix-daemon.service. Check the SERVICE, not the socket: the service is WantedBy=multi-user.target and binds the socket itself, so nix-daemon.socket reads inactive forever on a working install.";
      git = "To clone this flake. Priority optional, so absent from a bare install.";
      greetd = "The login manager, and it ships /etc/pam.d/greetd carrying four keyring lines that /etc/pam.d/login does not.";
      tuigreet = "The greeter that bootstrap/greetd-config.toml's command= line names.";
      dbus-user-session = "Owns /usr/lib/systemd/user/dbus.socket, the per-login session bus every portal, the tray host and the compositor need.";
      dbus-broker = "The bus implementation actually serving here, measured: systemctl --user show dbus.service reports dbus-broker.service as its fragment.";
      polkitd = "Owns /usr/lib/polkit-1/polkit-agent-helper-1, the setuid helper flake.nix's debianPolkit overlay patches Nix's polkit to call. Without it hyprpolkitagent runs, loads its QML, and dies on the first authentication.";
      network-manager = "home/services.nix runs nm-secret-agent against it.";
      ca-certificates = "The four third-party repositories are https. Priority standard, so probably already present; named because probably is not measured.";
    };

    # Seven packages, four repositories, two files. The bootstrap supplies the
    # repositories and stops: two of these are reachable from no repository at
    # all, and endpoint-verification is a managed-device agent whose enrolment
    # no script should attempt.
    packages.corp = {
      google-chrome-stable = "https://dl.google.com/linux/chrome-stable/deb/ -- calango-bootstrap-google-chrome.sources";
      code = "https://packages.microsoft.com/repos/code -- calango-bootstrap-microsoft.sources";
      "1password" = "https://downloads.1password.com/linux/debian/amd64 -- calango-bootstrap-1password.sources";
      "1password-cli" = "The same repository as 1password. These two share one, which is why there are four repositories and not five.";
      endpoint-verification = "https://packages.cloud.google.com/apt -- calango-bootstrap-google-cloud.sources. Corporate enrolment is a separate, human step.";
      slack-desktop = "NO repository. apt-cache policy shows one version-table entry, /var/lib/dpkg/status. Fetch the .deb; bin/slack-latest prints the current version and the commands.";
      fresh-editor = "NO repository, same as slack-desktop. Upstream is https://sinelaw.github.io/fresh/. Debian's 0.4.7 outranks nixpkgs' 0.3.6, which is why this one stays on apt.";
    };
  };

  # The guard rides as an INPUT of the exposed directory, not merely as a
  # sibling in home.packages. `nix build .#calangoBootstrap` never evaluates
  # home.packages -- spec 16 shipped exactly that mistake with the .deb's own
  # store-path guard, which protected the activation path and left the
  # installable artifact unguarded.
  config.calango.bootstrapDir = pkgs.runCommand "calango-bootstrap"
    { inherit bootstrapTree noStorePathsInEtc; } ''
      cp -r "$bootstrapTree" "$out"
      chmod -R u+w "$out"
    '';

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

  # Rides in home.packages as well, so the guard runs on every generation
  # build and not only under `nix build .#calangoBootstrap`.
  config.home.packages = [ config.calango.bootstrapDir ];
}
