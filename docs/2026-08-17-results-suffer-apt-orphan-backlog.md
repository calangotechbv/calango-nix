# Results: the apt orphan backlog — suffer

2026-08-17

Spec: `docs/superpowers/specs/2026-08-17-apt-orphan-backlog-design.md`
Plan: `docs/superpowers/plans/2026-08-17-apt-orphan-backlog.md`

## Task 1: the audit

Read-only throughout. Nothing was marked, nothing was removed, and no
`apt`, `apt-mark` or `dpkg` command that mutates state was run. Every
number below was re-derived today rather than carried over from the
design, per the plan's instruction not to quote its figures without
counting them. The working artefacts are temporary files outside the
repository; they are described where they matter and never cited by path,
because a path under an ignored directory does not travel with the
repository.

### The census

```
$ apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | sort -u > "$CENSUS"
$ wc -l < "$CENSUS"
137
```

**137**, the same count the design measured. That agreement is worth one
sentence of caution rather than reassurance: the two measurements are
hours apart on the same machine with no package operation between them, so
matching is what a correct instrument does, not independent corroboration
of the number.

The full set:

```
avahi-utils cups-pk-helper emacs-bin-common emacs-common emacs-el exo-utils
ffmpegthumbnailer galternatives gir1.2-handy-1 gir1.2-notify-0.7
gir1.2-packagekitglib-1.0 gir1.2-polkit-1.0 gnome-accessibility-themes
gnome-themes-extra gtk2-engines-pixbuf gvfs-fuse install-info kitty-doc
kitty-shell-integration kitty-terminfo libconfig++11 libdbusmenu-lxqt0
libdisplay-info2 libei1 libexo-2-0 libexo-common libfcft4t64 libffado2
libffmpegthumbnailer4v5 libfm-extra4t64 libfm-qt6-15 libfm-qt-l10n
libgccjit0 libglibmm-2.4-1t64 libglu1-mesa libgtk-layer-shell0 libhandy-1-0
libjpeg-turbo-progs libjs-sphinxdoc libjs-underscore libkf6idletime6
libkf6screen8 libkf6screendpms8 libkscreen-bin libkscreen-data
libldacbt-abr2 liblua5.4-0 liblxqt-globalkeys2 libm17n-0 libmenu-cache3
libmenu-cache-bin libmng1 libopenfec1 libotf1 libpackagekit-glib2-18
libpipewire-0.3-modules libpolkit-qt6-1-1 libportal1 libpulsedsp
libqt5core5t64 libqt5dbus5t64 libqt5gui5t64 libqt5network5t64 libqt5qml5
libqt5qmlmodels5 libqt5quick5 libqt5svg5 libqt5waylandclient5
libqt5waylandcompositor5 libqt5widgets5t64 libqt6svgwidgets6 libroc0.4
libsigc++-2.0-0v5 libspeexdsp1 libstartup-notification0 libthunarx-3-0
libtree-sitter0.22 libtumbler-1-0t64 libturbojpeg0 libutf8proc3
libwebpdecoder3 libwireplumber-0.5-0 libwnck-3-0 libwnck-3-common
libxcb-dpms0 libxcb-screensaver0 libxcb-xinerama0 libxfce4panel-2.0-4
libxfce4ui-2-0 libxfce4ui-common libxfce4util7 libxfce4util-bin
libxfce4util-common libxfce4windowing-0-0 libxfce4windowing-common
libxfconf-0-3 libxml++2.6-2v5 lximage-qt lximage-qt-l10n lxqt-config
lxqt-config-l10n lxqt-menu-data lxqt-policykit lxqt-policykit-l10n
lxqt-powermanagement lxqt-powermanagement-l10n lxqt-qtplugin lxqt-session
lxqt-session-l10n lxqt-sudo lxqt-sudo-l10n lxqt-system-theme lxqt-themes
m17n-db pcmanfm-qt-l10n pnp.ids python3-cups python3-cupshelpers
python3-smbc qlipper qps qt5-gtk-platformtheme qt6-image-formats-plugins
qttranslations5-l10n qtwayland5 system-config-printer
system-config-printer-common system-config-printer-udev thunar-data tumbler
tumbler-common xaw3dg xfconf xscreensaver xscreensaver-data xscreensaver-gl
xsettingsd
```

### The profile, and why its bins differ from the design's

```
$ awk '{ if ($0 ~ /^lib/)                   b="library lib*";
         else if ($0 ~ /l10n$/)             b="translation *-l10n";
         else if ($0 ~ /^lxqt/)             b="lxqt session lxqt*";
         else if ($0 ~ /(-data|-common)$/)  b="data *-data/-common";
         else if ($0 ~ /^gir1\.2-/)         b="typelib gir1.2-*";
         else if ($0 ~ /^python3-/)         b="python3-*";
         else                               b="everything else";
         c[b]++ } END { for (k in c) printf "%-22s %3d\n", k, c[k] }' "$CENSUS"

library lib*            77
everything else         30
lxqt session lxqt*       9
translation *-l10n       8
data *-data/-common      6
typelib gir1.2-*         4
python3-*                3
                       ---
                       137
```

