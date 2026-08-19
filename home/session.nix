{ config, lib, pkgs, ... }:

let
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };

  # Everything hyprland.lua invokes by bare name through hl.exec_cmd /
  # hl.dsp.exec_cmd -- 36 call sites, assembled from plain "..." literals,
  # [[...]] long brackets, `..` concatenation and function parameters (the
  # terminal/fileManager/menu locals). Derived by reading every call site,
  # not by grepping one syntactic form of one of them: a static extractor
  # over just quoted-string call arguments misses `slurp`, which appears
  # only inside a [[...]] long bracket passed as an argument into the local
  # shot() helper, and misses `lf`, a bare second word inside the
  # fileManager string "foot --app-id lf lf" with no shell-operator syntax
  # in front of it to key on. hl.exec_cmd calls have no explicit PATH
  # (unlike hypridle.service, which has none either -- see idleSleepPath in
  # home/hyprland.nix), so a missing entry here is a keybind or startup exec
  # that does nothing and logs nothing.
  #
  # xwayland is the one entry that is NOT there for the reason above. Nothing
  # in hyprland.lua invokes `Xwayland` by name -- the compositor spawns it from
  # its own code, on demand, when the first X11 client connects, and it finds
  # it on the PATH it was started with, which is this one. So the list is
  # "everything hyprland.lua invokes by bare name, plus Xwayland, which the
  # compositor itself resolves the same way".
  #
  # And xwayland is in this list to FIX something, not merely to replace apt's.
  # Debian's Xwayland is a child of this nixGL-wrapped compositor, so it
  # inherits LIBGL_DRIVERS_PATH and GBM_BACKENDS_PATH pointing into Nix's mesa
  # while linking Debian's libgbm. Glamor needs a matching GBM/DRI pair, gets a
  # mismatched one, and silently falls back to software rendering. Measured with
  # identical clients, only the server differing:
  #     Nix's Xwayland      Accelerated: yes  AMD Radeon 780M (radeonsi)
  #     Debian's Xwayland   Accelerated: no   llvmpipe
  # Every X11 client has been on the CPU since spec 1. Nix's needs no nixGL
  # wrapper of its own -- it inherits the compositor's environment, which is
  # exactly what makes it work.
  compositorPath = lib.makeBinPath (with pkgs; [
    bash          # sh -- wl-paste --type text --watch's handler is `sh -c '...'`
    cliphist      # cliphist store, the two clipboard watchers started on hyprland.start
    coreutils     # mkdir, tee, date -- the screenshot pipeline in shot()
    foot          # $terminal, and fileManager = "foot --app-id lf lf"
    gnugrep       # grep -qi, the cliphist text watcher's password-manager-hint guard
    grim          # screenshot capture, all three Print binds via shot()
    hyprland      # bare hyprctl in exec_cmd strings (notify, the two Print binds)
    jq            # -r queries against `hyprctl -j` in the two Print binds
    config.calango.lf # fileManager's file manager, passed to foot as an argument
    playerctl     # the four XF86Audio{Next,Pause,Play,Prev} binds
    procps        # pgrep -f, guarding both clipboard watchers against duplicates
    quickshell    # qs ipc call ... -- menu, switchWindow, and every panel toggle bind
    slurp         # the region picker inside Print's shot() guard
    uwsm          # uwsm finalize, on hyprland.start
    wireplumber   # wpctl, every volume/mute bind
    wl-clipboard  # wl-copy (shot()) and wl-paste (both clipboard watchers)
    xwayland      # Xwayland, spawned by the compositor for every X11 client
  ]);

  # Wrap the compositor itself rather than the caller. A wrapper on the
  # binary survives being launched by uwsm through a systemd unit, which a
  # wrapper on the session entry may not -- a unit does not inherit the
  # environment of whoever invoked uwsm unless uwsm exports it. That is why
  # the wrapper below execs the binary directly rather than wrapping
  # whatever calls into uwsm.
  #
  # The binary wrapped is start-hyprland, not bare Hyprland: commit c366f90
  # restored it as the compositor's parent, for the reason given in the
  # start-hyprland comment further down.
  #
  # hyprland.lua's own comment at line 194 notes that its hl.env calls do not
  # cover PATH. Everything the compositor spawns -- every bind, every startup
  # exec -- inherits this, and a missing entry is a keybind that does nothing
  # and logs nothing. compositorPath above is derived from the config, not
  # transcribed from a design document.
  #
  # Prepended, not appended. The original reason was that apt's Hyprland,
  # hyprctl and hyprlock sat in /usr/bin and an appended path would let them
  # win. That premise expired with spec 5: none of those three exists any
  # more, and /usr/share/wayland-sessions is not even a directory. Prepending
  # stays because the guarantee is what matters -- this list is derived from
  # the config and is meant to be the answer, not a suggestion ranked below
  # whatever a future apt package happens to install.
  #
  # No QS_CONFIG_PATH here any more, and its absence is deliberate.
  #
  # This wrapper used to export it, pointing at quickshell's store path, so
  # that the 15 `qs ipc call ...` binds in hyprland.lua could reach the
  # instance quickshell.service was started with under `-p <store path>`.
  # That worked until the store path changed. The wrapper runs once, at
  # session start, so the compositor holds whatever hash was current then;
  # the service picks up the new one at the next `home-manager switch`. From
  # that moment the binds ask for a path with nothing running and fail
  # silently -- session menu, layout switcher, brightness keys, every panel
  # toggle -- until the user logs out. One edit to a QML file was enough.
  #
  # quickshell.service now runs with no -p and reads
  # ~/.config/quickshell/shell.qml, which home/quickshell.nix points at the
  # store. A bare `qs` resolves the same symlink, so both ends agree by
  # construction and a switch retargets them together. Nothing needs an
  # environment variable, so nothing can hold a stale one.
  #
  # start-hyprland is a watchdog around the compositor binary, not an
  # alternative session manager to uwsm -- apt's own chain ran both
  # together (uwsm -> hyprland.desktop -> start-hyprland -> Hyprland), and
  # execing Hyprland directly, as this wrapper used to, dropped that inner
  # launcher and left the compositor logging
  # "WARNING: Hyprland is being launched without start-hyprland" on every
  # start. Restoring it makes start-hyprland the parent again.
  #
  # start-hyprland has its own nixGL handling (--no-nixgl / --force-nixgl),
  # but nixGLIntel wrapping it from the outside is kept instead: that path
  # is the one verified across three specs on this machine, and this is the
  # user's only session -- not where to re-open a question an earlier spec
  # already closed. --force-nixgl, letting start-hyprland do it and
  # dropping the flake's nixgl input entirely, is the tidier end state but
  # is unproven here and deliberately not taken now.
  hyprland-nixgl = pkgs.writeShellScriptBin "hyprland-nixgl" ''
    export PATH=${compositorPath}''${PATH:+:$PATH}
    exec ${nixgl.bin} \
      ${pkgs.hyprland}/bin/start-hyprland --no-nixgl -- \
      --config ${config.calango.hyprConfig}/hyprland.lua "$@"
  '';

  # uwsm resolves a compositor by desktop entry, and hyprland's own
  # hyprland.desktop runs bin/start-hyprland -- unwrapped. On a foreign
  # distribution that entry cannot work: Task 6 rung 1 showed the unwrapped
  # binary dying with
  #     MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
  #     CBackend::create() failed!
  # because Nix's Mesa looks in /run/opengl-driver/lib, a path that exists on
  # NixOS and nowhere else. So the session needs an entry of its own whose
  # Exec is the wrapper. It is added beside hyprland.desktop rather than
  # replacing it, so the unwrapped entry stays available for comparison.
  hyprland-nixgl-session = pkgs.runCommand "hyprland-nixgl-session" { } ''
    mkdir -p "$out/share/wayland-sessions"
    cat > "$out/share/wayland-sessions/hyprland-nixgl.desktop" <<EOF
    [Desktop Entry]
    Name=Hyprland (Nix)
    Comment=calango-nix, wrapped in nixGLIntel
    Exec=${hyprland-nixgl}/bin/hyprland-nixgl
    TryExec=${hyprland-nixgl}/bin/hyprland-nixgl
    DesktopNames=Hyprland
    Type=Application
    EOF
  '';
