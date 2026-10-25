#!/bin/zsh
# Build nnote into build/nnote. `zsh build.sh install` also copies it to ~/.local/bin.
set -euo pipefail
root=${0:A:h}
# Without Xcode, ld warns about Xcode-only search paths; those warnings are noise.
swift build --package-path "$root" -c release --product nnote 2>&1 \
  | grep -vE '^(Building|Build complete|\[[0-9]+/[0-9]+\])|search path .*CommandLineTools/Developer.* not found' || true
bin="$(swift build --package-path "$root" -c release --show-bin-path)/nnote"
[[ -x "$bin" ]] || { echo "build failed" >&2; exit 1; }
mkdir -p "$root/build"
cp "$bin" "$root/build/nnote"
echo "built $root/build/nnote"
if [[ "${1:-}" == install ]]; then
  install -m 755 "$root/build/nnote" "$HOME/.local/bin/nnote"
  echo "installed $HOME/.local/bin/nnote"
fi
