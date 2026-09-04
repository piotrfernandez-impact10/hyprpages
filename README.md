# hypr-spaces

See what is actually running on your Hyprland desktop, arrange it by dragging,
and get the config written for you.

Hyprland binds every workspace to exactly one monitor. That makes a "space"
spanning two screens impossible to express directly — you end up hand-writing
pairs of workspace rules and hoping the numbering stays straight.
`hypr-spaces` treats a **page** as the unit you actually think in: one keypress
worth of desktop, across every monitor you own.

```
page N  ->  workspace N            on the first monitor
        ->  workspace N + offset   on the second
        ->  workspace N + 2*offset on a third
```

## Status

Early, and honest about it: the command line is tested and stable, the visual
editor currently requires [Omarchy](https://omarchy.org)'s Quickshell-based
shell. Making the editor run on any Hyprland is the next milestone — see
[Roadmap](#roadmap).

## What it does

- **Reads your live desktop** — monitors, pages, every open window
- **Looks inside windows** — terminals report their working directory and the
  command actually running; browsers report their open tabs
- **Draws it to scale** — each monitor at its true proportions and real
  position, each window where it actually sits
- **Writes the config** — workspace pinning and per-app placement rules, in
  either Lua or classic `hyprland.conf` syntax
- **Moves real windows**, not just rules, so an edit has an effect immediately

## Requirements

- Hyprland (any version for the conf output; 0.55+ for the Lua output)
- Python 3.11+
- No Python dependencies

Optional, for richer detail: `kitty` (per-window terminal detail via its
control socket), a Chromium-family browser started with
`--remote-debugging-port` (tab lists).

## Install

```bash
git clone https://github.com/<owner>/hypr-spaces
cd hypr-spaces
./install.sh
```

That symlinks `hypr-spaces` into `~/.local/bin`. There is deliberately no
`pip install`: the tool has no dependencies, and `pip install --user` fails
outright on distributions that mark Python as externally managed (PEP 668).

## Use

```bash
hypr-spaces state            # what is running right now, as JSON
hypr-spaces capture          # adopt the current layout as your configuration
hypr-spaces apply --dry-run  # show the config that would be written
hypr-spaces apply            # write it and reload Hyprland
hypr-spaces page 3           # switch every screen to page 3
```

`apply` writes **only** its own file — `~/.config/hypr/spaces.lua` or
`spaces.conf`. Your own config is never edited. It picks the format from
whether you have a `hyprland.lua`, and tells you the one line to add:

```lua
require("hypr.spaces")                    -- Lua config
```
```conf
source = ~/.config/hypr/spaces.conf       # classic config
```

### Lua vs conf

Both express the same pinning and placement rules. The difference is how pages
switch on every screen at once:

| | Lua | conf |
|---|---|---|
| Page switching | a `workspace.active` hook, so **any** route works — keys, clicking a bar, `SUPER`+scroll | `SUPER`+number bound to `hypr-spaces page N` |

## How window introspection works

Getting "what is running in there" is per-application work, and the awkward
cases shaped the design.

**Terminals are not uniform.** foot, alacritty and ghostty run one process per
window, so the window's PID is enough: walk `/proc` to the deepest foreground
descendant and read its `cwd` and `cmdline`. kitty does not work that way — a
single kitty process owns every OS window and the compositor reports that same
PID for all of them, so kitty is queried over its own control socket instead.

**Detection keys on process name, not window class.** A class is whatever the
user chose; `kitty --class notes` is still kitty. Matching on the class misses
it — and the same applies to icons, which resolve through `StartupWMClass`
first and fall back to the process.

**Browser tabs come from the DevTools protocol**, so they are only available
when the browser was started with `--remote-debugging-port`. "No tabs" and
"cannot see tabs" are kept distinct rather than flattened to an empty list.

Anything unrecognised degrades to "a window with a class", which is still
enough to place it.

## Roadmap

1. **A standalone editor** so the visual half works on any Hyprland, not only
   under Omarchy's shell
2. **Packaging** — an AUR package, a man page, a desktop entry
3. **Space templates** — rebuild a page from nothing, launching each terminal
   with its directory and command, and the browser with its tabs

## Development

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest
.venv/bin/ruff check . && .venv/bin/ruff format --check .
.venv/bin/mypy hypr_spaces
```

The suite fakes `/proc`, `hyprctl` and the desktop-entry tree, so it runs
anywhere — no compositor needed, which is what lets CI run it on a plain Linux
runner.

The QML has no test harness, so lint it before loading it into a live shell —
a broken overlay can leave an orphaned layer surface behind:

```bash
mkdir -p /tmp/qmlimports && ln -sfn /usr/share/omarchy/shell /tmp/qmlimports/qs
qmllint -I /tmp/qmlimports -I /usr/lib/qt6/qml plugin/kvark.spaces/*.qml
```

## Licence

MIT. See [LICENSE](LICENSE).
