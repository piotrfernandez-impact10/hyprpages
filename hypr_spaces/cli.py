"""Command line entry point. The QML overlay is pure UI and talks to this.

Keeping the logic here rather than in QML means /proc walking, socket work and
config writing stay testable from a terminal, and the tool still does something
useful without the shell running.
"""

from __future__ import annotations

import argparse
import json
import sys

from . import capture, hypr
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

    windows = []
    for client in hypr.query("clients") or []:
        described = capture.describe(client, kitty_cache, tabs)
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
        cfg.monitors = [m["name"] for m in state["monitors"]]

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


def cmd_apply(args) -> int:
    if args.stdin:
        # The editor hands back the whole configuration in one call rather
        # than a flag per change, so an edit session is atomic: either the new
        # layout is saved and applied, or nothing is touched.
        cfg = SpacesConfig.from_dict(json.load(sys.stdin))
        cfg.save()
    else:
        cfg = SpacesConfig.load()

    lua = cfg.to_lua()
    if args.dry_run:
        print(lua)
        return 0

    from .model import output_path

    destination = output_path()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(lua)
    print(f"wrote {destination}")

    hypr.reload()
    errors = hypr.config_errors()
    if errors:
        print("hyprctl configerrors:\n" + errors, file=sys.stderr)
        return 1
    print("reloaded, no config errors")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="hypr-spaces")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("state", help="print the current desktop as JSON").set_defaults(func=cmd_state)
    sub.add_parser("capture", help="save the current layout as the configuration").set_defaults(
        func=cmd_capture
    )

    apply_parser = sub.add_parser("apply", help="write spaces.lua and reload Hyprland")
    apply_parser.add_argument(
        "--dry-run", action="store_true", help="print the Lua instead of writing it"
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


if __name__ == "__main__":
    raise SystemExit(main())
