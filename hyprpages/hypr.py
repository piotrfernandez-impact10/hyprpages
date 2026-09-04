"""Thin wrapper around hyprctl.

Everything here shells out to `hyprctl -j` rather than talking to the IPC
socket directly. Hyprland 0.56 parses socket commands as Lua, so the old
plain-text `dispatch movetoworkspacesilent 4,address:0x...` form is gone --
`hyprctl dispatch` with a Lua expression is now the stable interface.
"""

from __future__ import annotations

import json
import subprocess


class HyprError(RuntimeError):
    pass


def _hyprctl(*args: str) -> str:
    proc = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        raise HyprError(proc.stderr.strip() or f"hyprctl {' '.join(args)} failed")
    return proc.stdout


def query(*args: str):
    """Any `hyprctl <args> -j` call, decoded."""
    return json.loads(_hyprctl(*args, "-j") or "null")


def monitors() -> list[dict]:
    """Left-to-right, so the UI column order matches the physical desks."""
    mons = query("monitors") or []
    mons.sort(key=lambda m: m.get("x", 0))
    return [
        {
            "id": m.get("id", -1),
            "name": m["name"],
            "description": m.get("description", ""),
            "width": m.get("width"),
            "height": m.get("height"),
            # Logical size: the space windows are positioned in, which is what
            # the editor draws.
            **_logical_size(m),
            # Physical placement, so the editor can mirror the desk layout
            # rather than guessing an order.
            "x": m.get("x", 0),
            "y": m.get("y", 0),
            "scale": m.get("scale", 1),
            "transform": m.get("transform", 0),
            "reserved": m.get("reserved", [0, 0, 0, 0]),
            # "none" when independent; otherwise the screen this one mirrors.
            "mirrorOf": "" if m.get("mirrorOf") in (None, "none") else m.get("mirrorOf"),
            "refresh": round(m.get("refreshRate", 0), 2),
            "active_workspace": m.get("activeWorkspace", {}).get("name"),
            "focused": m.get("focused", False),
        }
        for m in mons
    ]


# wl_output transforms 1, 3, 5 and 7 are the quarter turns; the rest are
# upright or flipped upright.
_ROTATED = {1, 3, 5, 7}


def _logical_size(monitor: dict) -> dict:
    """The space a monitor occupies, from the mode it reports.

    Two corrections, both invisible on an unscaled landscape screen and both
    wrong everywhere else:

    * `width`/`height` are the mode in physical pixels, while windows are
      positioned in logical coordinates. They differ by `scale`.
    * The mode is reported unrotated. A rotated monitor occupies its height in
      width - confirmed by placing a second output beside a transform-3 one and
      watching where the compositor put it.
    """
    width = monitor.get("width") or 0
    height = monitor.get("height") or 0
    scale = monitor.get("scale") or 1
    if monitor.get("transform", 0) in _ROTATED:
        width, height = height, width
    return {
        "logicalWidth": round(width / scale),
        "logicalHeight": round(height / scale),
    }


def clients() -> list[dict]:
    """Open windows, deduplicated by class.

    Titles are deliberately not returned: they leak whatever the user happens
    to have open (documents, filenames, private chats) into the UI and any
    saved config. The class is all a window rule needs.
    """
    seen: dict[str, dict] = {}
    for c in query("clients") or []:
        cls = c.get("initialClass") or c.get("class") or ""
        if not cls:
            continue
        entry = seen.setdefault(
            cls,
            {
                "class": cls,
                "count": 0,
                "floating": c.get("floating", False),
                "xwayland": c.get("xwayland", False),
                "workspaces": [],
            },
        )
        entry["count"] += 1
        ws = c.get("workspace", {}).get("name")
        if ws and ws not in entry["workspaces"]:
            entry["workspaces"].append(ws)
    return sorted(seen.values(), key=lambda e: e["class"].lower())


def move_to_workspace(address: str, workspace: int, follow: bool = False) -> None:
    """Move one window to a workspace, without dragging focus along.

    Hyprland 0.56 parses dispatch arguments as Lua, so the older
    `dispatch movetoworkspacesilent 4,address:0x...` form is gone.
    """
    _hyprctl(
        "dispatch",
        "hl.dsp.window.move({{ workspace = '{}', follow = {}, window = 'address:{}' }})".format(
            workspace, "true" if follow else "false", address
        ),
    )


def focus_workspace(monitor: str, workspace: int) -> None:
    """Bring a workspace up on a given monitor and leave focus there.

    The monitor is focused first: `focus({workspace})` acts on whichever
    monitor currently has focus, so without this the workspace would be pulled
    onto the wrong screen.
    """
    _hyprctl("dispatch", f"hl.dsp.focus({{ monitor = '{monitor}' }})")
    _hyprctl("dispatch", f"hl.dsp.focus({{ workspace = '{workspace}' }})")


def focus_monitor(monitor: str) -> None:
    _hyprctl("dispatch", f"hl.dsp.focus({{ monitor = '{monitor}' }})")


def focus_window(address: str) -> None:
    _hyprctl("dispatch", f"hl.dsp.focus({{ window = 'address:{address}' }})")


def close_window(address: str) -> None:
    """Ask a window to close, the same as the compositor's own close binding.

    This is a request, not a kill: an application with unsaved work gets to put
    its dialog up rather than losing it.
    """
    _hyprctl("dispatch", f"hl.dsp.window.close({{ window = 'address:{address}' }})")


def reload() -> None:
    _hyprctl("reload")


def config_errors() -> str:
    return _hyprctl("configerrors").strip()
