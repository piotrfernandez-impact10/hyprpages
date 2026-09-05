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
from .model import App, PagesConfig, class_to_pattern


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
    # A mirrored output shows another screen's content at the same coordinates;
    # drawing it as its own screen would stack two rectangles on one spot.
    monitors = [m for m in hypr.monitors() if not m.get("mirrorOf")]
    cfg = PagesConfig.load()
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


def cmd_capture(args) -> int:
    """Fold the running desktop into the configuration.

    Merged, not replaced. Capture can only see what is open, and most of what a
    configuration describes is closed at any moment - so rebuilding from
    scratch quietly deletes the rules for everything that happens not to be
    running. --replace asks for that deliberately.

    A class open on two pages at once cannot be written as one rule, so it is
    reported and left alone rather than pinned to whichever window hyprctl
    listed first. That is the usual state of a terminal, and inventing a rule
    from it drags every terminal to one page ever after.
    """
    state = build_state()
    cfg = PagesConfig.load()
    if not cfg.monitors:
        # The same inference build_state used. Falling back to physical
        # left-to-right order here instead would mirror the layout whenever the
        # desktop pins its first band to the right-hand screen.
        cfg.monitors = infer_monitor_order(state["monitors"], cfg.offset)

    live: dict[str, list[dict]] = {}
    for window in state["windows"]:
        if window["class"] and window["page"] is not None:
            live.setdefault(window["class"], []).append(window)

    kept = [] if args.replace else list(cfg.apps)
    by_pattern = {app.pattern: app for app in kept}

    added: list[str] = []
    updated: list[str] = []
    ambiguous: list[str] = []

    for cls, windows in sorted(live.items()):
        spots = {(w["page"], w["monitor"]) for w in windows}
        if len(spots) > 1:
            pages = ", ".join(str(page) for page, _ in sorted(spots))
            ambiguous.append(f"{cls} (pages {pages})")
            continue

        window = windows[0]
        size = " ".join(str(int(n)) for n in window["size"]) if window["floating"] else ""
        pattern = class_to_pattern(cls)
        app = by_pattern.get(pattern)
        if app is None:
            app = App(pattern=pattern, page=window["page"], monitor=window["monitor"], label=cls)
            by_pattern[pattern] = app
            kept.append(app)
            added.append(cls)
        else:
            was = (app.page, app.monitor, app.float, app.size)
            if was != (window["page"], window["monitor"], window["floating"], size):
                updated.append(cls)
            app.page = window["page"]
            app.monitor = window["monitor"]
        # A pinned app is floating because the rule says so, not because of
        # anything visible yet - reading its live state back would clear the
        # size the moment it was captured before the rule had been applied.
        if not app.pin:
            app.float = window["floating"]
            app.size = size
        # Never touched: `together`, `pin` and `label`, which say what the user
        # meant and cannot be read back off a running window.

    untouched = len(kept) - len(added) - len(updated)
    summary = (
        f"{len(added)} new, {len(updated)} updated, {untouched} unchanged"
        f" - {len(kept)} rules across {len(state['monitors'])} monitors"
    )
    if args.dry_run:
        for app in kept:
            where = f"page {app.page}" + (f" on {app.monitor}" if app.monitor else "")
            print(f"{app.pattern}  ->  {where}")
        print(f"# {summary} (nothing written)")
    else:
        cfg.apps = kept
        cfg.save()
        print(f"captured {summary}")

    for entry in ambiguous:
        print(f"skipped {entry}: open on more than one page, no single rule fits", file=sys.stderr)
    return 0


