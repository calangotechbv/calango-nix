{ config, lib, pkgs, ... }:

let
  lfSource = ./../lf;

  # lf/preview's closure. Derived by reading the script end to end, not
  # transcribed from the grep starting point.
  previewPath = lib.makeBinPath (with pkgs; [
    bat          # as_text's primary path; batcat is Debian's rename of the
                 # same upstream binary and needs no separate package here --
                 # the `command -v bat` probe at line 25 finds this one first
    coreutils    # head (as_text's fallback and the jq/bsdtar branches' line
                 # limiter), du and cut (the binary-file fallback's size
                 # line), mktemp and rm (the pdf branch's scratch dir and its
                 # EXIT trap)
    file         # 5 call sites (lf/preview:77,116,129,144,156): the
                 # `file --mime-type` dispatch the whole case statement is
                 # built on, plus every `file -Lb` fallback line printed when
                 # a preferred tool is missing
    chafa        # as_image's sixel and symbols renderers
    poppler-utils # pdftoppm, the application/pdf branch's page-1 rasterizer
    jq           # the application/json branch's colourised, height-limited dump
    libarchive   # bsdtar -- the archive branch (zip/tar/gzip/bzip2/xz/zstd/
                 # rpm/deb) lists contents with bsdtar specifically, not GNU
                 # tar; libarchive is the nixpkgs package that provides it
  ]);

  # lfrc's own closure: `cmd open` and `cmd trash` run in lf's environment,
  # which is foot's, which is the compositor's. home/session.nix's
  # compositorPath does not carry these and should not -- they are lf's
  # requirements, so lf carries them itself.
  #
  # No editor package here on purpose. `cmd open`'s text branch runs
  # ${EDITOR:-vi}: EDITOR is expected to be set in this user's environment,
  # and both wrappers prepend to PATH rather than replace it, so a bare `vi`
  # fallback still resolves -- to Debian's /usr/bin/vi, which is already on
  # the ambient PATH this wrapper prepends onto. Adding a Nix editor would
  # just be a second, unreachable one shadowed by that prepend order.
  lfPath = lib.makeBinPath (with pkgs; [
    file        # cmd open's `case $(file --mime-type ...)` dispatch
    xdg-utils   # xdg-open, cmd open's fallback for anything non-textual
    glib        # gio, cmd trash's freedesktop-trash implementation
    coreutils   # mkdir (cmd mkdir) and touch (cmd touch)
  ]);

  # A wrapper rather than a PATH export inside preview, so the checked-in
  # script stays byte-identical to calango-desktop's and the whole diff of
  # this port is the one lfrc line.
  lfPreview = pkgs.writeShellScriptBin "lf-preview" ''
    export PATH=${previewPath}''${PATH:+:$PATH}
    exec ${lfSource}/preview "$@"
  '';

  lfConfig = pkgs.runCommand "lf-config" { } ''
    cp -r ${lfSource} "$out"
    chmod -R u+w "$out"

    substituteInPlace "$out/lfrc" \
      --replace-fail '@lfPreview@' '${lfPreview}/bin/lf-preview'

    # Same invariant as home/foot.nix and home/hyprland.nix. Do not widen.
    if grep -q '@[a-zA-Z]*@' "$out/lfrc"; then
      echo "unsubstituted token left in lfrc:" >&2
      grep -n '@[a-zA-Z]*@' "$out/lfrc" >&2
      exit 1
    fi
  '';

  lfWrapped = pkgs.writeShellScriptBin "lf" ''
    export PATH=${lfPath}''${PATH:+:$PATH}
    exec ${pkgs.lf}/bin/lf "$@"
  '';
in
{
  options.calango.lf = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "lf, wrapped with the PATH lfrc's commands need.";
  };

  config.calango.lf = lfWrapped;
  config.home.packages = [ lfWrapped ];
  config.xdg.configFile."lf".source = lfConfig;
}