The design's table reads 76 / 30 / 9 / 8 / 7 / 4 / 3. Both sum to 137 and
both partition the same set; the two disagree on two packages because the
bins are applied in an order and the design did not fix one.
`libfm-qt-l10n` matches `^lib` and `l10n$`, and `lxqt-menu-data` matches
`^lxqt` and `-data$`; whichever pattern runs first claims them. This is
worth naming rather than reconciling, because the design's own note says a
first attempt at that table summed to 150 through overlapping patterns —
the ordering is load-bearing and neither document should be read as
authority for a per-bin figure.

The shape of the set is what matters and it survives either ordering:
roughly four fifths of the 137 are libraries, translations or data files of
applications that are already gone, and the thirty in "everything else" is
where every decision lives.

### The union in-use check

`/proc/<pid>/maps` is unreadable for other users' processes and root
outnumbers the user roughly three to one here, so the `ps` half is not
optional — a `/proc`-only walk covers about a quarter of the machine.

```
$ { for p in /proc/[0-9]*; do
      readlink "$p/exe" 2>/dev/null
      awk '{print $NF}' "$p/maps" 2>/dev/null | grep '^/'
    done
    ps -eo args= 2>/dev/null | awk '{print $1}' | grep '^/'
  } | sort -u | grep -E '^/(usr|etc|lib|bin|sbin|opt)' > "$FILES"
$ wc -l < "$FILES"
635

$ xargs -a "$FILES" -d '\n' dpkg -S 2>/dev/null \
    | sed 's/:.*//' | tr ',' '\n' | sed 's/ //g' | sort -u > "$PKGS"
$ wc -l < "$PKGS"
333

$ comm -12 "$CENSUS" "$PKGS"
gir1.2-notify-0.7
gvfs-fuse
libmng1
python3-cups
qt6-image-formats-plugins
xscreensaver
```

635 in-use paths resolving to 333 packages, of which **six** are in the
census — the same six the design found, again on the same session with the
same processes still alive, so again a reproduction rather than a second
opinion.

### The six hits, and their holders

```
$ for pkg in $(comm -12 "$CENSUS" "$PKGS"); do
    echo "=== $pkg"
    for f in $(dpkg -L "$pkg" 2>/dev/null | grep -Ff "$FILES" - 2>/dev/null); do
      for p in /proc/[0-9]*; do
        if grep -qF "$f" "$p/maps" 2>/dev/null || [ "$(readlink $p/exe 2>/dev/null)" = "$f" ]; then
          printf '  %s <- pid %s: %s\n' "$f" "${p#/proc/}" \
            "$(tr '\0' ' ' < $p/cmdline 2>/dev/null | cut -c1-70)"
        fi
      done
    done | sort -u
  done

=== gir1.2-notify-0.7
  /usr/lib/x86_64-linux-gnu/girepository-1.0/Notify-0.7.typelib <- pid 3823: /usr/bin/python3 /usr/share/system-config-printer/applet.py
=== gvfs-fuse
  /usr/libexec/gvfsd-fuse <- pid 4116: /usr/libexec/gvfsd-fuse /run/user/1000/gvfs -f
=== libmng1
  /usr/lib/x86_64-linux-gnu/libmng.so.1.1.0.10 <- pid 3790: /usr/bin/deskflow
=== python3-cups
  /usr/lib/python3/dist-packages/cups.cpython-313-x86_64-linux-gnu.so <- pid 3823: /usr/bin/python3 /usr/share/system-config-printer/applet.py
```

That loop is O(files × processes) and did not finish inside two minutes;
it was cut off after `python3-cups`. The remaining two were resolved by
first asking which of their files are held and then searching only for
those, which is the same question asked in an order that terminates:

```
$ dpkg -L qt6-image-formats-plugins | grep -Ff "$FILES" -
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqicns.so
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqmng.so
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqtga.so
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqtiff.so
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqwbmp.so
/usr/lib/x86_64-linux-gnu/qt6/plugins/imageformats/libqwebp.so
$ dpkg -L xscreensaver | grep -Ff "$FILES" -
/usr/share/fonts/xscreensaver/gallant12x22.ttf

$ for f in <those seven paths>; do
    grep -lF "$f" /proc/[0-9]*/maps 2>/dev/null | while read m; do
      p=${m%/maps}
      printf '%s <- pid %s: %s\n' "$f" "${p#/proc/}" "$(tr '\0' ' ' < $p/cmdline | cut -c1-70)"
    done
  done
…/imageformats/libqicns.so <- pid 3790: /usr/bin/deskflow
…/imageformats/libqmng.so  <- pid 3790: /usr/bin/deskflow
…/imageformats/libqtga.so  <- pid 3790: /usr/bin/deskflow
…/imageformats/libqtiff.so <- pid 3790: /usr/bin/deskflow
…/imageformats/libqwbmp.so <- pid 3790: /usr/bin/deskflow
…/imageformats/libqwebp.so <- pid 3790: /usr/bin/deskflow
/usr/share/fonts/xscreensaver/gallant12x22.ttf <- pid 28847: foot
```

Four holders in total: pid 3790 `deskflow`, pid 3823 the printer applet,
pid 4116 `gvfsd-fuse`, pid 28847 `foot`.

### Classification: why each file is held

**`libmng1` and `qt6-image-formats-plugins` — dead, stale process.** The
holder is a ghost, and this is not an inference from the package database
alone; the kernel says so on the process itself:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' deskflow
dpkg-query: no packages found matching deskflow

$ dpkg -S /usr/bin/deskflow
dpkg-query: no path found matching pattern /usr/bin/deskflow

