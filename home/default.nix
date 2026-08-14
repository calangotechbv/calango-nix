{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # The eight that exist only in trixie-backports today.
    hyprland
    uwsm
    xdg-desktop-portal-hyprland
    hyprlock
    # hypridle and hyprpolkitagent arrive through their modules below.
    # ydotool is dev tier and belongs to spec 3.

    # A terminal, so the session can be used and checked. foot draws through
    # wayland shm rather than GL, which makes it a control: if foot opens and
    # a GL client does not, the fault is the GL wrapper and nothing else.
    foot

    # The GL stack. nixGLIntel is the Mesa wrapper and covers AMD; it sits
    # outside nixGL's auto.* set, so it needs no --impure.
    pkgs.nixgl.nixGLIntel

    # The three families the shell is drawn in. Named here rather than in
    # spec 2 because a missing font is indistinguishable from a broken
    # renderer, and this task is where the renderer is first tested.
    adwaita-fonts
    nerd-fonts.adwaita-mono
  ];

  # Links fonts into ~/.local/share/fonts and writes a fontconfig snippet, so
  # both Nix and Debian applications find them.
  fonts.fontconfig.enable = true;

  # A user unit that is WantedBy=graphical-session.target. Its only job in
  # spec 1 is to prove that uwsm built the target and that a unit inherited a
  # usable environment.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
      };
      listener = [
        {
          timeout = 900;
          on-timeout = "loginctl lock-session";
        }
      ];
    };
  };

  # Qt6, and so the cheapest proof that quickshell will draw in spec 2.
  services.hyprpolkitagent.enable = true;

  programs.home-manager.enable = true;
}
