"""Command line entry point. The QML overlay is pure UI and talks to this.

Keeping the logic here rather than in QML means /proc walking, socket work and
config writing stay testable from a terminal, and the tool still does something
useful without the shell running.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__, capture, desktop, hypr
from .model import App, SpacesConfig, class_to_pattern


def infer_monitor_order(monitors: list[dict], offset: int) -> list[str]:
    """Work out which monitor holds which band of workspace numbers.

    Physical left-to-right order is the obvious guess and it is wrong: a
    desktop may already pin 1-10 to the right-hand screen. So read the live
    workspaces instead and let each monitor vote, from the band its workspace
    ids fall into. Monitors with no open workspace keep their physical order at
    the end, which is the only signal available for them.
    """
    votes: dict[str, dict[int, int]] = {m["name"]: {} for m in monitors}
    for workspace in hypr.query("workspaces") or []:
        name, monitor = workspace.get("id"), workspace.get("monitor")
        if not isinstance(name, int) or name < 1 or monitor not in votes:
            continue
        band = (name - 1) // offset
        votes[monitor][band] = votes[monitor].get(band, 0) + 1

    placed: dict[int, str] = {}
    unplaced: list[str] = []
    for monitor in monitors:
        tally = votes[monitor["name"]]
        if not tally:
            unplaced.append(monitor["name"])
            continue
        band = max(tally, key=lambda key: tally[key])
        placed.setdefault(band, monitor["name"])

    order: list[str] = []
    for band in range(len(monitors)):
        if band in placed:
            order.append(placed[band])
        elif unplaced:
            order.append(unplaced.pop(0))
    return order + unplaced


def build_state() -> dict:
    """Everything the editor needs to draw the current desktop."""
    monitors = hypr.monitors()
    cfg = SpacesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(monitors, cfg.offset)

    kitty_cache = capture.kitty_windows()
    tabs = capture.browser_tabs()

    by_id = {m["id"]: m for m in monitors}

    windows = []
    for client in hypr.query("clients") or []:
        described = capture.describe(client, kitty_cache, tabs)
        # The monitor a window is on right now, which is not necessarily the
        # one its page pins it to - the editor draws the former and edits the
        # latter.
        on = by_id.get(described.pop("monitorId", -1))
        described["onMonitor"] = on["name"] if on else ""
        workspace = described["workspace"]
        placement = cfg.page_of(int(workspace)) if workspace.isdigit() else None
        described["page"] = placement[0] if placement else None
        described["monitor"] = placement[1] if placement else None
        windows.append(described)

    return {
        "monitors": monitors,
        "config": json.loads(json.dumps(cfg, default=lambda o: o.__dict__)),
        "windows": windows,
        "tabsAvailable": tabs is not None,
    }


def cmd_state(_args) -> int:
    json.dump(build_state(), sys.stdout, indent=2)
    print()
    return 0


def cmd_capture(_args) -> int:
    """Turn the current desktop into config: every window becomes a rule."""
    state = build_state()
    cfg = SpacesConfig.load()
    if not cfg.monitors:
        # The same inference build_state used. Falling back to physical
        # left-to-right order here instead would mirror the layout whenever the
        # desktop pins its first band to the right-hand screen.
        cfg.monitors = infer_monitor_order(state["monitors"], cfg.offset)

    seen: set[str] = set()
    apps: list[App] = []
    for window in state["windows"]:
        cls = window["class"]
        if not cls or cls in seen or window["page"] is None:
            continue
        seen.add(cls)
        apps.append(
            App(
                pattern=class_to_pattern(cls),
                page=window["page"],
                monitor=window["monitor"],
                float=window["floating"],
                size=" ".join(str(int(n)) for n in window["size"]) if window["floating"] else "",
                label=cls,
            )
        )
    cfg.apps = apps
    cfg.save()
    print(f"captured {len(apps)} apps across {len(state['monitors'])} monitors")
    return 0


def cmd_move(args) -> int:
    """Move the live windows of a class to a page, and record the rule.

    Editing the rule alone changes nothing the user can see: a placement rule
    only takes effect when a window next opens. Dragging a window in the editor
    has to move the real window too, or the gesture appears to do nothing.
    """
    cfg = SpacesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    workspace = cfg.workspace_for(args.page, args.monitor)
    if workspace is None:
        print(f"no workspace for page {args.page} on {args.monitor}", file=sys.stderr)
        return 1

    moved = 0
    for client in hypr.query("clients") or []:
        cls = client.get("initialClass") or client.get("class") or ""
        if cls != args.window_class:
            continue
        if client.get("workspace", {}).get("name") == str(workspace):
            continue  # already there
        hypr.move_to_workspace(client["address"], workspace)
        moved += 1

    print(f"moved {moved} window(s) of {args.window_class} to workspace {workspace}")
    return 0


def cmd_focus(args) -> int:
    """Make a page's workspace on one screen the focused one.

    Used before opening an application launcher: whatever is started next opens
    on the focused workspace, so this is how "add something here" is expressed
    without the launcher having to know anything about pages.
    """
    cfg = SpacesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    workspace = cfg.workspace_for(args.page, args.monitor)
    if workspace is None:
        print(f"no workspace for page {args.page} on {args.monitor}", file=sys.stderr)
        return 1

    hypr.focus_workspace(args.monitor, workspace)
    print(f"focused workspace {workspace} on {args.monitor}")
    return 0


def cmd_page(args) -> int:
    """Switch every screen to the same page.

    What the Lua config does with a workspace.active hook, expressed as a
    command so the conf format can bind it to a key. Focus is restored to the
    screen it started on, so changing page does not move the cursor's screen.
    """
    cfg = SpacesConfig.load()
    monitors = hypr.monitors()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(monitors, cfg.offset)

    focused = next((m["name"] for m in monitors if m.get("focused")), "")

    for monitor in cfg.monitors:
        workspace = cfg.workspace_for(args.page, monitor)
        if workspace is not None:
            hypr.focus_workspace(monitor, workspace)

    if focused:
        hypr.focus_monitor(focused)
    return 0


def cmd_apps(_args) -> int:
    """The launchable applications, for the editor's picker."""
    json.dump(desktop.applications(), sys.stdout)
    print()
    return 0


