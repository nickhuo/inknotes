#!/bin/zsh
# Build nnote into build/nnote. `zsh build.sh install` also copies it to ~/.local/bin.
set -euo pipefail
root=${0:A:h}
mkdir -p "$root/build"
clang -fobjc-arc -Wall -Wno-undeclared-selector -O2 \
  -framework Foundation -framework CoreData -framework AppKit -framework PencilKit \
  -o "$root/build/nnote" "$root"/src/*.m
echo "built $root/build/nnote"
if [[ "${1:-}" == install ]]; then
  install -m 755 "$root/build/nnote" "$HOME/.local/bin/nnote"
  echo "installed $HOME/.local/bin/nnote"
fi
