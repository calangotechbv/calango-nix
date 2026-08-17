# The one place that decides which nixGL wrapper this machine uses.
#
# Before spec 14, five sites in home/ spelled `pkgs.nixgl.nixGLIntel` out for
# themselves. Changing the GL wrapper meant moving five places and nothing read
# the fifth. `nixglSingleSource` in home/default.nix now fails the build when
# the literal appears anywhere under home/ -- it does not distinguish a call
# site from a comment. It also does not look outside home/, so a wrapper
# written into flake.nix, or into a second file in this directory, would escape
# it. Widening it is not free: the guard's failure message names these three
# exports, so a guard that read its own module would match itself.
#
# This is a plain Nix function, NOT a Home Manager module. flake.nix lists its
# modules one by one, so a file absent from that list is visibly not one, and
# lib/ sits beside bin/, data/ and system/, which are already non-module
# directories.
#
# `bin` is exported deliberately rather than leaked. home/session.nix can use
# neither function -- it prepends compositorPath and passes four extra
# arguments to start-hyprland -- so it takes the raw path. The property this
# file buys is that ONE file decides which GL wrapper is used; it is not that
# one file spells the exec line.
{ pkgs }:

let
  bin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";

  # An indented string with a trailing newline, and both halves of that are
  # load-bearing. Measured before this file existed, by building three
  # candidate bodies against home/hyprland.nix:104's hand-written form:
  #
  #   hand-written, one line                7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
  #   this form                             7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
  #   plain string, no trailing newline     x3ymc3ksqzdy7vm7aj305ls2b7c2mfgf-hyprlock
  #
  # Three of the five adopting sites must keep their store path, which is how
  # this consolidation proves it changed nothing it did not mean to. Editing
  # this body -- even the whitespace -- moves all of them.
  body = exe: ''
    exec ${bin} ${exe} "$@"
  '';
in
{
  inherit bin;

  # A bare script. Use for an ExecStart or as a symlink target.
  wrap = name: exe: pkgs.writeShellScript name (body exe);

  # A package with bin/<name>. Use for home.packages.
  wrapBin = name: exe: pkgs.writeShellScriptBin name (body exe);
}
