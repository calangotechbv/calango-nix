# syncthing 2.1.2, through Home Manager's own service module rather than a
# verbatim copy of Debian's unit.
#
# Home Manager's module, not a copy of Debian's unit -- which is also how
# services.hypridle and services.hyprpolkitagent already run here, so this is
# not the departure an earlier version of this comment claimed it was.
#
# What is genuinely new is that this module can write user data:
# `syncthing-init` PATCHes the live config.xml over the REST API. That is what
# the omitted options and the assertions below are about. The module's unit
# also adds four hardening directives Debian's lacks -- LockPersonality,
# PrivateUsers, RestrictNamespaces and SystemCallFilter=@system-service -- on
# top of the three they share; the results document records whether any had to
# be reverted.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # `settings`, `guiCredentials` and `guiAddress` are ABSENT on purpose, and
  # their absence is the whole safety property of this file.
  #
  # The module computes
  #   doUpdateConfig = cleanedConfig != {} || guiCredentials != null || hasCustomGuiAddress
  # and creates `syncthing-init` -- a oneshot that PATCHes the running
  # configuration over syncthing's REST API -- whenever that is true. This
  # machine's ~/.local/state/syncthing/config.xml holds three folders and two
  # devices and is the authority. Nothing in this flake may write it.
  #
  # The module compares cfg.guiAddress against its own literal default
  # (127.0.0.1:8384, exactly what config.xml already serves and what
  # ~/.config/syncthingtray.ini connects to) -- not whether the option was
  # assigned. So writing that same default value back in explicitly is a
  # genuine no-op, and any *other* value flips hasCustomGuiAddress and
  # switches syncthing-init ON. Omission is the only way that is guaranteed
  # safe; do not "match" the value by hand.
  services.syncthing = {
    enable = true;
    package = pkgs.syncthing;
  };

  # The tray, from the same module. Both overrides are load-bearing and
  # neither is obvious from reading the option names.
  #
  # `package` defaults to syncthingtray-MINIMAL, which is a different build
  # from the syncthingtray running here today; accepting the default would
  # swap it silently. `command` defaults to "syncthingtray --wait", dropping
  # the qt-widgets-gui and --single-instance that the hand-made
  # ~/.config/autostart/syncthingtray.desktop has been passing since
  # 2026-07-15. qt-widgets-gui is still a valid operation in 2.1.0, checked
  # against the binary's own --help.
  services.syncthing.tray = {
    enable = true;
    package = pkgs.syncthingtray;
    command = "syncthingtray qt-widgets-gui --single-instance --wait";
  };

  # The firewall vocabulary for the daemon above.
  #
  # The file is named `calango`, not `syncthing`, and the profile inside it is
  # `calango-syncthing`, not `syncthing`. Debian's syncthing package is `rc`,
  # and dpkg still records it owning /etc/ufw/applications.d/syncthing while in
  # that state -- shipping the same path would need a conffile handover between
  # packages, and shipping the same profile NAME would collide in ufw's own
  # namespace with the one that file defines.
  #
  # No postinst is needed and none is written: ufw already declares
  # `interest-noawait /etc/ufw/applications.d`, and its postinst's triggered)
  # branch runs `ufw app update all`. dpkg fires it for us.
  #
  # A profile is not a rule. `ufw app update` refreshes profiles and any rule
  # already citing them; it never creates one. `sudo ufw allow calango-syncthing`
  # stays a deliberate human act -- which is just as well, since
  # /etc/ufw/user.rules is 0640 root:root and nothing here could verify a rule.
  #
  # No GUI entry, deliberately: 8384 listens on 127.0.0.1 only, measured with
  # `ss -lntup`. Shipping a profile for it would invite opening a shut port.
  calango.deb.ufwProfiles.calango = ''
    [calango-syncthing]
    title=Syncthing (calango-nix)
    description=Syncthing sync protocol and local discovery
    ports=22000|21027/udp
  '';

  calango.deb.ban = {
    syncthing = "Nix's, as of spec 15: syncthing 2.1.2 through services.syncthing. Debian's 1.29.5 cannot read the upgraded config.xml, which went version 37 to 52.";
    syncthingtray = "Nix's, as of spec 15. Debian's build embeds Qt WebEngine for its web GUI, which was 186 MB of the 288 MB the migration reclaimed; Nix's does not.";
  };

  # The guard for the paragraph above, and the first use of `assertions` in
  # this flake.
  #
  # Not a runCommand in home.packages. The guards that live there --
  # wrappedGuiApps, pulseaudioClients -- each inspect a *package*, and this
  # property is about the generation, which a derivation inside the generation
  # cannot inspect.
  #
  # It is not the only option, and an earlier version of this comment claimed
  # it was. flake.nix's checks read ${suffer.activationPackage}/home-files from
  # outside the generation, so a check could grep the built unit directory for
  # syncthing-init.service. assertions is chosen over that because it runs on
  # every generation build rather than only under `nix flake check`, and
  # because config.systemd.user.services is readable at eval -- so the property
  # is checked where it is decided rather than where it would be observed.
  assertions = [
    {
      assertion = config.systemd.user.services ? syncthing;
      message = ''
        services.syncthing produced no `syncthing` unit, so the assertion
        below asserts nothing about anything. Either the module was disabled
        or it renamed its unit. Decide which, on purpose, and update this
        pair together.
      '';
    }
    {
      assertion = !(config.systemd.user.services ? syncthing-init);
      message = ''
        services.syncthing produced `syncthing-init`, which PATCHes
        config.xml over syncthing's REST API. Something in home/syncthing.nix
        set `settings`, `guiCredentials` or `guiAddress` to something other
        than its default. This machine's config.xml is the authority: three
        folders and two devices, none of it declared here. Remove the option
        rather than changing its value.
      '';
    }
  ];
}
