#!/usr/bin/env bash
# Runs a QML file under the flake's own Qt, with no display.
#
#   ./test/run.sh test/title-slot.qml   # exits 0 on PASS, 1 on any failure
#
# Two things here are not optional and both cost a session to find:
#
#   QT_ASSUME_STDERR_HAS_CONSOLE   without it `qml` prints nothing at all and
#                                  still exits 0 -- a passing-looking silence.
#   QML2_IMPORT_PATH               without it every file fails with
#                                  "Did not load any objects, exiting." and,
#                                  again, exit 0.
#
# The Qt comes from the flake's pinned nixpkgs rather than from the registry,
# for the reason CLAUDE.md gives: `nixpkgs#` answers a different question.
set -euo pipefail

cd "$(dirname "$0")/.."

QT=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.qt6.qtdeclarative')
if [ ! -x "$QT/bin/qml" ]; then
  sg nix-users -c "nix build --no-link '.#homeConfigurations.\"isutton@suffer\".pkgs.qt6.qtdeclarative'"
fi

QT_ASSUME_STDERR_HAS_CONSOLE=1 \
QT_LOGGING_RULES='*=true;qt.*=false' \
QML2_IMPORT_PATH="$QT/lib/qt-6/qml" \
QT_QPA_PLATFORM=offscreen \
  "$QT/bin/qml" "$@"
