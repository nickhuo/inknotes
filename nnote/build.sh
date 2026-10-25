#!/bin/zsh
# Build nnote next to this script.
set -euo pipefail
here=${0:A:h}
clang -fobjc-arc -Wall -Wno-undeclared-selector -O2 \
  -framework Foundation -framework CoreData -framework AppKit -framework PencilKit \
  -o "$here/nnote" "$here/nnote.m" "$here/svg.m"
echo "built $here/nnote"