def cmd_launch(args) -> int:
    """Start an application on a given page and screen.

    Focus first, then launch: a new window opens on the focused workspace, so
    this needs no cooperation from the application or from Hyprland rules.
    Launched through uwsm-app so it joins the session scope like anything
    started from Omarchy's own launcher.
    """
    cfg = SpacesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    workspace = cfg.workspace_for(args.page, args.monitor)
    if workspace is None:
        print(f"no workspace for page {args.page} on {args.monitor}", file=sys.stderr)
        return 1

    hypr.focus_workspace(args.monitor, workspace)
    entry = args.desktop_id.removesuffix(".desktop")

    launcher = _launch_command(entry)
    if launcher is None:
        print("no way to launch desktop entries: install gtk-launch or gio", file=sys.stderr)
        return 1

    subprocess.Popen(
        launcher,
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"launched {entry} on workspace {workspace}")
    return 0


def _launch_command(entry: str) -> list[str] | None:
    """How to start a desktop entry on this system.

    uwsm is used when present so the app joins the session scope, as it would
    if started from the compositor's own launcher, but it is a session manager
    some setups do not run - so it must not be a hard requirement.
    """
    base: list[str] | None = None
    if shutil.which("gtk-launch"):
        base = ["gtk-launch", entry]
    elif shutil.which("gio"):
        base = ["gio", "launch", f"/usr/share/applications/{entry}.desktop"]
    if base is None:
        return None
    if shutil.which("uwsm-app"):
        return ["uwsm-app", "--", *base]
    return base


