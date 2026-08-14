{ config, lib, pkgs, ... }:

let
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
  compositorPath = lib.makeBinPath (with pkgs; [
    bash          # sh -- wl-paste --type text --watch's handler is `sh -c '...'`
    cliphist      # cliphist store, the two clipboard watchers started on hyprland.start
    coreutils     # mkdir, tee, date -- the screenshot pipeline in shot()
    foot          # $terminal, and fileManager = "foot --app-id lf lf"
    gnugrep       # grep -qi, the cliphist text watcher's password-manager-hint guard
    grim          # screenshot capture, all three Print binds via shot()
    hyprland      # bare hyprctl in exec_cmd strings (notify, the two Print binds)
    jq            # -r queries against `hyprctl -j` in the two Print binds
    lf            # fileManager's file manager, passed to foot as an argument
    playerctl     # the four XF86Audio{Next,Pause,Play,Prev} binds
    procps        # pgrep -f, guarding both clipboard watchers against duplicates
    quickshell    # qs ipc call ... -- menu, switchWindow, and every panel toggle bind
    slurp         # the region picker inside Print's shot() guard
    uwsm          # uwsm finalize, on hyprland.start
    wireplumber   # wpctl, every volume/mute bind
    wl-clipboard  # wl-copy (shot()) and wl-paste (both clipboard watchers)
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
  # Prepended, not appended: apt's Hyprland, hyprctl and hyprlock are all
  # still installed under /usr/bin, and an appended path would let them win.
  #
  # QS_CONFIG_PATH looks removable and is not. `qs` with no -p/-c targets
  # the "default" config, and quickshell.service (home/quickshell.nix) is
  # launched with -p <store path>, so there is no "default" instance to
  # find -- every one of the 15 `qs ipc call ...` binds in hyprland.lua
  # (session menu, layout switcher, brightness keys, and every other panel
  # toggle) would otherwise fail with "Could not find 'default' config
  # directory or shell.qml in any valid config path." quickshell documents
  # this variable as the environment fallback for --path, so exporting it
  # here makes every `qs` the compositor spawns find the same running
  # instance quickshell.service started with -p, with no edit to
  # hyprland.lua and no coupling of hyprland.lua to quickshell's store path.
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
    export QS_CONFIG_PATH=${config.calango.quickshellConfig}
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
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

  # The placeholder ~/.config/hypr/hyprland.conf that used to live here is
  # gone: the compositor is now pointed at the real Lua config in the store
  # (see the --config flag on hyprland-nixgl above), and Home Manager's
  # orphan-link cleanup removes the old symlink on the next activation.
}
