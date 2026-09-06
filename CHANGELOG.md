# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Keyboard hints**: every tile carries a letter, always, rather than behind a
  mode you enter first. Press one to take hold of a window, then a page number
  to send it there or an arrow key for the other screen; any other key lets go.
  `v`, `l` and `r` are kept out of the alphabet — they already mean live view,
  link screens and refresh.
- **Drag to swap**: dropping a tile on another window on the same screen trades
  their places. Position inside a screen belongs to the layout, so trading is
  the only rearrangement a tiler offers — a same-screen drag used to do nothing
  at all. Previewed in the slot the window will land in, with a two-headed
  arrow between the two and the partner outlined; it moves live windows and
  records no rule, because no rule can express it.
- `hyprpages swap <address> <address>` behind it.
- Per-app **"keep it on every page"**: the app follows you instead of living on
  one page — a video call, a player, a monitoring window. Hyprland only pins
  floating windows, so the generated rule floats it too rather than emitting a
  rule that quietly does nothing. Works in both output formats.
- **Live view**: each window drawn with its own real content instead of an
  icon, so you recognise the desktop you are editing. `V` toggles it, and with
  it off no capture session exists at all. Works for windows on pages that are
  not currently on screen.
- `hyprpages set <name> <value>` for view preferences, which must not travel
  through `apply` -- that rewrites the generated config and reloads the
  compositor, absurd for a flag that never reaches it.
- `hyprpages launch --new` to start another instance of an application that is
  already open, rather than moving the one that exists.
- Linked screens are a toggle: pages can move every monitor together, or leave
  each switching on its own.
- Per-app "keep windows together": new windows of an app join the ones already
  open, following the group when it moves.
- Visual editor: the desktop drawn to scale, drag windows between screens with
  a snap preview, right-click to send a window to another page or screen, a `+`
  on each screen that picks an application to open there, and a `−` on each
  window that closes it.
- Classic `hyprland.conf` output alongside the Lua output, chosen automatically
  from whether a `hyprland.lua` exists.
- `hyprpages page N` switches every screen to one page, which is how the conf
  format expresses what the Lua output does with a `workspace.active` hook.
- Application icons resolved from desktop entries, falling back to the window's
  process when its class is a user invention.
- `--version`.

### Changed
- One control per thing: `+` belongs to a screen, `−` belongs to a window. The
  `+` inside each window tile is gone -- it only differed in tiling the new
  window beside that one, which a single drag fixes, and it cost a button in
  every tile.

### Fixed
- A newly launched window lands on the page it was asked for. Focusing the
  target workspace is not enough on its own: a placement rule for the same
  application beats the focused workspace, so "add Chrome to page 6" opened a
  new window on whichever page Chrome's own rule named.
- The editor opens on the page you are on. `activePage()` ran before the config
  from the same response had been read, so it fell back to physical
  left-to-right monitor order instead of the configured one — on the first open
  after a shell restart that computed the wrong page and landed on page 1.
- Adding an application that is already open now depends on whether it can have
  more than one window. An entry shipping a "new window" action is saying it
  can, so "add Chrome here" opens another window; a terminal emulator counts
  too, since foot and kitty ship no actions at all. One that is neither cannot,
  so "add Spotify here" still means the Spotify that exists. Chrome's action Exec
  is the bare binary, identical to its main one, and running that again only
  raises the window it already has — so when the action adds nothing, the
  window is asked for explicitly with `--new-window`.
- Picking an application that is already open moved its window to the chosen
  page. It used to launch a second copy, which single-instance applications
  answer by raising the window they already have, on the page it was already
  on -- so the picker appeared to do nothing.
- `capture` merges into the configuration instead of replacing it. It can only
  see open windows, so rebuilding from scratch silently deleted the rules for
  everything that happened to be closed. `--replace` asks for the old
  behaviour, and `--dry-run` shows the result without writing it.
- `capture` no longer invents a rule for a class that is open on several pages
  at once -- the usual state of a terminal, and the rule dragged every terminal
  to one page ever after. It reports them instead.
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