$ ls -l /usr/bin/deskflow
ls: cannot access '/usr/bin/deskflow': No such file or directory

$ readlink /proc/3790/exe
/usr/bin/deskflow (deleted)
```

`deskflow` is gone from dpkg's database entirely — one state past `rc` —
its binary is not on disk, and `/proc/3790/exe` carries the kernel's own
`(deleted)` marker. The process was started at login (`/proc/3790` is
dated 06:11, the session's start) and `deskflow` was removed later the
same day in spec 10, which is exactly the shape `CLAUDE.md` records:
removing a package does not kill its running process, and absence is only
measurable after the session ends. These two hits measure history.

There is one live Qt6 consumer on this machine that the design did not
consider, and it is worth ruling in rather than passing over, because a
Qt image-format plugin is `dlopen`ed on demand and so would not appear in
any process's maps until the moment it is needed:

```
$ for m in $(grep -lF 'libQt6Core' /proc/[0-9]*/maps); do …; done
1512320  /nix/store/…-quickshell-0.3.0        libQt6Core -> /nix/store/…-qtbase-6.11.1
3790     /usr/bin/deskflow                    libQt6Core -> /usr/lib/…/libQt6Core.so.6.8.2
3808     /nix/store/…-hyprpolkitagent-        libQt6Core -> /nix/store/…-qtbase-6.11.1
3793     /usr/bin/syncthingtray …             libQt6Core -> /usr/lib/…/libQt6Core.so.6.8.2
```

`syncthingtray` (pid 3793, `ii 1.7.5-1`, not in the census) is a live
Debian Qt6 application. It does not declare the plugins, and no installed
package does:

```
$ apt-cache show syncthingtray | grep '^Depends:'
Depends: … libqt6svg6 (>= 6.6.0), libqt6webenginecore6 … libqt6widgets6 …

$ apt-cache rdepends qt6-image-formats-plugins | tail -n +3 | sed 's/^ *|\?//' | sort -u
calibre-bin dolphin gcompris-qt gwenview lximage-qt nheko nomacs obs-studio qtcreator-doc
```

Of those nine reverse-dependents exactly one is installed — `lximage-qt`,
itself in the census. The plugins provide ICNS, MNG, TGA, TIFF, WBMP and
WebP decoding; `syncthingtray` renders its icons through
`libmartchus-qtforkawesome1t64` and `libQt6Svg`, both of which it declares
and neither of which is in the census. Nothing measured here says
`syncthingtray` will never ask Qt to decode a TIFF — that is not knowable
from outside the process — but no declared dependency, no installed
reverse-dependent, and a dead holder together make this a removal rather
than a keep.

**`xscreensaver` — dead, fontconfig mmap.** The single held file is a
font, and the holder is a terminal:

```
/usr/share/fonts/xscreensaver/gallant12x22.ttf <- pid 28847: foot
$ readlink -f /proc/28847/exe
/nix/store/1pn4da8n8yprl0ag7j6wxm0dis3jkr0h-foot-1.27.0/bin/foot
```

`CLAUDE.md` records that fontconfig builds a process's font map at startup
and a running application keeps deleted fonts mmapped. The detail worth
adding is the provenance: the holder is **Nix's** foot 1.27.0 — Debian's
`foot` is `rc`, removed earlier in this project (`CLAUDE.md` records it
under "There is deliberately no foot server") — so a Nix binary keeps a
Debian font package looking alive. The hit says a terminal was launched
while the font existed. It says nothing about whether the screensaver is
wanted, which is a separate question answered further down.

**`gir1.2-notify-0.7` and `python3-cups` — decision needed.** Both are
held by pid 3823, and that process is a deliberately autostarted desktop
feature rather than a leftover:

```
$ cat /proc/3823/cgroup
0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-print\x2dapplet@autostart.service
$ awk '/^PPid/{print $2}' /proc/3823/status → 2865 → /usr/lib/systemd/systemd --user
$ dpkg -L system-config-printer | grep -E 'autostart|\.desktop'
/etc/xdg/autostart
/etc/xdg/autostart/print-applet.desktop
/usr/share/applications/system-config-printer.desktop
```

The unit name `app-print\x2dapplet@autostart.service` is systemd's XDG
autostart generator acting on `/etc/xdg/autostart/print-applet.desktop`,
so the applet starts on every login by design. Whether that design is
still wanted is a user question, which is why this goes to the decision
list rather than being settled here.

**`gvfs-fuse` — decision needed.** The holder is the package's own daemon:

```
$ ps -eo pid,user,args= | grep gvfs
   4089 isutton  /usr/libexec/gvfsd
   4116 isutton  /usr/libexec/gvfsd-fuse /run/user/1000/gvfs -f
 427137 isutton  /usr/libexec/gvfsd-metadata
