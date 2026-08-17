{ config, lib, pkgs, ... }:

let
  # GUI applications migrated off apt. One list, because the guard below
  # asserts a property over all of them at once and a second list would be a
  # second thing to keep in step.
  #
  # gammastep closes a two-provenance split rather than starting a
  # migration. pkgs.gammastep was already reaching the night-light unit
  # through home/services.nix's nightLightPath -- the unit's own
  # Environment=PATH -- but never through home.packages, so the unit ran
  # 2.0.11 while a shell and both .desktop entries got Debian's 2.0.9.
  # Nix's package has full parity: gammastep, gammastep-indicator, and both
  # .desktop files.
  #
  # Both bin/gammastep and bin/gammastep-indicator are wrapGAppsHook wrappers
  # (.gammastep-wrapped and .gammastep-indicator-wrapped siblings exist), and
  # this entry is why the guard below has no "ships no schemas" exemption.
  #
  # An earlier version of this comment argued that the wrappers matter because
  # the schema directories they prefix come from gammastep's dependencies. That
  # is measured and false. Each wrapper does prefix XDG_DATA_DIRS with gtk+3's
  # and gsettings-desktop-schemas' directories, and gammastep ships none of its
  # own:
  #
  #   $ G=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
  #   $ find $G -path '*gsettings-schemas*' | wc -l
  #   0
  #
  # But the indicator does not read a schema, from any source. Its module has
  # zero Gio, Settings or GSettings references, and adding the wrapper's
  # variables back to the bare stub one at a time -- adding rather than
  # stripping, because a shell that has none of them set returns the same
  # failure whatever you strip -- isolates the one that matters:
  #
  #   nothing set                 exit=1    traceback at gi.require_version('Gtk','3.0')
  #   GI_TYPELIB_PATH only        exit=255  runs; gammastep's own --help behaviour
  #   XDG_DATA_DIRS only          exit=1    unchanged
  #   GDK_PIXBUF_MODULE_FILE only exit=1    unchanged
  #
  # So the wrapper IS load-bearing and GI_TYPELIB_PATH is what carries it:
  # gammastep-indicator is a PyGObject application and gi.require_version fails
  # without the typelib path. That makes the case against a derived exemption
  # stronger than the old comment made it, not weaker -- whether a package
  # needs its wrapper turns out not to be a function of schemas at all. The
  # guard below therefore requires a wrapped binary from every member,
  # gammastep included, and gammastep supplies two.
  #
  # Neither gammastep.desktop nor gammastep-indicator.desktop declares
  # DBusActivatable (checked directly: `grep DBusActivatable` on both files
  # in the store path matches nothing), and gammastep ships no
  # share/dbus-1/services directory at all -- confirmed again here, see the
  # xdg.dataFile comment below for why that matters. So unlike seahorse,
  # gammastep needs no D-Bus activation file.
  #
  # signal-desktop and bitwarden-desktop are plain migrations off apt, and the
  # first members here that are not GTK applications at all. Both are Electron:
  # one binary each (bin/signal-desktop, bin/bitwarden), zero wrapped binaries,
  # zero share/gsettings-schemas directories and no share/dbus-1/services. The
  # nixpkgs attribute for the second is bitwarden-desktop -- plain
  # `pkgs.bitwarden` throws `'bitwarden' has been renamed to/replaced by
  # 'bitwarden-desktop'`. Their .desktop ids are signal.desktop and
  # bitwarden.desktop, NOT Debian's signal-desktop.desktop; flake.nix's
  # gui-desktop-ids requires both by those names.
  #
  # Neither needs a nixGL wrapper OF ITS OWN, which is a narrower claim than
  # the one this comment used to make. The user ran both binaries bare from a
  # terminal in the live Hyprland session and both windows drew -- but a
  # session child inherits the five GL variables from the compositor's own
  # wrap, so that run says nothing about the variables themselves. Stripped of
  # them, Signal reports
  #   MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
  # and its GPU process exits. The measurement was still worth taking, because
  # `ldd` cannot answer the question at all -- Electron dlopens its GL and
  # platform plugins.
  #
  # Having no wrapper is what makes them the first entries in wrapExemptions
  # below.
  guiPackages = [
    pkgs.seahorse
    pkgs.gammastep
    pkgs.signal-desktop
    pkgs.bitwarden-desktop
  ];

  # The packages that legitimately need no GSettings wrapper, each with the
  # reason it needs none. Consumed by wrappedGuiApps below, in both directions.
  #
  # Explicit, and deliberately NOT derived. The derived rule -- "ships no
  # schemas of its own, therefore nothing to wrap" -- is what this guard
  # shipped with in spec 10, and the gammastep comment above disproves it in
  # this same file: gammastep-indicator needs its wrapper and reads no schema
  # from any source, so wrapper necessity is not a function of schemas at all.
  # Deriving a second rule would be the same mistake wearing a different
  # predicate, so the key is a name a human had to type and the value is a
  # sentence a human had to justify.
  #
  # Keyed by lib.getName, which is the pname, so an entry survives a version
  # bump without being re-approved -- and only a version bump. A rename is a
  # new package as far as this table is concerned, which is the right default.
  wrapExemptions = {
    signal-desktop = "Electron, not GTK. Ships one binary, zero wrapped binaries and zero GSettings schemas; there is no schema for a wrapper to reach.";
    bitwarden-desktop = "Electron, not GTK. Same shape as signal-desktop: one binary, no wrapper, no schemas.";
  };

  # Assert that every GUI package here is wrapped for GSettings schemas.
  #
  # nixpkgs relocates schemas to share/gsettings-schemas/<name>/glib-2.0/schemas,
  # a path GLib never searches -- on NixOS the module system adds those
  # directories to XDG_DATA_DIRS, and standalone Home Manager on Debian does
  # nothing of the kind. A GTK application whose schema is missing does not
  # degrade; it aborts with `Settings schema '...' is not installed`, which
  # reads as a broken package.
  #
  # In practice nixpkgs solves this per package: wrapGAppsHook produces a
  # wrapper that prefixes XDG_DATA_DIRS with every schema directory the
  # application needs. seahorse's bin/seahorse is a makeBinaryWrapper around
  # bin/.seahorse-wrapped carrying four of them, its own included. So this
  # guard does not build a mechanism -- it checks that the mechanism upstream
  # already applied is present, so a package that forgot the hook is a build
  # error rather than a window that never opens.
  #
  # Detected by the .<name>-wrapped sibling, which both makeWrapper and
  # makeBinaryWrapper produce, rather than by grepping the binary -- one is a
  # shell script and the other an ELF, and a check that only understands one
  # would pass vacuously on the other.
  #
  # There IS an exemption, and its shape is the whole point. There was once a
  # derived one -- `[ ! -d "$pkg/share/gsettings-schemas" ]`, justified as
  # "nothing to find and nothing to wrap" -- and the gammastep comment above
  # disproves that justification in this same file: gammastep-indicator needs
  # its wrapper for GI_TYPELIB_PATH and reads no schema at all, so the
  # predicate measures the wrong property entirely. A GTK application that had
  # merely missed wrapGAppsHook would have taken that exempt path and aborted
  # at startup anyway, which is
  # precisely the failure this guard exists to make into a build error. So it
  # was deleted, with the prediction that a legitimately unwrapped application
  # would eventually need a deliberate one.
  #
  # signal-desktop and bitwarden-desktop are that case, and the exemption they
  # get is keyed by NAME, from the wrapExemptions table above. The reason it is
  # by name rather than derived is not that no correct predicate exists -- it
  # is that a predicate exempts every future package that happens to satisfy
  # it, including the one that satisfies it by accident, and nobody is asked a
  # question at that moment. A name in a table has to be typed by someone who
  # then has to write the sentence next to it.
  #
  # And it is checked in BOTH directions, which is what separates this from an
  # allowlist. An allowlist only grows, and an entry that has stopped being
  # true goes on excusing a package that has started needing the check --
  # silently, because nothing ever re-reads it. So an exempt package that
  # acquires a wrapped binary upstream fails this build and demands its entry
  # be deleted.
  #
  # All three failure branches were proven by mutation rather than by reading,
  # each with the mutation confirmed by a count before the build ran. Deleting
  # signal-desktop's entry gives `signal-desktop has no wrapped binary in
  # bin/.`; adding seahorse, which IS wrapped, gives `seahorse is on
  # wrapExemptions but ships 1 wrapped binary(ies).`; exempting all four
  # reaches the anti-vacuity anchor with `every guiPackages member is on
  # wrapExemptions.`. Three checks in this project have passed while the
  # property they stood for was false, which is why none of them is trusted
  # unmutated.
  #
  # Today's verdict, from this derivation's own build log:
  # `ok (1 wrapped): seahorse`, `ok (2 wrapped): gammastep`,
  # `ok (exempt): signal-desktop`, `ok (exempt): bitwarden-desktop`.
  #
  # The name in those lines is lib.getName's, passed in from Nix, not the store
  # path's basename: the basename carries the hash and the version, so it could
  # never be compared against a table key that is meant to survive a rebuild.
  wrappedGuiApps = pkgs.runCommand "gui-apps-schema-wrapped" { } ''
    fail=0
    exempt="${lib.concatStringsSep " " (lib.attrNames wrapExemptions)}"

    check() {
      name="$1"
      pkg="$2"

      wrapped="$(find "$pkg/bin" -maxdepth 1 -name '.*-wrapped' 2>/dev/null | wc -l)"

      # Written as an `if`, not `[ ... ] && is_exempt=1`. A builder runs with
      # errexit on, and CLAUDE.md's rule for that is to put the test in a
      # condition, which set -e exempts, rather than let its exit status be
      # the statement's own.
      is_exempt=0
      for e in $exempt; do
        if [ "$e" = "$name" ]; then is_exempt=1; fi
      done

      if [ "$is_exempt" -eq 1 ]; then
        # The staleness half, which an ordinary allowlist does not have. An
        # exemption that has stopped being true is worse than no exemption:
        # it goes on excusing a package that has started needing the check.
        # Upstream adding wrapGAppsHook must break this build, not pass.
        if [ "$wrapped" -gt 0 ]; then
          echo "$name is on wrapExemptions but ships $wrapped wrapped binary(ies)." >&2
          echo "  The exemption has gone stale. It was written because this" >&2
          echo "  package had nothing to wrap; upstream now wraps it, so it" >&2
          echo "  should be checked like every other member. Delete its entry" >&2
          echo "  from wrapExemptions in home/gui-apps.nix." >&2
          fail=1
          return 0
        fi
        echo "ok (exempt): $name" >&2
        return 0
      fi

      if [ "$wrapped" -eq 0 ]; then
        echo "$name has no wrapped binary in bin/." >&2
        echo "  nixpkgs relocates GSettings schemas to" >&2
        echo "  share/gsettings-schemas/, which GLib does not search, and" >&2
        echo "  nothing here adds that to XDG_DATA_DIRS. A GTK application" >&2
        echo "  needing a schema -- its OWN or a dependency's -- would abort" >&2
        echo "  at startup with \"Settings schema ... is not installed\"." >&2
        echo "  Expected a .<name>-wrapped sibling in bin/ from wrapGAppsHook." >&2
        echo "  If this package is genuinely not a GTK application, add it to" >&2
        echo "  wrapExemptions in home/gui-apps.nix BY NAME, WITH ITS REASON" >&2
        echo "  -- NOT by whether it ships schemas of its own, which" >&2
        echo "  gammastep shows is the wrong question." >&2
        fail=1
        return 0
      fi

      echo "ok ($wrapped wrapped): $name" >&2
    }

    ${lib.concatMapStringsSep "\n    "
        (p: ''check "${lib.getName p}" "${p}"'') guiPackages}

    # Anti-vacuity anchor, the same one gui-desktop-ids and
    # no-pulseaudio-daemon carry. Every member could be exempt, and then this
    # guard would have asserted nothing while still printing four ok lines.
    nonexempt=0
    for e in ${lib.concatStringsSep " " (map lib.getName guiPackages)}; do
      hit=0
      for x in $exempt; do
        if [ "$x" = "$e" ]; then hit=1; fi
      done
      if [ "$hit" -eq 0 ]; then nonexempt=$((nonexempt+1)); fi
    done
    if [ "$nonexempt" -eq 0 ]; then
      echo "every guiPackages member is on wrapExemptions." >&2
      echo "  Nothing was required to have a wrapper, so this guard's pass" >&2
      echo "  is vacuous. Either the table has grown past its purpose or the" >&2
      echo "  last GTK application left guiPackages; decide which, on" >&2
      echo "  purpose." >&2
      exit 1
    fi

    [ "$fail" -eq 0 ] || exit 1
    # A directory, not `touch "$out"`. gui-apps-guard below symlinks to this
    # output, and that symlink is what home.packages carries into
    # pkgs.buildEnv -- which requires every package it merges to resolve to
    # a directory. A file output here made buildEnv fail with "is a file
    # and can't be merged into an environment", on the first build attempted.
    mkdir -p "$out"
  '';

  # The .service basenames this configuration declares as xdg.dataFile entries,
  # read off the option's own attribute names rather than kept in a second
  # list. The names are relative paths -- "dbus-1/services/<name>.service" --
  # so the prefix comes off before comparison.
  #
  # This is the WHOLE configuration's declared set, home/portals.nix's five
  # entries included, not just this module's one. That is deliberate and it is
  # the property the guard below actually cares about: what matters is that the
  # file lands in XDG_DATA_HOME, which is the only place the session bus will
  # look (see the long comment on the seahorse entry further down), and any
  # module putting it there satisfies that. A wider declared set can only ever
  # make the guard more permissive, never produce a false failure.
  #
  # Reading config here to build something that feeds home.packages is not a
  # cycle -- every xdg.dataFile definition in this flake is a literal and none
  # of them reads home.packages -- but this plan has already shipped one
  # `infinite recursion` from a self-referencing binding, so this shape was
  # built and evaluated rather than reasoned about.
  declaredDbusServices =
    let
      prefix = "dbus-1/services/";
    in
    map (lib.removePrefix prefix)
      (lib.filter (lib.hasPrefix prefix) (lib.attrNames config.xdg.dataFile));

  # Assert that every GUI package shipping a D-Bus activation file has a
  # matching xdg.dataFile entry.
  #
  # This is the class-level guard behind the single hand-written entry at the
  # bottom of this file. Task 2 shipped that entry after seahorse could not be
  # launched at all: its .desktop carries DBusActivatable=true, so a launcher
  # never runs Exec= and asks the session bus to activate the name instead --
  # and the bus's own XDG_DATA_DIRS carries no ~/.nix-profile/share, so the
  # activation file sitting in the package was invisible to it. Until this
  # guard, the only thing stopping the next package from repeating that was a
  # human noticing.
  #
  # Iterating guiPackages members individually, NOT reading
  # ~/.nix-profile/share/dbus-1/services or the generation's merged
  # home-path. That directory is a merged view: measured here it holds five
  # portal service files owned by home/portals.nix
  # (org.freedesktop.portal.Desktop, .Documents,
  # org.freedesktop.impl.portal.PermissionStore, and the .desktop.gtk and
  # .desktop.hyprland backends) alongside seahorse's one. A guard reading the
  # merge would demand xdg.dataFile entries on behalf of packages this module
  # does not own, and would report a portals regression as a gui-apps failure.
  #
  # No import-from-derivation: by the time this runs, every package in
  # guiPackages is built, because home.packages forces that. IFD would only be
  # a problem for auto-generating the xdg.dataFile entries themselves, whose
  # attribute names Home Manager's option model needs at eval time.
  dbusActivatableGuiApps = pkgs.runCommand "gui-apps-dbus-activation" { } ''
    declared="${lib.concatStringsSep " " declaredDbusServices}"
    fail=0
    examined=0

    for pkg in ${lib.concatStringsSep " " (map toString guiPackages)}; do
      name="$(basename "$pkg")"
      dir="$pkg/share/dbus-1/services"

      if [ ! -d "$dir" ]; then
        echo "ok (no activation files): $name" >&2
        continue
      fi

      here=0
      for svc in "$dir"/*.service; do
        [ -e "$svc" ] || continue
        here=$((here+1))
        examined=$((examined+1))
        base="$(basename "$svc")"

        ok=0
        for d in $declared; do
          [ "$d" = "$base" ] && { ok=1; break; }
        done

        if [ "$ok" -eq 0 ]; then
          echo "$name ships $base but no xdg.dataFile declares it." >&2
          echo "  A .desktop with DBusActivatable=true is never launched" >&2
          echo "  through Exec= or PATH -- the launcher asks the session bus" >&2
          echo "  to activate the name, and the bus resolves that through a" >&2
          echo "  .service file on its OWN search path. That path has no" >&2
          echo "  ~/.nix-profile/share in it, so the copy in the package is" >&2
          echo "  invisible and the launch fails with" >&2
          echo "  \"The name is not activatable\" -- the application cannot" >&2
          echo "  be started at all, which is how this was found the first" >&2
          echo "  time. Add:" >&2
          echo "    xdg.dataFile.\"dbus-1/services/$base\".source =" >&2
          echo "      \"\''${pkg}/share/dbus-1/services/$base\";" >&2
          fail=1
        else
          echo "ok (declared): $name -> $base" >&2
        fi
      done

      if [ "$here" -eq 0 ]; then
        echo "$dir exists but holds no *.service file." >&2
        echo "  The glob found nothing where the directory itself is there," >&2
        echo "  which means the naming or layout changed upstream -- not" >&2
        echo "  that this package has nothing to declare. Fix the glob" >&2
        echo "  before trusting a pass." >&2
        fail=1
      fi
    done

    if [ "$examined" -eq 0 ]; then
      echo "No guiPackages member ships a share/dbus-1/services/*.service." >&2
      echo "  Every entry took the 'no activation files' exempt path, so" >&2
      echo "  this guard compared nothing against nothing and its pass" >&2
      echo "  would be vacuous. Today seahorse ships exactly one such file," >&2
      echo "  so reaching this means either that stopped being true or the" >&2
      echo "  share/dbus-1/services path moved. Same reason flake.nix's" >&2
      echo "  no-pulseaudio-daemon asserts pactl is present before" >&2
      echo "  concluding pulseaudio is absent: a negative result is only" >&2
      echo "  evidence if the check was looking somewhere." >&2
      echo "  If a future configuration legitimately has no" >&2
      echo "  DBusActivatable application, delete this block on purpose and" >&2
      echo "  say so here." >&2
      exit 1
    fi

    [ "$fail" -eq 0 ] || exit 1
    # A directory, for the same reason the guard above ends in mkdir: this
    # output is reached from home.packages through gui-apps-dbus-guard's
    # symlink, and pkgs.buildEnv refuses to merge a store path that is a file.
    mkdir -p "$out"
  '';
in
{
  # seahorse moves to Nix while gnome-keyring and gcr4 stay on apt, and that
  # is deliberate rather than a half-migration. The coupling is D-Bus, not
  # shared libraries: seahorse is a libsecret client of
  # org.freedesktop.secrets, a stable cross-version API, and Nix's seahorse
  # links Nix's own gcr inside its own process. Nothing requires a client and
  # a daemon to come from the same packaging system.
  #
  # gnome-keyring cannot move -- pam_gnome_keyring.so is in /etc/pam.d/greetd
  # and pointing PAM at a store path risks a machine that cannot log in. See
  # CLAUDE.md. seahorse is 47.0.1 on both sides, so this is a pure lateral
  # move and nothing here can be blamed on a version change.
  #
  # Both guards are referenced from home.packages so nothing can install these
  # applications without having passed them. Each is wrapped in its own
  # `ln -s <guard> $out` derivation rather than named directly: $out is then a
  # symlink to an empty directory, which buildEnv merges as nothing at all. A
  # derivation whose own $out held named files would put those names in the
  # profile root.
  home.packages = guiPackages ++ [
    (pkgs.runCommand "gui-apps-guard" { } "ln -s ${wrappedGuiApps} $out")
    (pkgs.runCommand "gui-apps-dbus-guard" { } "ln -s ${dbusActivatableGuiApps} $out")
  ];

  # seahorse's .desktop carries DBusActivatable=true, so a launcher never
  # execs its Exec=seahorse line at all -- it asks the session bus to
  # activate org.gnome.seahorse.Application, and the bus resolves that
  # through a .service file, not through XDG_DATA_DIRS the way a plain
  # Exec= launch would. Measured at the gate, post-switch and post-`apt
  # remove seahorse`:
  #
  #   $ busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
  #       org.freedesktop.DBus StartServiceByName su org.gnome.seahorse.Application 0
  #   Call failed: The name is not activatable
  #
  # Same root cause as home/portals.nix's five xdg.dataFile entries: the
  # session bus's own XDG_DATA_DIRS, read from
  # `/proc/<dbus MainPID>/environ`, is
  # ~/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share/:/usr/share/
  # -- no ~/.nix-profile/share anywhere in it. So seahorse's own copy at
  # share/dbus-1/services/org.gnome.seahorse.Application.service, sitting
  # right there in home.packages, is invisible to the bus. Missed here
  # because Task 1's probe ran the binary directly, which never goes
  # through D-Bus activation and so never exercises this path; it only
  # surfaced once a launcher -- not a shell -- was the thing doing the
  # launching. ~/.local/share/dbus-1/services is XDG_DATA_HOME, which the
  # bus does search, so that is where the copy has to land.
  #
  # Still a hand-written entry, and it has to be: auto-generating it would
  # need an import-from-derivation, because Home Manager's option model
  # wants the attribute name -- the .service filename -- at Nix eval time,
  # before the package is necessarily built.
  #
  # What it no longer is, is unguarded. dbusActivatableGuiApps in the let
  # block above checks the class this entry is one instance of: every
  # guiPackages member that ships a share/dbus-1/services/*.service file
  # must have a matching xdg.dataFile entry somewhere in this
  # configuration. That guard needs no IFD -- it reads each package's
  # directory at *build* time, and what forces those packages to exist by
  # then is the guard's OWN inputDrvs, not home.packages: interpolating each
  # store path into its build script makes every one of them a build-time
  # dependency of the guard itself. Verified on the derivation --
  # `nix derivation show <gui-apps-dbus-activation.drv>` lists
  # seahorse-47.0.1.drv and gammastep-2.0.11.drv among its inputDrvs -- so
  # the guard would still be correct if these packages left home.packages
  # entirely. Its verdict today, from its own
  # build log, one line per package (the name is the store path's basename,
  # hash included): `ok (declared): 7kw783z...-seahorse-47.0.1 ->
  # org.gnome.seahorse.Application.service` and `ok (no activation files):
  # bcrxrws...-gammastep-2.0.11`. So the entry below is complete, confirmed by a
  # guard rather than asserted by a comment -- and it was proven able to
  # fail, by renaming this attribute and watching the build stop.
  #
  # dbus-broker caches its service directory at its own startup and never
  # rescans on a home-manager switch (see CLAUDE.md) -- the file landing
  # here is necessary but not sufficient. A fresh login or
  # `busctl --user ReloadConfig` is required before activation works.
  xdg.dataFile."dbus-1/services/org.gnome.seahorse.Application.service".source =
    "${pkgs.seahorse}/share/dbus-1/services/org.gnome.seahorse.Application.service";
}
