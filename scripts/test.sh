#!/usr/bin/env bash
# Validates the plugin and runs its tests: manifest validation, qmllint
# (syntax), the Model.js tests under qmltestrunner, and the history.py
# tests. Nothing here touches the network, the running shell, or the real
# listening history.
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_root"

qt_bin=/usr/lib/qt6/bin
shell_dir=/usr/share/omarchy/shell
for tool in "$qt_bin/qmllint" "$qt_bin/qmltestrunner"; do
  [[ -x $tool ]] || { echo "test.sh: missing $tool (qt6-declarative)" >&2; exit 1; }
done
for command_name in omarchy python3 sqlite3; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "test.sh: missing $command_name" >&2; exit 1; }
done

omarchy plugin validate .

# The shell's modules are imported as qs.Commons / qs.Ui; qmllint only
# resolves them from a directory named qs, so point one at the shell.
imports=$(mktemp -d)
trap 'rm -rf "$imports"' EXIT
ln -s "$shell_dir" "$imports/qs"
"$qt_bin/qmllint" -I "$imports" ./*.js ./*.qml

QT_QPA_PLATFORM=offscreen "$qt_bin/qmltestrunner" -input tests -import . -o -,txt

PYTHONDONTWRITEBYTECODE=1 python3 tests/test_history.py

bash -n claude-skill/bin/dr-lyd.sh

echo "All validation and tests passed."
