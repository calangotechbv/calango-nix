# Everything about Slack, which as of spec 17 is apt's.
#
# This module exists rather than three entries in home/deb.nix because
# home/deb.nix's own comment states the rule: entries with no natural owner
# live there, and anything a module is responsible for lives in that module.
# Slack now has an owner.
#
# The direction is inverted from every other migration in this project. apt is
# the FRESHEST source here (4.51.180) and Nix the stalest (4.49.89, and unfree,
# so flake.nix would need a `config` it deliberately does not have). Slack was
# a flatpak until this spec; it is not a Nix candidate.
#
# Bare `home.packages` and `calango.deb.*` keys, with no `config.` prefix. That
# is the house form for a CONTRIBUTING module -- home/audio.nix:385,394 and
# home/syncthing.nix:81,88 are the precedents. home/deb.nix uses the explicit
# `options.` / `config.` form because it DECLARES the options; mixing the two
# shapes in one file makes the module system read `home` as an unknown
# top-level module key rather than as configuration.
{ pkgs, ... }:

let
  # Substituted rather than resolved at runtime, the same shape as
  # home/apps.nix's binConfig. `${db:Status-Abbrev}` cannot be written into
  # this Nix string directly -- `''${db:...}` is correct, unreadable, and
  # exactly the kind of thing a later editor "fixes" into a format string that
  # silently returns empty for every package. lib/deb.nix builds the same token
  # by concatenation for the same reason.
  statusFmt = "$" + "{db:Status-Abbrev}";

  slackLatest = pkgs.runCommand "slack-latest" { } ''
    mkdir -p "$out/bin"
    cp ${./../bin/slack-latest} "$out/bin/slack-latest"
    chmod u+w "$out/bin/slack-latest"

    substituteInPlace "$out/bin/slack-latest" \
      --replace-fail '@curl@' '${pkgs.curl}/bin/curl' \
      --replace-fail '@jq@' '${pkgs.jq}/bin/jq' \
      --replace-fail '@dpkg@' '${pkgs.dpkg}/bin/dpkg' \
      --replace-fail '@dpkgQuery@' '${pkgs.dpkg}/bin/dpkg-query' \
      --replace-fail '@statusFmt@' '${statusFmt}'

    # --replace-fail already fails on a token the Nix side names and the script
    # does not. This catches the other direction: a token the SCRIPT names and
    # the Nix side forgot, which would otherwise ship a literal @foo@ into a
    # command line. Same guard as home/apps.nix's calango-open.
    if grep -q '@[a-zA-Z]*@' "$out/bin/slack-latest"; then
      echo "unsubstituted token left in slack-latest:" >&2
      grep -n '@[a-zA-Z]*@' "$out/bin/slack-latest" >&2
      exit 1
    fi

    chmod 555 "$out/bin/slack-latest"
  '';
in
{
  home.packages = [ slackLatest ];

  calango.deb.keep.slack-desktop =
    "Corp set, permanently apt, and the one member where apt is the freshest source: 4.51.180 upstream against nixpkgs' unfree 4.49.89. A standalone .deb with no repository behind it, so nothing upgrades it and apt upgrade will never mention it -- bin/slack-latest asks Slack's release feed and a human acts on the answer. Its /etc/cron.daily/slack would re-create the retired packagecloud repo and its signing keys, which is why this package also ships /etc/default/slack.";

  # The knob file, shipped rather than edited, and the load-bearing part of
  # spec 17.
  #
  # slack-desktop ships no maintainer scripts at all -- its control archive
  # holds ./control and nothing else -- which reads as "the repo cannot come
  # back". It can: the payload ships /etc/cron.daily/slack, a Chromium-derived
  # script that recreates both. Traced against the values below:
  #
  #   repo_add_once=false               -> update_bad_sources, which returns at
  #                                        its first test while slack.list is
  #                                        unreadable
  #   repo_reenable_on_distupgrade=false -> install_new_key is never reached
  #
  # With reenable=true -- the value this machine carried before spec 17 --
  # install_new_key runs UNCONDITIONALLY and rewrites
  # /etc/apt/trusted.gpg.d/slack-desktop.gpg every day, so deleting that key is
  # not a deletion. And with the FILE ABSENT the script's first act is to write
  # it back with both knobs "true", install both keys, and create slack.list
  # ACTIVE against a retired jessie repo. Deleting it is the worst move
  # available, which is why this ships it instead.
  #
  # Same species as the deb-systemd-helper trap in CLAUDE.md: a rm that the
  # maintainer's own automation undoes. There the mechanism was a postinst;
  # here it is cron. /etc/cron.daily/google-chrome is the identical script for
  # a repo that genuinely works, and is out of scope.
  #
  # lib/deb.nix makes this a conffile because the key begins `etc/`. That is
  # required, not cosmetic: an /etc file with no conffiles entry is replaced by
  # dpkg on upgrade without asking, which would restore the defaults above.
  calango.deb.files."etc/default/slack" = ''
    repo_add_once="false"
    repo_reenable_on_distupgrade="false"
  '';
}
