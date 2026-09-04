# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Linked screens are a toggle: pages can move every monitor together, or leave
  each switching on its own.
- Per-app "keep windows together": new windows of an app join the ones already
  open, following the group when it moves.
- Visual editor: the desktop drawn to scale, drag windows between screens with
  a snap preview, right-click to send a window to another page or screen, and a
  `+` on each screen that picks an application to open there.
- Classic `hyprland.conf` output alongside the Lua output, chosen automatically
  from whether a `hyprland.lua` exists.
- `hyprpages page N` switches every screen to one page, which is how the conf
  format expresses what the Lua output does with a `workspace.active` hook.
- Application icons resolved from desktop entries, falling back to the window's
  process when its class is a user invention.
- `--version`.

### Fixed
- The editor's Apply never reached the CLI: stdin was written before the
  process started, so `apply --stdin` blocked on a pipe that was never written.
- "Keep windows together" matched nothing for any hyphenated class
  (`google-chrome`, `code-oss`, ...) — `-` is ordinary in a regex but a lazy
  quantifier in a Lua pattern, and was not being escaped.
- Grouping an app no longer pins it to a page as a side effect.
- Toggling float on an app that already had a rule did nothing.
- A refresh silently discarded unsaved edits while still reporting them unsaved.
- A group whose window went to a special workspace dragged every later window
  into the scratchpad; a closed group kept a stale home.
- `capture` inferred monitor order from physical position while `state` inferred
  it from live workspaces; the two could disagree and mirror the layout.
- Generated Lua used Omarchy's `o.window` helper, so it would not load on a
  plain Hyprland. It now uses `hl.window_rule` only.
- `install.sh` used `pip install --user`, which fails outright under PEP 668.
- A missing `hyprctl` produced a traceback instead of a sentence.
- `apply` wrote a file that nothing loaded, without saying so.
