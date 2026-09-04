# Contributing

## Getting set up

```bash
python -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest
```

The test suite fakes `/proc`, `hyprctl` and the desktop-entry tree, so it runs
without a compositor. Please keep it that way — a test that needs a live
Hyprland cannot run in CI and will rot.

## Before opening a pull request

```bash
.venv/bin/ruff check . && .venv/bin/ruff format --check .
.venv/bin/mypy hypr_spaces
.venv/bin/pytest
```

## Where things live

| Path | What it is |
|---|---|
| `hypr_spaces/` | The CLI. All introspection and config writing lives here so it is testable. |
| `plugin/kvark.spaces/` | The QML editor. Pure UI: it shells out to the CLI. |
| `bin/hypr-spaces` | Entry point, so the repo runs without installation. |

## Working on the QML

There is no test harness for QML, and a broken overlay can leave an orphaned
layer surface that wedges the compositor's screencopy. Lint before loading:

```bash
mkdir -p /tmp/qmlimports && ln -sfn /usr/share/omarchy/shell /tmp/qmlimports/qs
qmllint -I /tmp/qmlimports -I /usr/lib/qt6/qml plugin/kvark.spaces/*.qml
```

Two traps worth knowing:

- `qs.*` imports resolve for a plugin's **entry point** but not for the files it
  imports. A helper component must take style values as properties.
- Repeater delegates are parented to their enclosing item, so every screen and
  every window is a sibling. `z` set *inside* a screen cannot lift anything
  above a window.

## Style

Comments should explain what is not obvious from the code — a constraint, a
trap, why an approach was rejected. Restating the line above adds nothing.
