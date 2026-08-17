{ lib, pkgs, ... }:

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
  # Both bin/gammastep and bin/gammastep-indicator are wrapGAppsHook
  # wrappers (.gammastep-wrapped and .gammastep-indicator-wrapped siblings
  # exist, and both wrapper scripts do prefix XDG_DATA_DIRS with gtk+3's and
  # gsettings-desktop-schemas' own schema directories). But that is a
  # property of gammastep's *dependencies*, not of gammastep itself: the
  # package ships no share/gsettings-schemas directory of its own --
  # `find <gammastep> -path '*gsettings-schemas*' | wc -l` is 0 -- so the
  # guard below takes its "no schemas -> nothing to wrap" exempt path for
  # this entry, the same as it would for any package with zero schemas of
  # its own, wrapped binaries or not.
  #
  # Neither gammastep.desktop nor gammastep-indicator.desktop declares
  # DBusActivatable (checked directly: `grep DBusActivatable` on both files
  # in the store path matches nothing), and gammastep ships no
  # share/dbus-1/services directory at all -- confirmed again here, see the
  # xdg.dataFile comment below for why that matters. So unlike seahorse,
  # gammastep needs no D-Bus activation file.
  guiPackages = [ pkgs.seahorse pkgs.gammastep ];

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
  # Packages with no GSettings schema at all are exempt, and the exemption is
  # derived rather than listed: if the package ships no gsettings-schemas
  # directory, there is nothing to find and nothing to wrap.
  wrappedGuiApps = pkgs.runCommand "gui-apps-schema-wrapped" { } ''
    fail=0
    for pkg in ${lib.concatStringsSep " " (map toString guiPackages)}; do
      name="$(basename "$pkg")"

      if [ ! -d "$pkg/share/gsettings-schemas" ]; then
        echo "ok (no schemas): $name" >&2
        continue
      fi

      wrapped="$(find "$pkg/bin" -maxdepth 1 -name '.*-wrapped' 2>/dev/null | wc -l)"
      if [ "$wrapped" -eq 0 ]; then
        echo "$name ships GSettings schemas but no wrapped binary." >&2
        echo "  Its schemas are at share/gsettings-schemas/, which GLib does" >&2
        echo "  not search, and nothing here adds that to XDG_DATA_DIRS. The" >&2
        echo "  application would abort at startup with" >&2
        echo "  \"Settings schema ... is not installed\"." >&2
        echo "  Expected a .<name>-wrapped sibling in bin/ from wrapGAppsHook." >&2
        fail=1
      else
        echo "ok ($wrapped wrapped): $name" >&2
      fi
    done
    [ "$fail" -eq 0 ] || exit 1
    # A directory, not `touch "$out"`. gui-apps-guard below symlinks to this
    # output, and that symlink is what home.packages carries into
    # pkgs.buildEnv -- which requires every package it merges to resolve to
    # a directory. A file output here made buildEnv fail with "is a file
    # and can't be merged into an environment", on the first build attempted.
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
  # The guard is referenced from home.packages so nothing can install these
  # applications without having passed it.
  home.packages = guiPackages ++ [
    (pkgs.runCommand "gui-apps-guard" { } "ln -s ${wrappedGuiApps} $out")
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
  # Same root cause as home/portals.nix's three xdg.dataFile entries: the
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
  # Not derived from guiPackages by scanning each package's
  # share/dbus-1/services directory, unlike the schema guard above -- but
  # not because that scan would need an import-from-derivation. It
  # wouldn't: a build-time guard, shaped exactly like wrappedGuiApps two
  # bindings up, can `find`/`ls` each package's share/dbus-1/services at
  # build time, because by the time such a guard runs every package in
  # guiPackages is already built -- home.packages forces that. IFD is a
  # problem only for *auto-generating* the xdg.dataFile entries
  # themselves, since Home Manager's option model needs the attribute
  # names (the .service filenames) at Nix eval time, before the packages
  # are necessarily built.
  #
  # So the honest state is: this is a single hand-written entry with no
  # guard behind it, and the only thing stopping a future package from
  # shipping a DBusActivatable=true .desktop with no matching xdg.dataFile
  # entry is a human noticing. That gap has an owner and a place: Task 4
  # of this plan builds the .desktop identity checks, and is to add a
  # build-time guard there -- checked for the class (every guiPackages
  # member with a share/dbus-1/services/*.service file must have a
  # matching xdg.dataFile entry), not re-derived per package the way this
  # comment was. gammastep, which Task 3 adds to guiPackages, ships no
  # share/dbus-1/services directory at all (`ls
  # <gammastep>/share/dbus-1/services/` exits 2, no such directory) -- so
  # today's single entry happens to be complete, which is exactly the
  # kind of thing a guard should confirm rather than a comment asserting it.
  #
  # dbus-broker caches its service directory at its own startup and never
  # rescans on a home-manager switch (see CLAUDE.md) -- the file landing
  # here is necessary but not sufficient. A fresh login or
  # `busctl --user ReloadConfig` is required before activation works.
  xdg.dataFile."dbus-1/services/org.gnome.seahorse.Application.service".source =
    "${pkgs.seahorse}/share/dbus-1/services/org.gnome.seahorse.Application.service";
}