in
{
  home.packages = [ hyprland-nixgl hyprland-nixgl-session ];

  # The greetd session entry, which has been root-owned, hand-created and
  # covered by no mechanism since the flake began -- `dpkg -S` finds no owner.
  #
  # /usr/share, not /usr/local/share: Debian policy forbids a package writing
  # to /usr/local, and /etc/greetd/config.toml passes
  # --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions,
  # so greetd searches both. /usr/share/wayland-sessions is where this entry
  # lands and /usr/local/share/wayland-sessions is empty as of spec 16, when
  # the hand-installed copy was deleted after a confirmed login.
  #
  # bootstrap/greetd-config.toml's command= line must name the directory this
  # path sits in, and home/bootstrap.nix asserts exactly that at build time.
  #
  # The order mattered: ship this entry, confirm a login through it, THEN
  # delete the old one -- never delete first, since this is the one artifact
  # here that can leave a machine with no way to reach a desktop. While both
  # copies existed, tuigreet showed two identical entries, accepted as
  # cosmetic against the alternative of betting the login path on a file
  # nobody had logged in through yet.
  #
  # It names no /nix/store path, deliberately and verifiably: it reaches Nix
  # through $HOME/.nix-profile. home/deb.nix's noStorePaths guard fails the
  # build if that ever changes, because a root-owned file naming the store
  # breaks unrecoverably when the path is collected.
  calango.deb.files."usr/share/wayland-sessions/hyprland-nix.desktop" = ''
    [Desktop Entry]
    Name=Hyprland (Nix)
    Comment=calango-nix
    Type=Application
    DesktopNames=Hyprland
    Exec=/bin/sh -lc 'export XDG_DATA_DIRS="$HOME/.nix-profile/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"; exec "$HOME/.nix-profile/bin/uwsm" start -e -D Hyprland hyprland-nixgl.desktop'
  '';

  # The placeholder ~/.config/hypr/hyprland.conf that used to live here is
  # gone: the compositor is now pointed at the real Lua config in the store
  # (see the --config flag on hyprland-nixgl above), and Home Manager's
  # orphan-link cleanup removes the old symlink on the next activation.
}