1514832 isutton  /usr/libexec/gvfsd-trash  --spawner :1.45 …
1514898 isutton  /usr/libexec/gvfsd-network --spawner :1.45 …
1514906 isutton  /usr/libexec/gvfsd-dnssd   --spawner :1.45 …
```

A hit whose only holder is the package's own daemon is close to circular
as evidence of need, so the substantive measurement is what that daemon is
currently serving:

```
$ mount | grep gvfs
gvfsd-fuse on /run/user/1000/gvfs type fuse.gvfsd-fuse (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)
$ ls -la /run/user/1000/gvfs/
total 0
dr-x------  2 isutton isutton   0 Aug 17 06:11 .
drwx------ 20 isutton isutton 880 Aug 17 12:31 ..
```

The FUSE bridge is mounted and **empty**: zero gvfs mounts exist right
now. That is a statement about this moment, not about the feature — the
bridge's whole purpose is to appear the instant a GIO mount is made, and
nothing here proves the user will never make one. Note also that nothing
requires it:

```
$ apt-cache show gvfs | grep -E '^(Depends|Recommends|Suggests):'
Depends: gvfs-common …, gvfs-daemons …, gvfs-libs …, libc6 …, libglib2.0-0t64 …
Suggests: gvfs-backends
```

`gvfs` neither depends on nor recommends `gvfs-fuse`, so the package is
held by nothing but its own running daemon. It is a decision.

No hit fell into the fourth category, **keep, unexplained**.

### What the in-use check cannot see, demonstrated

The check covers this moment, which the spec already says. It has a second
limit that the spec does not name and that this machine demonstrates
directly: **it is blind to interpreted programs**, because `exe` and
`argv[0]` both point at the interpreter and the script is read rather than
mapped.

```
$ grep -c '^/usr/share/system-config-printer/applet\.py$' "$FILES" || echo "0 - MISSED"
0 - MISSED
$ grep -c '^/usr/bin/python3$' "$FILES"
1
$ grep -o '/usr/share/system-config-printer[^ ]*' /proc/3823/maps | sort -u
(no output)
$ ls -l /proc/3823/fd | grep -c system-config-printer
0
```

The running printer applet's own program file is nowhere in the in-use
set. `/usr/bin/python3` is, and `dpkg -S` resolves that to
`python3-minimal`, not to `system-config-printer`. So the package whose
code is executing right now — a package that **is** in the census — was
not among the six hits. `python3-cups` was caught only because it is a
compiled extension module and therefore mmapped; `python3-cupshelpers` is
pure Python and was missed for the same reason the applet was, even though
line 40 of the running script reads:

```
$ grep -n '^import\|^from' /usr/share/system-config-printer/applet.py | sed -n '1,20p'
20:import cups
40:import cupshelpers.installdriver
53:from gi.repository import Notify
```

Three of the printer cluster's packages are in genuine live use and the
instrument found two. Had the audit stopped at the six hits and treated
them as the complete live set, `system-config-printer` and
`python3-cupshelpers` would have been swept out from under a running
process. This is the concrete reason the plan's Step 5 exists.

### The thirty read by hand

```
$ for p in $(grep -vE 'l10n$|^lib|(-data|-common)$|^lxqt|^gir1\.2-|^python3-' "$CENSUS"); do
    printf '%-30s %s\n' "$p" "$(dpkg-query -W -f='${binary:Summary}' "$p" 2>/dev/null)"
  done | wc -l
30
```

Thirty, the same thirty the spec lists. Before reading them individually,
one global question, since a package with a live consumer outside the
census would settle its own case:

```
$ while read p; do
    r=$(apt-cache rdepends --installed --no-suggests --no-conflicts --no-breaks \
          --no-replaces --no-enhances "$p" 2>/dev/null | tail -n +3 \
        | sed 's/^ *|\?//' | sort -u | grep -vxF -f "$CENSUS" || true)
    [ -n "$r" ] && printf '%-30s <- %s\n' "$p" "$(echo $r)"
  done < "$CENSUS" | wc -l