def cmd_move(args) -> int:
    """Move live windows of a class to a page, and record the rule.

    Editing the rule alone changes nothing the user can see: a placement rule
    only takes effect when a window next opens. Dragging a window in the editor
    has to move the real window too, or the gesture appears to do nothing.

    With --address only that one window moves. Dragging one of three browser
    windows should move the one you dragged; the rule still governs where the
    next one opens, which is the part that applies to the class as a whole.
    """
    cfg = PagesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    workspace = cfg.workspace_for(args.page, args.monitor)
    if workspace is None:
        print(f"no workspace for page {args.page} on {args.monitor}", file=sys.stderr)
        return 1

    moved = 0
    for client in hypr.query("clients") or []:
        if args.address:
            if client.get("address") != args.address:
                continue
        else:
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
    cfg = PagesConfig.load()
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
    cfg = PagesConfig.load()
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


def cmd_close(args) -> int:
    """Close one window.

    A request rather than a kill, so an application with unsaved work can put
    its own dialog up instead of losing it.
    """
    known = any(client.get("address") == args.address for client in (hypr.query("clients") or []))
    if not known:
        print(f"no window with address {args.address}", file=sys.stderr)
        return 1

    hypr.close_window(args.address)
    print(f"asked {args.address} to close")
    return 0


def cmd_apps(_args) -> int:
    """The launchable applications, for the editor's picker."""
    json.dump(desktop.applications(), sys.stdout)
    print()
    return 0


def cmd_launch(args) -> int:
    """Put an application on a page: move the one that is open, or start one.

    Starting is the wrong answer for an application that is already running.
    Most of them are single-instance, so a second launch is answered by raising
    the window they already have - on the workspace it was already on. From the
    editor that looks like nothing happening at all, which is why "add Spotify
    here" moves the Spotify that exists instead.

    An instance already on the target page means "here" is satisfied, so a
    second window is what was actually being asked for. --new forces that.
    """
    cfg = PagesConfig.load()
    if not cfg.monitors:
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    workspace = cfg.workspace_for(args.page, args.monitor)
    if workspace is None:
        print(f"no workspace for page {args.page} on {args.monitor}", file=sys.stderr)
        return 1

    if not args.new:
        existing = _open_elsewhere(args.desktop_id, workspace)
        if existing:
            hypr.move_to_workspace(existing["address"], workspace)
            hypr.focus_workspace(args.monitor, workspace)
            hypr.focus_window(existing["address"])
            cls = existing.get("initialClass") or existing.get("class") or ""
            print(f"moved {cls} to workspace {workspace}")
            return 0

    # Focus first, then launch: a new window opens on the focused workspace, so
    # this needs no cooperation from the application or from Hyprland rules.
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


def _open_elsewhere(desktop_id: str, workspace: int) -> dict | None:
    """A window of this application that is not already on `workspace`.

    None when the application has nothing open, or when it already has a window
    where it was asked to go - in both cases what is wanted is a new one.

    Of several candidates a window whose class names the application outright
    beats one resolved through a fallback, and then the most recently focused
    wins: with three browser windows scattered around, the one being thought of
    is the one last used.
    """
    if not desktop_id:
        return None

    away: list[tuple[bool, int, dict]] = []
    for client in hypr.query("clients") or []:
        cls = client.get("initialClass") or client.get("class") or ""
        # Resolved exactly as the editor resolves it for the same window, so
        # the two can never disagree about what is already open.
        entry, exact = desktop.entry_match(cls, capture.process_name(client.get("pid", 0)))
        if entry != desktop_id:
            continue
        if client.get("workspace", {}).get("name") == str(workspace):
            return None
        # focusHistoryID counts up from 0 at the focused window.
        away.append((not exact, client.get("focusHistoryID", 1 << 30), client))

    return min(away, key=lambda item: item[:2])[2] if away else None


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


SETTINGS = {"live-view": "live_view", "link-screens": "pair_monitors"}


def cmd_set(args) -> int:
    """Change one setting, without touching the generated Hyprland config.

    View preferences must not travel through `apply`: that rewrites the
    generated config and reloads the compositor, which is absurd for a flag
    that never reaches it.
    """
    field = SETTINGS.get(args.name)
    if field is None:
        print(f"unknown setting {args.name}; try: {', '.join(SETTINGS)}", file=sys.stderr)
        return 1

    cfg = PagesConfig.load()
    setattr(cfg, field, args.value.lower() in ("1", "true", "yes", "on"))
    cfg.save()
    print(f"{args.name} = {getattr(cfg, field)}")
    return 0


