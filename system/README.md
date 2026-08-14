# The root-owned footprint

This project puts **one** file outside `$HOME`. Everything else is Home
Manager, under the user account.

## The test account

Used by the migration only. Delete it once `isutton` has moved across.

```sh
sudo adduser --gecos "calango-nix test account" nixtest
sudo usermod -aG video,input,render,nix-users nixtest
```

`video` and `render` open the DRM device, `input` the keyboard and pointer,
`nix-users` the Nix daemon.

Undo: `sudo deluser --remove-home nixtest`

## The session entry

Added in Task 8. See that task for the file.

```sh
sudo install -Dm644 system/hyprland-nix.desktop \
  /usr/local/share/wayland-sessions/hyprland-nix.desktop
```

`/etc/greetd/config.toml` needs no edit: it already runs
`tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`.

Undo: `sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop`
