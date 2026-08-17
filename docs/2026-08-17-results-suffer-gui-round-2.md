# Results: GUI applications round 2 — suffer

2026-08-17. Spec 13. Branch `gui-round-2`.

`signal-desktop` and `bitwarden` move from apt to Nix. Each was chosen because it
exercises a guard from spec 10 where that guard has never fired.

---

## Task 1: the GL verdict

Both packages are Electron, so both drive Chromium's GPU path — heavier than
anything spec 10 migrated. `CLAUDE.md` records that every Nix GUI binary needs
the nixGL wrapper, then spec 10 found `seahorse` and `gammastep` do not, so the
rule is narrower than stated and each application has to be asked separately.

`ldd` cannot answer it. `CLAUDE.md` excludes it precisely for toolkits that
`dlopen` their GL and platform plugins, where a binary starts, registers and dies
the instant it is asked to render. It was not consulted.

The only instrument is a person watching a window. The user ran each binary bare
and unwrapped, from a terminal inside the live Hyprland session:

```
/nix/store/2l2xlpbk6y4f5kk7z32wn8xpxqwnf1jz-signal-desktop-8.21.0/bin/signal-desktop
/nix/store/l3dy6i7lxh2vs5k3q3cylbkm57gchg52-bitwarden-desktop-2026.7.0/bin/bitwarden
```

**Both windows opened.** Reported by the user; no agent can observe this.

**Neither needs nixGL.** That closes the spec's stated primary risk, and it is
now three GUI applications in a row — `seahorse`, `gammastep`, and these two —
where the standing rule's parenthetical list turned out to be the whole of it.
The rule is about the compositor and its immediate surface-creating companions,
not about GUI applications in general. Spec 14 should not re-derive this from
scratch, but should still ask, because the instrument is cheap and a false
generalisation here costs a window that never appears.

### A risk the spec missed, caught before the run and not by the spec

Both applications open a config directory on first launch, and a newer build
migrates it:

```
~/.config/Signal       116M    attachments.noindex, blob_storage, config.json
~/.config/Bitwarden    4.8M
```

Signal Desktop keeps its message history in an encrypted database there and
refuses to start against one a newer version has migrated. So running 8.21.0 once
could leave Debian's 8.19.0 unable to open 116 MB of history — the same one-way
shape recorded for syncthing, except undocumented and triggered by the GL test
itself rather than by a deliberate conversion.

The spec's risk section did not mention it. It listed a GL failure after removal,
damage to `mimeapps.list`, exemption drift and a version regression, and missed
the one risk the very first task would trigger. Caught by asking what the test
would touch before running it, which is not a substitute for having written it
down.

Backups were taken first:

```
~/.config/Signal.pre-nix-backup       116M
~/.config/Bitwarden.pre-nix-backup    4.8M
```

And the risk was not hypothetical. Both live directories were written during the
test:

```
Signal      mtime 2026-08-17 16:26:10
Bitwarden   mtime 2026-08-17 16:26:26
(run at     2026-08-17 16:27:22)
```

What is **not** established is whether a schema migration actually occurred, or
whether those writes are ordinary cache and log activity. The version gap is two
minor releases, so a migration may not have happened at all. Nobody attempted to
start Debian's 8.19.0 afterwards to find out, and nobody should: if it has
migrated, the attempt teaches nothing the backup does not already cover, and if
it has not, a failed start could itself do damage. The backups are the recovery
path either way.

A tempting alternative was considered and rejected: Electron's `--user-data-dir`
would have pointed the test at a throwaway directory and touched nothing.
Whether Signal honours that flag rather than computing its own userData path was
unverified, and an unverified flag standing between a test and 116 MB of message
history is not a trade worth making. Copying was certain.