def cmd_apply(args) -> int:
    from .model import detect_format, output_path

    fmt = args.format or detect_format()

    # The editor hands back the whole configuration in one call rather than a
    # flag per change, so an edit session is atomic: either the new layout is
    # saved and applied, or nothing is touched.
    cfg = PagesConfig.from_dict(json.load(sys.stdin)) if args.stdin else PagesConfig.load()

    if not cfg.monitors:
        # A first run has nothing saved yet; without this, apply would happily
        # generate a config with no monitors in it and report success.
        cfg.monitors = infer_monitor_order(hypr.monitors(), cfg.offset)

    if args.stdin:
        # Saved after the inference, so what is stored matches what was written.
        # Saving first left `monitors: []` on disk beside a config that had
        # them, and the next run re-inferred from whatever was plugged in.
        cfg.save()

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
        needle = instruction = 'require("hypr.hyprpages")'
    else:
        entry = config_dir() / "hypr" / "hyprland.conf"
        needle = "hyprpages.conf"
        instruction = "source = ~/.config/hypr/hyprpages.conf"

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
        prog="hyprpages",
        description="Visual editor for Hyprland spaces: see what is running, "
        "arrange it, and generate the config.",
    )
    parser.add_argument("--version", action="version", version=f"hyprpages {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("state", help="print the current desktop as JSON").set_defaults(func=cmd_state)
    capture_parser = sub.add_parser(
        "capture", help="fold the running windows into the configuration"
    )
    capture_parser.add_argument(
        "--replace",
        action="store_true",
        help="start from nothing, dropping the rules for everything not running",
    )
    capture_parser.add_argument(
        "--dry-run", action="store_true", help="print the rules instead of saving them"
    )
    capture_parser.set_defaults(func=cmd_capture)

    move_parser = sub.add_parser("move", help="move a class's live windows to a page")
    move_parser.add_argument("window_class", help="exact window class to move")
    move_parser.add_argument("--page", type=int, required=True)
    move_parser.add_argument("--monitor", required=True)
    move_parser.add_argument(
        "--address",
        default="",
        help="move only this window (0x...), instead of every window of the class",
    )
    move_parser.set_defaults(func=cmd_move)

    sub.add_parser("apps", help="list launchable applications as JSON").set_defaults(func=cmd_apps)

    launch_parser = sub.add_parser("launch", help="start an app on a page and screen")
    launch_parser.add_argument("desktop_id", help="desktop entry id, e.g. spotify.desktop")
    launch_parser.add_argument("--page", type=int, required=True)
    launch_parser.add_argument("--monitor", required=True)
    launch_parser.add_argument(
        "--new",
        action="store_true",
        help="always start another instance, instead of moving one that is open",
    )
    launch_parser.set_defaults(func=cmd_launch)

    set_parser = sub.add_parser("set", help="change one setting, without reloading Hyprland")
    set_parser.add_argument("name", choices=sorted(SETTINGS))
    set_parser.add_argument("value")
    set_parser.set_defaults(func=cmd_set)

    close_parser = sub.add_parser("close", help="ask one window to close")
    close_parser.add_argument("address", help="window address, e.g. 0x55...")
    close_parser.set_defaults(func=cmd_close)

    page_parser = sub.add_parser("page", help="switch every screen to one page")
    page_parser.add_argument("page", type=int)
    page_parser.set_defaults(func=cmd_page)

    focus_parser = sub.add_parser("focus", help="focus a page's workspace on one screen")
    focus_parser.add_argument("--page", type=int, required=True)
    focus_parser.add_argument("--monitor", required=True)
    focus_parser.set_defaults(func=cmd_focus)

    apply_parser = sub.add_parser("apply", help="write hyprpages.lua and reload Hyprland")
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