def cmd_apply(args) -> int:
    from .model import detect_format, output_path

    fmt = args.format or detect_format()

    if args.stdin:
        # The editor hands back the whole configuration in one call rather
        # than a flag per change, so an edit session is atomic: either the new
        # layout is saved and applied, or nothing is touched.
        cfg = SpacesConfig.from_dict(json.load(sys.stdin))
        cfg.save()
    else:
        cfg = SpacesConfig.load()

    if not cfg.monitors:
        # A first run has nothing saved yet; without this, apply would happily
        # generate a config with no monitors in it and report success.
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    rendered = cfg.render(fmt)
    if args.dry_run:
        print(rendered)
        return 0

    destination = output_path(fmt)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(rendered)
    print(f"wrote {destination}")

    _warn_if_not_loaded(destination, fmt)

    hypr.reload()
    errors = hypr.config_errors()
    if errors:
        print("hyprctl configerrors:\n" + errors, file=sys.stderr)
        return 1
    print("reloaded, no config errors")
    return 0


def _warn_if_not_loaded(destination: Path, fmt: str) -> None:
    """Point out that the generated file is not read by anything yet.

    Writing it changes nothing on its own, and silently doing nothing is the
    single most confusing thing this tool could do.
    """
    from .model import config_dir

    if fmt == "lua":
        entry = config_dir() / "hypr" / "hyprland.lua"
        needle = instruction = 'require("hypr.spaces")'
    else:
        entry = config_dir() / "hypr" / "hyprland.conf"
        needle = "spaces.conf"
        instruction = "source = ~/.config/hypr/spaces.conf"

    try:
        if needle in entry.read_text():
            return
    except OSError:
        pass

    print(
        f"note: nothing loads {destination} yet.\n      add   {instruction}   to {entry}",
        file=sys.stderr,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="hypr-spaces",
        description="Visual editor for Hyprland spaces: see what is running, "
        "arrange it, and generate the config.",
    )
    parser.add_argument("--version", action="version", version=f"hypr-spaces {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("state", help="print the current desktop as JSON").set_defaults(func=cmd_state)
    sub.add_parser("capture", help="save the current layout as the configuration").set_defaults(
        func=cmd_capture
    )

    move_parser = sub.add_parser("move", help="move a class's live windows to a page")
    move_parser.add_argument("window_class", help="exact window class to move")
    move_parser.add_argument("--page", type=int, required=True)
    move_parser.add_argument("--monitor", required=True)
    move_parser.set_defaults(func=cmd_move)

    sub.add_parser("apps", help="list launchable applications as JSON").set_defaults(func=cmd_apps)

    launch_parser = sub.add_parser("launch", help="start an app on a page and screen")
    launch_parser.add_argument("desktop_id", help="desktop entry id, e.g. spotify.desktop")
    launch_parser.add_argument("--page", type=int, required=True)
    launch_parser.add_argument("--monitor", required=True)
    launch_parser.set_defaults(func=cmd_launch)

    page_parser = sub.add_parser("page", help="switch every screen to one page")
    page_parser.add_argument("page", type=int)
    page_parser.set_defaults(func=cmd_page)

    focus_parser = sub.add_parser("focus", help="focus a page's workspace on one screen")
    focus_parser.add_argument("--page", type=int, required=True)
    focus_parser.add_argument("--monitor", required=True)
    focus_parser.set_defaults(func=cmd_focus)

    apply_parser = sub.add_parser("apply", help="write spaces.lua and reload Hyprland")
    apply_parser.add_argument(
        "--dry-run", action="store_true", help="print the Lua instead of writing it"
    )
    apply_parser.add_argument(
        "--format",
        choices=["lua", "conf"],
        help="output format (default: lua when hyprland.lua exists, else conf)",
    )
    apply_parser.add_argument(
        "--stdin",
        action="store_true",
        help="read the configuration as JSON on stdin and save it before applying",
    )
    apply_parser.set_defaults(func=cmd_apply)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except hypr.HyprError as exc:
        print(f"hyprctl error: {exc}", file=sys.stderr)
        return 1
    except FileNotFoundError:
        print("hyprctl not found - is Hyprland running?", file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 0  # piped into head, and that is not an error


if __name__ == "__main__":
    raise SystemExit(main())