0
```

Zero of the 137 has an installed `Depends` or `Recommends` holder outside
the census. **That is a consistency check, not evidence.** It is very
nearly the definition of what `apt-get autoremove` computes, so it can
only fail if the instruments disagree with each other. It is recorded
because a silent pipeline is indistinguishable from a broken one, and this
one was proven able to print before its emptiness was believed:

```
$ apt-cache rdepends --installed --no-recommends … gvfs | …
gvfs-backends
gvfs-fuse
$ apt-cache rdepends --installed --no-recommends … libmng1 | …
qt6-image-formats-plugins
```

So the reverse-dependency graph decides none of the thirty, and each was
read on what it is for.

**The emacs set — `emacs-el`, and with it `emacs-bin-common`,
`emacs-common`, plus `install-info`, `xaw3dg`, `m17n-db`, `libm17n-0`,
`libotf1`, `libgccjit0`, `libtree-sitter0.22`.** `emacs-lucid` was removed
in spec 10 (recorded there as `un`). `emacs-el` is the Lisp source
distribution and has no reader left. `install-info` is registered in
dpkg's `File` triggers and maintains `/usr/share/info`, and its only
installed reverse-dependent is `emacs-common`; no info reader survives
(`info` is not installed, `texinfo` is `un`). `xaw3dg` is the Athena
widget set whose reverse-dependents are `emacs-lucid`, `gv`, `xfig` and
friends, none installed. `m17n-db` is the multilingual text database
behind `libm17n-0`, itself reached only from the emacs side —
`ibus-typing-booster`, `scim-m17n` and `uim-data` are all absent, and no
input-method framework is installed. **Removals**, all of them.

**The kitty set — `kitty-doc`, `kitty-shell-integration`,
`kitty-terminfo`, and `libjs-sphinxdoc` / `libjs-underscore` behind the
docs.** `kitty` was removed in spec 10; `home/quickshell.nix:191-196`
records deliberately that this project installs foot and that the theme
switcher's kitty path was deleted. The only reverse-dependent of all three
is `kitty` itself. `kitty-terminfo` would matter if a kitty terminal
existed to `ssh` out of; there is none, and foot's terminfo is a separate
package. **Removals.**

**The xfce / thunar set — `exo-utils`, `ffmpegthumbnailer`, `tumbler`,
`xfconf`, and their libraries.** `thunar` and `thunar-volman` are `rc`
since spec 10. `exo-utils`' reverse-dependents are `thunar`,
`thunar-volman`, `xfce4-panel`, `xfce4-settings`, `xfce4-terminal`;
`tumbler`'s are `ristretto`, `rygel`, `thunar`, `xfdesktop4`; `xfconf`'s
are `xfce4`, `xfce4-session`, `xfce4-settings`. Not one of those is
installed. `ffmpegthumbnailer` is a tumbler plugin backend reached from
`pcmanfm-qt` (removed in spec 10) and `mate-desktop-environment`
(absent). `tumbler` is XFCE's D-Bus thumbnailer; GTK file choosers
thumbnail through gdk-pixbuf and do not call it. **Removals.**

**The LXQt set — `lximage-qt`, `qlipper`, `qps`, `galternatives`, and the
`lxqt-*` group.** `pcmanfm-qt` is `rc`. `qlipper` is a clipboard-history
applet; this desktop's clipboard history is `cliphist` plus
`wl-clipboard` from Nix (`home/session.nix:38,52`), and the repository has
zero references to qlipper. `qps` is a Qt process manager reached only
from `lxqt`, `lxqt-core`, `lxqt-session`, none installed.
`galternatives` is a GUI for `update-alternatives` whose only
reverse-dependent is `lxqt-config`, itself in the census. `lximage-qt` is
reached from `lxqt`, `lxqt-core` and `pcmanfm-qt`, and it is not a
registered handler for anything:

```
$ sed -n 's/^[^=]*=//p' ~/.config/mimeapps.list | tr ';' '\n' | sed '/^$/d' | sort -u
bitwarden.desktop
claude-code-url-handler.desktop
eu.calangotech.CalangoOpen.desktop
eu.calangotech.KBrowserSelector.desktop
signal-desktop.desktop
slack.desktop
```

Resolved against the search path, `bitwarden.desktop` and
`signal-desktop.desktop` come from their own apt packages,
`claude-code-url-handler.desktop` and `eu.calangotech.CalangoOpen.desktop`
from `~/.local/share/applications`, and
`eu.calangotech.KBrowserSelector.desktop` and `slack.desktop` resolve to
nothing on those four directories at all — the last is the flatpak Slack,
whose entry lives under the flatpak exports. No id in `mimeapps.list`
belongs to a package in the census, so no MIME handler breaks anywhere in
this removal; the two that do not resolve are unaffected either way, since
a handler that already fails to resolve cannot be broken by removing
something else. **Removals.**

**The GTK2 theme set — `gnome-accessibility-themes`, `gnome-themes-extra`,
`gtk2-engines-pixbuf`.** All three theme GTK2, and GTK2 is already gone:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    libgtk2.0-0t64 libgtk2.0-common gnome-themes-extra-data
rc  libgtk2.0-0t64 2.24.33-7
rc  libgtk2.0-common 2.24.33-7
ii  gnome-themes-extra-data 3.28-4

$ grep -lF 'libgtk-x11-2.0' /proc/[0-9]*/maps | wc -l
0
```

The GTK2 runtime is `rc` and no process on the machine maps it. This
flake already handles the case: `gtk/apply-gtk-theme:435-478` detects
GTK2 by probing for the library and skips writing `~/.gtkrc-2.0`
otherwise, so the removal changes nothing that script does. Note
`gnome-themes-extra-data` is **not** in the census and stays — it is held
by `qt6-gtk-platformtheme`, which is installed and outside the census.
**Removals**, and the data package they share is not affected.

**`xsettingsd`.** An XSettings daemon for X11 applications; its
reverse-dependents are `kde-config-gtk-style`, `lxqt-branding-debian`,
`lxqt-config` and `xsettings-kde`. Only `lxqt-config` is installed and it
is in the census. Not running, zero references in this repository, and
GTK/Qt theming here is driven by `gtk/apply-gtk-theme` and
`home/gtk.nix`. **Removal.**

**`pnp.ids`.** The PNP monitor-vendor registry at
`/usr/share/hwdata/pnp.ids`. Its reverse-dependents are `colord-kde`,
`hwdata`, `kwin-common` and `libkf6screen8`; the first three are not
installed (`hwdata` is `un`) and `libkf6screen8` is in the census. The
compositor's `libdisplay-info` comes from Nix. **Removal.**

**`avahi-utils` and `cups-pk-helper`.** Both belong to the printer
cluster rather than standing alone: `avahi-utils` is a `Recommends` of
`system-config-printer` (network printer discovery — the `avahi-daemon`
itself is a separate, non-orphaned system package still running as pid
1083), and `cups-pk-helper` is the PolicyKit helper the configuration GUI
uses for privileged operations. **Decision**, with the printer cluster.

**`gvfs-fuse`.** **Decision**, as above.

**`xscreensaver`, `xscreensaver-gl`.** X11 screensaver and its GL modules.
Everything measurable says nothing uses them: no `~/.xscreensaver` config
file exists, no `xscreensaver` process is running, the shipped user unit
is `disabled`, and the repository has zero references while
`hyprlock`/`hypridle` appear across `home/session.nix`,
`home/hyprland.nix`, `hypr/hyprland.lua` and `hypr/idle-sleep.sh`. What
none of that establishes is whether the user *wants* a screensaver, which
is the only question left, so this goes to the decision list with a
recommendation rather than being decided here. **Decision.**

