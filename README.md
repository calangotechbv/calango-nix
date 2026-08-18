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
nix --version                            # 2.26.3 or later
systemctl is-active nix-daemon.service   # active
nix flake --help >/dev/null && echo ok   # needs the group change; see below
```

Check the **service**, not the socket. Debian ships both, but
`nix-daemon.service` is `WantedBy=multi-user.target`, so it starts on its own
and `nix-daemon --daemon` binds `/nix/var/nix/daemon-socket/socket` itself.
That leaves `nix-daemon.socket` reading `inactive (dead)` forever, and
`systemctl start nix-daemon.socket` failing, on a machine where Nix works
perfectly well.

Until you have logged in again, the `nix-users` group is not in your process,
and every `nix` command fails with
`getting status of '/nix/var/nix/daemon-socket/socket': Permission denied` —
the socket is `0666` but its directory is `0770 root:nix-users`. Either log in
again or prefix the command:

```sh
sg nix-users -c 'nix build ...'
```

## What apt still owns

The vendor stack (Google Chrome, docker-ce, 1Password, Google
endpoint-verification, Slack, VS Code), the login path (greetd, tuigreet),
PAM and the keyring, the system services, device-permission tools, the portal
frontend, Mesa, and `nix-bin` itself.

Slack is a standalone `.deb` with no repository behind it —
`slack-latest` reports when it is behind upstream.
