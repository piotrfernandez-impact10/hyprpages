#!/usr/bin/env bash
# Install hyprpages for the current user.
#
# No pip: the tool has no dependencies, so a symlink onto PATH is enough and
# avoids fighting PEP 668, which makes `pip install --user` fail outright on
# Arch and other distributions that mark Python as externally managed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
bindir="${HOME}/.local/bin"

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v hyprctl >/dev/null || echo "warning: hyprctl not found; is this a Hyprland session?" >&2

mkdir -p "$bindir"
ln -sfn "$repo/bin/hyprpages" "$bindir/hyprpages"
echo "installed $bindir/hyprpages"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on your PATH" >&2 ;;
esac

# The shell plugin is optional: the CLI works on any Hyprland, the editor
# needs Omarchy's Quickshell-based shell.
if [[ -d "$config/omarchy/plugins" ]] || command -v omarchy >/dev/null; then
  plugins="$config/omarchy/plugins"
  mkdir -p "$plugins"
  # Copied, not symlinked: omarchy-plugin-validate rejects symlinks anywhere
  # inside a plugin folder. Re-run this script after pulling.
  rm -rf "$plugins/kvark.hyprpages"
  # git archive rather than cp: the working tree carries a .venv full of
  # symlinks, and omarchy-plugin-validate rejects a symlink anywhere inside a
  # plugin folder.
  mkdir -p "$plugins/kvark.hyprpages"
  git -C "$repo" archive HEAD | tar -x -C "$plugins/kvark.hyprpages"
  echo "installed the Omarchy shell plugin"
  echo
  echo "Enable it and put its button on the bar:"
  echo "  omarchy plugin enable kvark.hyprpages --section left"
else
  echo "no Omarchy install found - CLI only (the visual editor needs it)"
fi

echo
echo "Next:"
echo "  hyprpages capture      # adopt your current layout"
echo "  hyprpages apply        # write the config and reload"
