# hypr-spaces

A visual editor for Hyprland spaces: see what is actually running, arrange it by
hand, and generate the config.

Hyprland binds every workspace to exactly one monitor. That makes a "space" that
spans two screens impossible to express directly — you end up hand-writing pairs
of workspace rules and hoping the numbering stays straight. `hypr-spaces` treats
a **page** as the unit you actually think in: one keypress worth of desktop
across every monitor you own.

    page N  ->  workspace N            on the first monitor
            ->  workspace N + offset   on the second
            ->  workspace N + 2*offset on a third

## Status

Early. The capture and code-generation layers work and are tested; the drag-and-drop
editor is in progress.

## What works today

- **Reads your live desktop** — monitors, pages, and every open window
- **Looks inside windows.** Terminals report their working directory and the
  command actually running; browsers report their open tabs
- **Generates Hyprland Lua** — workspace pinning, per-app placement rules, and an
  optional hook that keeps every monitor on the same page

## Install

Requires Python 3.11+ and Hyprland 0.55+ (the Lua config format).

```bash
git clone https://github.com/<owner>/hypr-spaces
cd hypr-spaces
pip install -e .
```

## Use

```bash
hypr-spaces state            # what is running right now, as JSON
hypr-spaces capture          # adopt the current layout as your configuration
hypr-spaces apply --dry-run  # show the Lua that would be written
hypr-spaces apply            # write ~/.config/hypr/spaces.lua and reload
```

Then load the generated file from your `hyprland.lua`:

```lua
require("hypr.spaces")
```

Nothing is written to your Hyprland config until you run `apply`, and `apply`
only ever writes `spaces.lua` — your own config is never edited.

## How window introspection works

Getting "what is running in there" is per-application work, and the awkward
cases shaped the design.

**Terminals are not uniform.** foot, alacritty and ghostty run one process per
window, so the window's PID is enough: walk `/proc` to the deepest foreground
descendant and read its `cwd` and `cmdline`. kitty does not work that way — a
single kitty process owns every OS window, and the compositor reports that same
PID for all of them, so `/proc` cannot tell two kitty windows apart. kitty is
queried over its own remote-control socket instead.

**Detection is by process name, not window class.** A window class is whatever
the user chose; `kitty --class notes` is still kitty. Matching on the class
misses it.

**Browser tabs come from the DevTools protocol**, which means they are only
available when the browser was started with `--remote-debugging-port`. The
distinction between "no tabs" and "cannot see tabs" is preserved throughout
rather than being flattened to an empty list.

Anything unrecognised degrades to "a window with a class", which is still enough
to place it.

## Development

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest
.venv/bin/ruff check . && .venv/bin/ruff format --check .
.venv/bin/mypy hypr_spaces
```

The test suite fakes `/proc` and `hyprctl`, so it runs anywhere — no compositor
needed, which is what lets CI run it on a plain Linux runner.

## Licence

MIT. See [LICENSE](LICENSE).
