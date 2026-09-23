#!/usr/bin/env bash
# Everything RUNBOOK.md asks for after Gate A, in one command: Stages B, C and
# D, with Gates B, C and E run where the runbook puts them. Gate D needs a
# graphical login, so it is printed at the end rather than run.
#
# Run it as <user>, from anywhere, on the machine being bootstrapped:
#
#   bash after-gate-a.sh [--host <host>] [--from <step>] [--list]
#
# It has to work BEFORE the clone exists, because the clone is one of its
# steps, so it is a plain file rather than a template rendered into
# .#calangoBootstrap. Fetch it with
#
#   curl -fsSLO https://raw.githubusercontent.com/calangotechbv/calango-nix/main/bootstrap/after-gate-a.sh
#
# or copy it from a machine that already has the clone.
#
# EVERY LINE MIRRORED FROM THE RUNBOOK CARRIES THE RUNBOOK'S TEXT ABOVE IT AS A
# `#= ` LINE, exactly as test/vm/steps/*.txt do, and checks.vm-step-lines-verbatim
# reads this file too. So a runbook edit that this script does not follow fails
# `nix flake check`, rather than this script going on doing the old thing. The
# #= lines are at column 0 even inside indented blocks, because that check's
# sed anchors on it.
#
# RESUMABLE, and that is a correctness property rather than a convenience.
# Stage C installs two apt sources that must be deleted once their vendor
# packages write their own; running that install a second time, after the
# vendor copies exist, re-creates the Signed-By collision that makes apt refuse
# to read any source at all. So each step runs once, a marker under $state
# records it, and a second run resumes after the last completed step. --from
# <step> forgets that step and everything after it; --list names them.
set -euo pipefail

repo=~/Projects/calango-nix
state=${XDG_STATE_HOME:-$HOME/.local/state}/calango-bootstrap
user=$(id -un)
host=$(hostname)
from=""

steps=(
  nix-conf clone host-files flake-host build gate-b
  apt-sources corp-packages transient-sources corp-groups slack
  metapackage greetd gate-c activate gate-e
)

usage() {
  sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case $1 in
    --host) host=${2:?--host needs a value}; shift 2 ;;
    --from) from=${2:?--from needs a step name}; shift 2 ;;
    --list) printf '%s\n' "${steps[@]}"; exit 0 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 >&2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mSTOP: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$user" != root ] || die "run this as <user>, not root: Stage C elevates with sudo itself."

mkdir -p "$state"
if [ -n "$from" ]; then
  known=0
  for s in "${steps[@]}"; do
    if [ "$s" = "$from" ]; then known=1; fi
    if [ "$known" = 1 ]; then rm -f "$state/$s"; fi
  done
  [ "$known" = 1 ] || die "no step named '$from'. --list names them."
fi

# True when the step still has to run. The marker is written only after the
# step's body returns, and under errexit a failing body never returns.
todo() {
  if [ -e "$state/$1" ]; then
    echo "   (done already: $1)"
    return 1
  fi
  say "$1"
}
done_() { touch "$state/$1"; }

# Gate A, re-asked rather than assumed. Every later step depends on it, and a
# machine that has not passed it fails much further on, with a message about
# something else. Group membership is read from the group database, not this
# session, exactly as the runbook's gate does.
say "Gate A (re-checked)"
systemctl is-active --quiet nix-daemon.service \
  || die "nix-daemon.service is not active. Gate A has not passed."
for g in nix-users video input sudo; do
  id -nG "$user" | tr ' ' '\n' | grep -qx "$g" \
    || die "$user is not in group $g. Gate A has not passed."
done
echo "   nix-daemon active; $user holds nix-users video input sudo"

# ---------------------------------------------------------------------------
# Stage B
# ---------------------------------------------------------------------------

if todo nix-conf; then
  # The runbook writes this file with `>`. A machine that already has one
  # keeps it, as long as it already enables flakes.
  if [ ! -e ~/.config/nix/nix.conf ]; then
