# The root-owned footprint

This was already stale before the bare-Debian bootstrap work -- `calango-desktop`
ships a ufw profile and `/etc/default/slack` beside the session entry -- and is
more so now that a greetd conffile is declared as well. Counted rather than
guessed, from `home/deb.nix`'s two manifest options together:

```sh
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.files' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
# 2 -- etc/default/slack, usr/share/wayland-sessions/hyprland-nix.desktop
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.ufwProfiles' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
# 1 -- the calango ufw profile
```

So `calango-desktop`'s own `.deb` manifest ships **3** files outside `$HOME`,
plus one conffile it hands to greetd's own package to install by hand --
`/etc/greetd/config.toml`, declared in `home/bootstrap.nix` and not part of
either option above. Everything else is Home Manager, under the user
account.

## The test account

Used by the migration only. Delete it once `isutton` has moved across.

```sh
sudo adduser --gecos "calango-nix test account" nixtest
sudo usermod -aG video,input,nix-users nixtest
```

`video` opens the DRM device, `input` the keyboard and pointer, `nix-users`
the Nix daemon. `render` is deliberately absent: `id` on the working account
shows it is not held, so the desktop demonstrably does not need it.

Undo: `sudo deluser --remove-home nixtest`

## The session entry

Hand-installed into `/usr/local/share/wayland-sessions/` for the whole life of
this flake, until spec 16 confirmed a login through a package-shipped copy and
deleted this one. It now ships as
`usr/share/wayland-sessions/hyprland-nix.desktop` inside `calango-desktop`'s
own `.deb` -- `home/session.nix`'s `calango.deb.files` entry, and `dpkg -S`
names `calango-desktop` as the owner. `/usr/local/share/wayland-sessions/` is
empty. `home/bootstrap.nix` asserts at build time that
`bootstrap/greetd-config.toml`'s own `--sessions` line still names the
directory this entry lands in, so the two can no longer silently disagree the
way this section's old install command and `/etc/greetd/config.toml` could.

The full bootstrap this project now provides -- packages, groups, apt
sources, the greetd configuration, and every gate -- is generated into
`RUNBOOK.md` and a Debian `preseed.cfg` by `nix build .#calangoBootstrap`
(`home/bootstrap.nix`, `bootstrap/runbook.md.in` and
`bootstrap/preseed.cfg.in`). The preseed drives the installer itself, ahead of
`RUNBOOK.md`'s Stage A, through the same declarations. The account and
session recipes in this file predate both and are kept only as a record of
Task 6, not as instructions to run.

The shipped entry's `Exec` line still carries the two things that are not
decoration, both paid for in Task 6:

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

That resolution is also why the entry only works for an account that has
already run `home-manager switch`. It is offered to every user from the
moment it is installed, and choosing it as anyone else fails on a missing
`$HOME/.nix-profile/bin/uwsm`. `tuigreet` runs with
`--remember-user-session`, so it will happily pre-fill the wrong account.

## Undo, in full

```sh
sudo rm /usr/local/share/wayland-sessions/hyprland-nix.desktop
sudo deluser --remove-home nixtest
```

That is the whole root-owned footprint. Everything else lives in `$HOME` and
`/nix`.