**`qt5-gtk-platformtheme`, `qtwayland5`, and the Qt5 libraries.** No Qt5
application is installed and none is running:

```
$ grep -lF 'libQt5Core' /proc/[0-9]*/maps | wc -l
0
$ apt-cache rdepends --installed … libqt5core5t64 | … | grep -vxF -f "$CENSUS"
(none outside the orphan set)
```

The whole Qt5 stack here was LXQt's. **Removals.**

**`qt6-image-formats-plugins`.** **Removal**, argued above.

**`system-config-printer`, `system-config-printer-udev`,
`python3-cups`, `python3-cupshelpers`, `python3-smbc`.** **Decision**,
with the cluster.

**`install-info`, `m17n-db`, `xaw3dg`, `tumbler`, `xfconf`,
`ffmpegthumbnailer`, `exo-utils`, `galternatives`, `qps`, `qlipper`,
`lximage-qt`** are each covered above. That accounts for all thirty:
twelve go to the decision list (eight printer, two xscreensaver,
`gvfs-fuse`, and `avahi-utils` with the printer set), and eighteen are
removals.

### One library the design missed, and it is a keep

`libpipewire-0.3-modules` appears in the census and every automated check
clears it — zero processes map it, no holder outside the census. It is
still a **keep**, and the reason is precisely the limit named above: its
consumers are not running.

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    pipewire pipewire-bin pipewire-pulse wireplumber \
    libpipewire-0.3-0t64 libpipewire-0.3-modules libspa-0.2-modules
rc  pipewire 1.4.2-1
rc  pipewire-bin 1.4.2-1
rc  pipewire-pulse 1.4.2-1
rc  wireplumber 0.5.8-2
ii  libpipewire-0.3-0t64 1.4.2-1
ii  libpipewire-0.3-modules 1.4.2-1
ii  libspa-0.2-modules 1.4.2-1
```

Debian's daemons are all `rc` since spec 9, and the live ones are Nix's,
read from the units' own `MainPID` rather than from a name:

```
$ for u in pipewire.service wireplumber.service; do
    pid=$(systemctl --user show $u -p MainPID --value)
    printf '%-22s MainPID=%s exe=%s\n' "$u" "$pid" "$(readlink -f /proc/$pid/exe)"
  done
pipewire.service       MainPID=2889 exe=/nix/store/…-pipewire-1.6.6/bin/pipewire
wireplumber.service    MainPID=2891 exe=/nix/store/…-wireplumber-0.5.14/bin/wireplumber

$ grep -o '[^ ]*bluez5[^ ]*' /proc/2891/maps | sort -u | head -3
/nix/store/…-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-bluez5.so
/nix/store/…-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
/nix/store/…-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-aptx.so
```

The bluez5 SPA plugins were read from the **session manager's** maps, not
pipewire's, because `CLAUDE.md` records that a check of pipewire's maps
for them cannot fail. They resolve entirely into the Nix store, so the
Debian audio residue in the census (`libwireplumber-0.5-0`,
`libldacbt-abr2`, `libpulsedsp`, and the rest) is genuinely dead.

`libpipewire-0.3-modules` is the exception because it serves *clients*,
not the daemon:

```
$ apt-cache rdepends --installed --no-suggests … libpipewire-0.3-0t64 | …
libfluidsynth3
libpipewire-0.3-modules
libwireplumber-0.5-0
qemu-system-gui

$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    libfluidsynth3 qemu-system-gui qemu-system-x86
ii  libfluidsynth3 2.4.4+dfsg-1+deb13u2
ii  qemu-system-gui 1:10.0.11+ds-0+deb13u1
ii  qemu-system-x86 1:10.0.11+ds-0+deb13u1

$ strings /usr/lib/x86_64-linux-gnu/libpipewire-0.3.so.0 | grep -E 'pipewire-0\.3$' | sort -u
/usr/lib/x86_64-linux-gnu/pipewire-0.3

$ dpkg -L libpipewire-0.3-modules | grep -c '\.so$'
44
```

`libpipewire-0.3-0t64` — Debian's client library — is kept installed by
`libfluidsynth3` (reached from `gstreamer1.0-plugins-bad` and
`libsdl2-mixer-2.0-0`) and by `qemu-system-gui` (reached from
`qemu-system-x86`), none of which is in the census. That library's
compiled-in module directory is `/usr/lib/x86_64-linux-gnu/pipewire-0.3`,
which is exactly what `libpipewire-0.3-modules` fills with 44 shared
objects. **The inference, stated as an inference:** a process that links
Debian's `libpipewire-0.3.so` and creates a PipeWire client context loads
its protocol and client-node modules from that directory, so removing the
package would break audio for a Debian-linked PipeWire client. What was
*measured* is the dependency chain, the compiled-in path, and that no such
process is running now — not a failure, because provoking one would mean
starting a VM. Under this project's conservatism rule that is a keep.

It is not a cheap one. `libffado2` and `libroc0.4` are hard `Depends` of
the modules package, and they pull further:

```
$ dpkg-query -W -f='${Installed-Size} ${Package}\n' <closure> | awk '{s+=$1;print}END{printf "TOTAL %d KiB\n",s}'
135 libconfig++11
2574 libffado2
2917 libglibmm-2.4-1t64
236 libopenfec1
4267 libpipewire-0.3-modules
1604 libroc0.4
67 libsigc++-2.0-0v5
102 libspeexdsp1
264 libxml++2.6-2v5
TOTAL 12166 KiB
```

Nine packages and roughly 12 MB, against the cost of a VM losing its
audio device with no obvious cause. The asymmetry the spec states decides
it.

### Two side findings

**No dangling `/etc/systemd/user` link will be created by this removal.**
`CLAUDE.md` records that removing a Debian package which ships a systemd
*user* unit leaves a root-owned dangling `.wants` symlink, and that the
current count is zero. Six of the 137 ship such a unit:

```
$ while read p; do
    u=$(dpkg -L "$p" 2>/dev/null | grep 'systemd/user/.*\.\(service\|socket\|target\|timer\)$')
    [ -n "$u" ] && printf '%-28s %s\n' "$p" "$(echo $u)"
  done < "$CENSUS"
