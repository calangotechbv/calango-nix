{ lib, pkgs, ... }:

let
  # GUI applications migrated off apt. One list, because the guard below
  # asserts a property over all of them at once and a second list would be a
  # second thing to keep in step.
  guiPackages = [ pkgs.seahorse ];

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
}
