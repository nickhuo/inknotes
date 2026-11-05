#!/bin/zsh
# Build inknotes into build/inknotes. `zsh build.sh install` also copies it to ~/.local/bin.
set -euo pipefail
root=${0:A:h}
# Without Xcode, ld warns about Xcode-only search paths; those warnings are noise.
if inknotes_build_output=$(swift build --package-path "$root" -c release --product inknotes 2>&1); then
  inknotes_build_status=0
else
  inknotes_build_status=$?
fi
print -r -- "$inknotes_build_output" \
  | grep -vE '^(Building|Build complete|\[[0-9]+ ?/ ?[0-9]+\])|search path .*CommandLineTools/Developer.* not found' || true
(( inknotes_build_status == 0 )) || exit "$inknotes_build_status"
bin="$(swift build --package-path "$root" -c release --show-bin-path)/inknotes"
[[ -x "$bin" ]] || { echo "build failed" >&2; exit 1; }
mkdir -p "$root/build"
cp "$bin" "$root/build/inknotes"
echo "built $root/build/inknotes"
if [[ "${1:-}" == install ]]; then
  install -m 755 "$root/build/inknotes" "$HOME/.local/bin/inknotes"
  echo "installed $HOME/.local/bin/inknotes"
fi