#= mkdir -p ~/.config/nix
#= printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
    mkdir -p ~/.config/nix
    printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
  elif ! grep -q '^experimental-features.*flakes' ~/.config/nix/nix.conf; then
    die "~/.config/nix/nix.conf exists and does not enable flakes. Add
  experimental-features = nix-command flakes
to it by hand, then run this again."
  fi
  done_ nix-conf
fi

if todo clone; then
  if [ -d "$repo/.git" ]; then
    echo "   $repo already exists; using it as it is, at $(git -C "$repo" log --oneline -1)"
  else
#= GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote https://github.com/calangotechbv/calango-nix.git HEAD
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote https://github.com/calangotechbv/calango-nix.git HEAD \
      || die "the repository is not anonymously readable. RUNBOOK.md Stage B explains the token."
#= git clone https://github.com/calangotechbv/calango-nix.git ~/Projects/calango-nix
    git clone https://github.com/calangotechbv/calango-nix.git ~/Projects/calango-nix
  fi
  done_ clone
fi

cd "$repo"

if todo host-files; then
  if [ ! -e "hypr/hosts/$host.lua" ]; then
#= cp hypr/hosts/suffer.lua hypr/hosts/<host>.lua
    cp hypr/hosts/suffer.lua "hypr/hosts/$host.lua"
    # "then edit the outputs" is a judgement about this machine's monitors,
    # not something to guess. Show what the kernel sees, and hand over.
    echo
    echo "   hypr/hosts/$host.lua is a copy of suffer's. It names eDP-1 and"
    echo "   HDMI-A-1; edit output=, primary= and secondary= for this machine."
    echo "   Connected outputs, by the names Hyprland uses:"
    for s in /sys/class/drm/card*-*/status; do
      if [ "$(cat "$s")" = connected ]; then
        echo "     $(basename "$(dirname "$s")" | sed 's/^card[0-9]*-//')"
      fi
    done
    if [ -t 0 ]; then
      read -rp "   Press Enter to open it in an editor... " _
      ${VISUAL:-${EDITOR:-sensible-editor}} "hypr/hosts/$host.lua"
    else
      die "no terminal to edit hypr/hosts/$host.lua in. Edit it, then run this again."
    fi
  fi
  # Optional in the runbook, and harmless: both files are comments or
  # defaults unless edited.
#= cp foot/hosts/suffer.ini foot/hosts/<host>.ini
#= cp gtk/hosts/suffer.conf gtk/hosts/<host>.conf
  [ -e "foot/hosts/$host.ini" ] || cp foot/hosts/suffer.ini "foot/hosts/$host.ini"
  [ -e "gtk/hosts/$host.conf" ] || cp gtk/hosts/suffer.conf "gtk/hosts/$host.conf"
  done_ host-files
fi

if todo flake-host; then
  # The runbook shows this as a nix snippet to add by hand, so there is no #=
  # line for it. The sed is test/vm/steps/10-stage-b.txt's, which is the edit
  # the qemu rehearsal has already proven.
  if grep -qF "\"$user@$host\" = " flake.nix; then
    echo "   flake.nix already has $user@$host"
  else
    sed -i "s|^      suffer = mkHome \"isutton\" \"suffer\";|&\n      $host = mkHome \"$user\" \"$host\";|" flake.nix
    sed -i "s|^        \"isutton@suffer\" = suffer;|&\n        \"$user@$host\" = $host;|" flake.nix
    grep -qF "\"$user@$host\" = $host;" flake.nix \
      || die "flake.nix no longer has the suffer lines this edit anchors on. Add the host by hand, as RUNBOOK.md Stage B shows."
    grep -n "$host" flake.nix
  fi
  done_ flake-host
fi

if todo build; then
#= sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap'
#= sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb'
#= sg nix-users -c 'nix build --no-link --print-out-paths \
  sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap'
  sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb'
  sg nix-users -c "nix build --no-link --print-out-paths .#homeConfigurations.\"$user@$host\".activationPackage"
  done_ build
fi

