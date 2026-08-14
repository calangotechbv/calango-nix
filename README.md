# calango-nix

A Hyprland desktop on Debian 13, where apt owns what needs root and Nix owns
everything else. Successor to `calango-desktop`, which stays as a reference
and is not an input to this build.

Specs and plans live in `docs/superpowers/`.

## Bootstrap

Nix comes from Debian, because `nix-daemon` is a root service:

```sh
sudo apt install nix-bin nix-setup-systemd
sudo usermod -aG nix-users "$USER"      # takes effect on next login
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
```

Check it:

```sh
nix --version                      # 2.26.3 or later
systemctl is-active nix-daemon.socket
```

## What apt still owns

The vendor stack (Google Chrome, docker-ce, 1Password, Google
endpoint-verification, Signal, VS Code), the login path (greetd, tuigreet),
PAM and the keyring, the system services, device-permission tools, the portal
frontend, Mesa, and `nix-bin` itself.
