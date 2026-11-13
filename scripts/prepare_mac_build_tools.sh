#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
if ! command -v brew >/dev/null 2>&1; then
    echo '::error::Homebrew is not available on Mac-58. No privileged installation was attempted.'
    exit 1
fi
missing=()
for package in ninja llvm lld libarchive pkg-config meson; do
    if ! brew list --versions "$package" >/dev/null 2>&1; then
        missing+=("$package")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    brew install "${missing[@]}"
fi
for directory in "$(brew --prefix llvm)/bin" "$(brew --prefix lld)/bin"; do
    echo "$directory" >> "$GITHUB_PATH"
done
"$(brew --prefix)/bin/meson" --version
echo 'OpenMinis native build tools are ready.'
