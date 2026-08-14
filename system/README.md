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

```sh
sudo install -Dm644 system/hyprland-nix.desktop \
  /usr/local/share/wayland-sessions/hyprland-nix.desktop
```

`/etc/greetd/config.toml` needs no edit: it already runs
`tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`.

Undo: `sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop`

Two things in that `Exec` line are not decoration, and both were paid for in
Task 6:

- It sets `XDG_DATA_DIRS` itself. Nothing else does — Debian's `nix-bin`
  ships no `/etc/profile.d/nix.sh`, and Home Manager's `hm-session-vars.sh`
  sets only `LOCALE_ARCHIVE_2_27`. Without it `uwsm` searches
  `/usr/share/wayland-sessions` first and starts apt's Hyprland, silently,
  from an entry named "Hyprland (Nix)".
- It names `hyprland-nixgl.desktop`, not `hyprland.desktop`. The stock entry
  runs `bin/start-hyprland` unwrapped, and an unwrapped Nix compositor cannot
  start on Debian at all — it dies in `CBackend::create()` looking for
  `/run/opengl-driver/lib`.

`$HOME` is resolved after login, and deliberately: greetd runs as `_greetd`
and cannot read inside `/home/isutton`, which is mode `0700`, so no absolute
path into a home directory can appear in this file.

## Undo, in full

```sh
sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop
sudo deluser --remove-home nixtest
```

That is the whole root-owned footprint. Everything else lives in `$HOME` and
`/nix`.
