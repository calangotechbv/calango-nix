# syncthing 2.1.2, through Home Manager's own service module rather than a
# verbatim copy of Debian's unit.
#
# This is the first module in this flake to adopt an upstream Home Manager
# service module instead of copying the unit the distribution shipped. That is
# a deliberate departure from the copy-verbatim rule, taken by the user with
# the trade-off stated: the module's unit adds four hardening directives
# Debian's lacks -- LockPersonality, PrivateUsers, RestrictNamespaces and
# SystemCallFilter=@system-service -- on top of the three they share. The
# results document records whether any of them had to be reverted.
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

  # The guard for the paragraph above, and the first use of `assertions` in
  # this flake.
  #
  # Not a runCommand in home.packages, which is where every other build-time
  # guard here lives. Those all inspect a *package* -- wrappedGuiApps reads
  # bin/, pulseaudioClients reads its own output -- and this property is about
  # the generation, which a derivation inside the generation cannot inspect.
  # config.systemd.user.services is readable at eval time, so the property is
  # checked where it is decided rather than where it would be observed.
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
