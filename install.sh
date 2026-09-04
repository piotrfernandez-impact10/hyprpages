#!/usr/bin/env bash
# Install the CLI and the Omarchy shell plugin for the current user.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugins="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

echo "Installing the CLI..."
python3 -m pip install --user -e "$repo"

if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy" ]]; then
  echo "Linking the shell plugin into $plugins..."
  mkdir -p "$plugins"
  # Copied, not symlinked: omarchy-plugin-validate rejects symlinks anywhere
  # inside a plugin folder. Re-run this script after pulling.
  rm -rf "$plugins/kvark.spaces"
  cp -r "$repo/plugin/kvark.spaces" "$plugins/kvark.spaces"
  omarchy plugin validate "$plugins/kvark.spaces" || true
  echo
  echo "Add a binding to ~/.config/hypr/bindings.lua:"
  echo '  o.bind("SUPER + SHIFT + S", "Spaces", "omarchy-shell shell toggle kvark.spaces")'
else
  echo "No ~/.config/omarchy found - skipping the shell plugin (CLI only)."
fi