if todo gate-b; then
  # Count the checks; do not compare against a number written down anywhere.
  # So this prints the count and stops on a failed check, which `nix flake
  # check` reports through its own exit status -- hence no pipe here.
#= sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
  sg nix-users -c 'nix flake check' 2>&1 | tee "$state/flake-check.log" >/dev/null \
    || { tail -30 "$state/flake-check.log" >&2; die "nix flake check failed. Full log: $state/flake-check.log"; }
  grep -o 'running [0-9]* flake checks' "$state/flake-check.log" || true
#= B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
#= find "$B" -type f | sort
#= ./test/apt-sources.sh "$B"
  B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
  find "$B" -type f | sort
  ./test/apt-sources.sh "$B"
  done_ gate-b
fi

# ---------------------------------------------------------------------------
# Stage C
# ---------------------------------------------------------------------------

# Re-derived, because a resumed run starts here with no $B.
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')

# One password prompt for the whole stage, kept warm while apt works. The loop
# exits with this script.
say "sudo"
sudo -v
while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done &

if todo apt-sources; then
#= sudo install -Dm644 -t /etc/apt/sources.list.d/ "$B"/etc/apt/sources.list.d/*.sources
#= sudo apt update
  sudo install -Dm644 -t /etc/apt/sources.list.d/ "$B"/etc/apt/sources.list.d/*.sources
  sudo apt update
  done_ apt-sources
fi

if todo corp-packages; then
  # The preseed first, or code's postinst stops the install on a debconf
  # question. RUNBOOK.md Stage C explains why `false` is the right answer.
#= echo 'code code/add-microsoft-repo boolean false' | sudo debconf-set-selections
  echo 'code code/add-microsoft-repo boolean false' | sudo debconf-set-selections
  # -y is the one departure from the runbook's line, and the only one a
  # script needs: apt's own [Y/n] is not a decision this stage leaves open.
#= sudo apt install 1password 1password-cli code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin endpoint-verification google-chrome-stable
  sudo apt install -y 1password 1password-cli code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin endpoint-verification google-chrome-stable
  done_ corp-packages
fi

if todo transient-sources; then
  # Before ANY other apt command. Not tidying: see the file header.
#= cd /etc/apt/sources.list.d && sudo rm -f calango-bootstrap-1password.sources calango-bootstrap-google-chrome.sources && cd -
#= sudo apt update
  cd /etc/apt/sources.list.d && sudo rm -f calango-bootstrap-1password.sources calango-bootstrap-google-chrome.sources && cd -
  sudo apt update
  done_ transient-sources
fi

if todo corp-groups; then
#= sudo usermod -aG docker <user>
  sudo usermod -aG docker "$user"
  done_ corp-groups
fi

if todo slack; then
  # Into a scratch directory rather than the clone, which the runbook's bare
  # `curl -O` would otherwise leave a .deb in.
  t=$(mktemp -d)
  (
    cd "$t"
    V=$(curl -sS 'https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb' \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    [ -n "$V" ] || die "Slack's feed returned no version."
    echo "   slack $V"
#= curl -fsSLO "https://downloads.slack-edge.com/desktop-releases/linux/x64/$V/slack-desktop-$V-amd64.deb"
#= sudo apt install ./slack-desktop-"$V"-amd64.deb
    curl -fsSLO "https://downloads.slack-edge.com/desktop-releases/linux/x64/$V/slack-desktop-$V-amd64.deb"
    sudo apt install -y ./slack-desktop-"$V"-amd64.deb
  )
  rm -rf "$t"
  done_ slack
fi

if todo metapackage; then
#= D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
#= sudo apt install "$D"/calango-desktop_*.deb
  D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
  sudo apt install -y "$D"/calango-desktop_*.deb
  done_ metapackage
fi

if todo greetd; then
  # The one file that can leave the machine unable to reach a desktop. A
  # machine that already has one gets the difference shown before it goes.
  if [ -e /etc/greetd/config.toml ] && ! cmp -s /etc/greetd/config.toml "$B/etc/greetd/config.toml"; then
    diff /etc/greetd/config.toml "$B/etc/greetd/config.toml" || true
  fi
#= sudo install -Dm644 "$B/etc/greetd/config.toml" /etc/greetd/config.toml
#= sudo systemctl enable greetd.service
  sudo install -Dm644 "$B/etc/greetd/config.toml" /etc/greetd/config.toml
  sudo systemctl enable greetd.service
  done_ greetd
fi

if todo gate-c; then
  # Separate commands, each checked for its answer. Never chained: line 2's
  # grep -c prints 0 and exits 1 on the passing case.
  fail=0
  want() { if [ "$2" = "$3" ]; then echo "   ok    $1"; else echo "   FAIL  $1: got '$2', want '$3'" >&2; fail=1; fi; }
#= dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' calango-desktop
  want calango-desktop "$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' calango-desktop | tr -s ' ')" "ii calango-desktop"
#= apt-get -s autoremove | grep -c '^Remv '
  want autoremove "$(apt-get -s autoremove | grep -c '^Remv ' || true)" 0
#= test -f /usr/share/wayland-sessions/hyprland-nix.desktop && echo present
  want session-entry "$(test -f /usr/share/wayland-sessions/hyprland-nix.desktop && echo present || true)" present
#= cmp -s /etc/greetd/config.toml "$B/etc/greetd/config.toml" && echo greetd-ok
  want greetd "$(cmp -s /etc/greetd/config.toml "$B/etc/greetd/config.toml" && echo greetd-ok || true)" greetd-ok
#= id -nG <user> | tr ' ' '\n' | grep -cx -e docker
  want docker-group "$(id -nG "$user" | tr ' ' '\n' | grep -cx -e docker || true)" 1
  [ "$fail" = 0 ] || die "Gate C did not answer as shown. Do not reboot into greetd until it does."
  done_ gate-c
fi

# ---------------------------------------------------------------------------
# Stage D
# ---------------------------------------------------------------------------

if todo activate; then
  # Through sg, and not optional: activate's first daemon call is silenced,
  # so a shell without nix-users dies there with no message at all.
#= p=$(sg nix-users -c 'nix build --no-link --print-out-paths \
#= sg nix-users -c "$p/activate"
  p=$(sg nix-users -c "nix build --no-link --print-out-paths .#homeConfigurations.\"$user@$host\".activationPackage")
  sg nix-users -c "$p/activate"
#= test -x ~/.nix-profile/bin/uwsm && echo uwsm-present
  test -x ~/.nix-profile/bin/uwsm && echo uwsm-present || die "activate ran and ~/.nix-profile/bin/uwsm is not there."
  done_ activate
fi

if todo gate-e; then
  # The gate is the OUTPUT: dpkg -V exits 0 whether or not it finds anything.
#= dpkg -V calango-desktop
  bad=$(dpkg -V calango-desktop 2>&1 || true)
  [ -z "$bad" ] || die "dpkg -V calango-desktop reports edited files:
$bad"
  echo "   ok    dpkg -V calango-desktop printed nothing"
  done_ gate-e
fi

cat <<EOF

Done through Stage D. What is left needs a person:

  1. Log out, and select Hyprland (Nix) in tuigreet. Then Gate D, from a
     terminal in that session:

       test -x ~/.nix-profile/bin/uwsm && echo uwsm-present
       loginctl show-session "\$XDG_SESSION_ID" -p Type --value      # wayland
       tr '\0' '\n' < /proc/\$(pgrep -x .Hyprland-wrapp)/environ \\
         | grep -c LIBGL_DRIVERS_PATH                               # 1

  2. Stage E, deliberately not scripted: corporate enrolment for
     endpoint-verification, re-pairing syncthing, and \`ufw allow
     calango-syncthing\` if you want the rule.

  3. The clone's remote is https. Switch it to ssh once 1Password's agent
     holds your key, if this machine will push.

  4. $repo/flake.nix and hypr/hosts/$host.lua are edited and uncommitted.
EOF