emacs-common                 /usr/lib/systemd/user/emacs.service
libkscreen-bin               /usr/lib/systemd/user/plasma-kscreen.service
thunar-data                  /usr/lib/systemd/user/thunar.service
tumbler                      /usr/lib/systemd/user/tumblerd.service
xfconf                       /usr/lib/systemd/user/xfconfd.service
xscreensaver                 /usr/lib/systemd/user/xscreensaver.service

$ systemctl --user list-unit-files emacs.service plasma-kscreen.service \
    thunar.service tumblerd.service xfconfd.service xscreensaver.service
UNIT FILE              STATE    PRESET
emacs.service          disabled enabled
plasma-kscreen.service static   -
thunar.service         static   -
tumblerd.service       static   -
xfconfd.service        static   -
xscreensaver.service   disabled enabled
```

Four are `static` (no `[Install]` section, so nothing can enable them) and
two are `disabled`. `list-unit-files` was the instrument rather than
`show`, because `CLAUDE.md` records that `show` reports a stale
`UnitFileState` until a reload. Confirmed against the links themselves:
none of the `.wants` directories contains an entry for any of the six.
Five other census members ship `/etc/xdg/autostart` entries
(`lxqt-policykit`, `lxqt-powermanagement`, `lxqt-session`, `qlipper`,
`system-config-printer`), but those are package-owned files that dpkg
removes cleanly. The dangling count should therefore still be zero after
Task 3, which is a prediction to check rather than a result.

**`CLAUDE.md`'s dangling-link sweep can report a false positive, and it
does right now.** Run today:

```
$ for f in /etc/systemd/user/*.wants/* /etc/systemd/user/*.upholds/*; do
    [ -e "$f" ] || echo "$f"
  done
/etc/systemd/user/*.upholds/*
```

That line is not a dangling symlink; it is the unexpanded glob. There is
exactly one `.upholds` directory, `sockets.target.upholds/`, and it is
empty, so the pattern matches nothing and the shell leaves the literal
behind for `[ -e ]` to reject. `CLAUDE.md` already describes the empty
directory — for `pipewire.service.wants/` — but predicts the opposite
symptom, "invisible to this loop rather than reported by it". Both are
true, and which one occurs depends on whether any *sibling* of the same
glob expands: `*.wants/*` has non-empty members so the empty
`pipewire.service.wants/` vanishes silently, while `*.upholds/*` has no
non-empty member and so the whole pattern surfaces as a phantom path. The
real dangling count today is **zero**.

## Verdicts

### Keepers — unconditional (9)

Marked manual regardless of any user decision, all for one reason.

| package | reason |
|---|---|
| `libpipewire-0.3-modules` | The 44 modules Debian's `libpipewire-0.3.so` loads from its compiled-in `/usr/lib/x86_64-linux-gnu/pipewire-0.3`. That client library is kept installed by `libfluidsynth3` and `qemu-system-gui`, both outside the census; neither is running, so no in-use check can see the need. |
| `libffado2`, `libroc0.4` | Hard `Depends` of the above. |
| `libconfig++11` | `Depends` of `libffado2`. |
| `libglibmm-2.4-1t64`, `libxml++2.6-2v5` | `Depends` of `libffado2`. |
| `libsigc++-2.0-0v5` | `Depends` of `libglibmm-2.4-1t64`. |
| `libopenfec1`, `libspeexdsp1` | `Depends` of `libroc0.4`. |

### Removals — unconditional (107)

Every one has a recorded reason above; the clusters are the emacs set, the
kitty set, the xfce/thunar set, the LXQt/pcmanfm-qt set, the Qt5 stack,
the GTK2 theme set, the Debian audio residue that Nix replaced, and the
libraries reachable only from those.

```
emacs-bin-common emacs-common emacs-el exo-utils ffmpegthumbnailer
galternatives gnome-accessibility-themes gnome-themes-extra
gtk2-engines-pixbuf install-info kitty-doc kitty-shell-integration
kitty-terminfo libdbusmenu-lxqt0 libdisplay-info2 libei1 libexo-2-0
libexo-common libfcft4t64 libffmpegthumbnailer4v5 libfm-extra4t64
libfm-qt6-15 libfm-qt-l10n libgccjit0 libgtk-layer-shell0 libjs-sphinxdoc
libjs-underscore libkf6idletime6 libkf6screen8 libkf6screendpms8
libkscreen-bin libkscreen-data libldacbt-abr2 liblua5.4-0
liblxqt-globalkeys2 libm17n-0 libmenu-cache3 libmenu-cache-bin libmng1
libotf1 libpolkit-qt6-1-1 libportal1 libpulsedsp libqt5core5t64
libqt5dbus5t64 libqt5gui5t64 libqt5network5t64 libqt5qml5 libqt5qmlmodels5
libqt5quick5 libqt5svg5 libqt5waylandclient5 libqt5waylandcompositor5
libqt5widgets5t64 libqt6svgwidgets6 libstartup-notification0
libthunarx-3-0 libtree-sitter0.22 libtumbler-1-0t64 libutf8proc3
libwebpdecoder3 libwireplumber-0.5-0 libwnck-3-0 libwnck-3-common
libxcb-dpms0 libxcb-screensaver0 libxcb-xinerama0 libxfce4panel-2.0-4
libxfce4ui-2-0 libxfce4ui-common libxfce4util7 libxfce4util-bin
libxfce4util-common libxfce4windowing-0-0 libxfce4windowing-common
libxfconf-0-3 lximage-qt lximage-qt-l10n lxqt-config lxqt-config-l10n
lxqt-menu-data lxqt-policykit lxqt-policykit-l10n lxqt-powermanagement
lxqt-powermanagement-l10n lxqt-qtplugin lxqt-session lxqt-session-l10n
lxqt-sudo lxqt-sudo-l10n lxqt-system-theme lxqt-themes m17n-db
pcmanfm-qt-l10n pnp.ids qlipper qps qt5-gtk-platformtheme
qt6-image-formats-plugins qttranslations5-l10n qtwayland5 thunar-data
tumbler tumbler-common xaw3dg xfconf xsettingsd
```

The arithmetic closes: 107 removals + 21 decision-contingent + 9
unconditional keepers = 137.

One ordering constraint carries into Task 3. `xscreensaver` ships
`/usr/share/fonts/xscreensaver/gallant12x22.ttf` and Nix's `foot` has it
mmapped, so if that decision comes back "remove", terminals and GUI
applications must be closed and reopened **before** the removal. A running
process keeps a deleted font mmapped and looks fine until it is next
launched.

## Decision list for the user

Three questions. Each is a feature, not a package, and the packages listed
are the dependency closure that must be marked manual if the answer is
"keep" — computed with `Recommends` included, because
`APT::AutoRemove::RecommendsImportant` defaults to true here.

**1. Do you want the printer applet and the printer configuration GUI?**

The applet is running right now (pid 3823), started on every login by
`/etc/xdg/autostart/print-applet.desktop` through systemd's XDG autostart
generator. `cupsd` and `cups-browsed` are running as system services and
are **not** in the census — they stay either way, so printing itself is
unaffected by this answer. What is at stake is the tray applet that
notifies about print jobs, the `system-config-printer` GUI for adding and
configuring printers, and its network discovery.

Keep → mark these 14 manual:

```
avahi-utils cups-pk-helper gir1.2-handy-1 gir1.2-notify-0.7
gir1.2-packagekitglib-1.0 gir1.2-polkit-1.0 libhandy-1-0
libpackagekit-glib2-18 python3-cups python3-cupshelpers python3-smbc
system-config-printer system-config-printer-common
system-config-printer-udev
```

(`cups-pk-helper` is the PolicyKit helper for privileged printer
configuration and `python3-smbc` the SMB printer browser; both serve the
GUI rather than the applet, so they can be dropped from the list if only
the applet is wanted.)

**2. Do you want `gvfs-fuse`?**

It exposes GIO mounts — MTP phones, SMB shares, network locations — as
real paths under `/run/user/1000/gvfs`, so that programs which do not
speak GIO can open them. Its daemon is running and the mount point is
currently **empty**: nothing is mounted through it right now. `thunar`
and `pcmanfm-qt` are gone and `lf` is the file manager, so the consumer
that used to make those mounts may be gone too. Note this measures this
moment only — the bridge exists for mounts not yet made.

Keep → mark 1 manual:

```
gvfs-fuse
```

**3. Do you want a screensaver?**

Everything measured says no: there is no `~/.xscreensaver`, no
`xscreensaver` process, its systemd user unit is `disabled`, and this
repository has zero references to it while `hyprlock` and `hypridle`
appear across five files. The only thing keeping `xscreensaver` in the
in-use results is a font that Nix's `foot` has mmapped. The recommendation
is **remove**, and this is on the list only because whether a screensaver
is wanted is not a question a measurement can answer.

Keep → mark these 6 manual:

```
libglu1-mesa libjpeg-turbo-progs libturbojpeg0 xscreensaver
xscreensaver-data xscreensaver-gl
```

(`xscreensaver-gl` and `libjpeg-turbo-progs` are `Recommends` of
`xscreensaver`; `libglu1-mesa` is a hard `Depends` of `xscreensaver-gl`
and `libturbojpeg0` of `libjpeg-turbo-progs`.)

**If all three are "remove"**, 128 packages go and 9 are marked manual.
**If all three are "keep"**, 107 go and 30 are marked manual.

Whichever way they go, the census must be re-derived after the marking and
before the removal — marking changes what is orphaned — and the simulated
plan read in full. That is Task 3's job, and its two `sudo` commands are
the user's to run.
