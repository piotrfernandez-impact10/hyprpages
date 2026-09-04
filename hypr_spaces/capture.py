"""Work out what is actually running inside each window.

A window rule only needs a class. Rebuilding a space needs more: the directory
a terminal sits in, the command it is running, the tabs a browser has open.
Getting that is per-application work, and the awkward cases drove the design:

* **Terminals are not uniform.** foot, alacritty and ghostty run one process
  per window, so the window's own PID is enough to walk /proc. kitty does not:
  a single kitty process owns every OS window, and hyprctl reports that same
  PID for all of them, so /proc cannot tell two kitty windows apart. kitty is
  therefore queried over its remote-control socket instead.
* **Browsers keep their tabs in the renderer**, not the filesystem, so tabs
  come from the DevTools protocol when the debug port is open, and are simply
  absent when it is not.

Anything unrecognised degrades to "just a window with a class", which is still
enough to place it.
"""

from __future__ import annotations

import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from . import desktop

# One process per window: the window PID is the terminal itself.
PROC_TERMINALS = {"foot", "footclient", "alacritty", "ghostty", "wezterm-gui", "xterm"}
# One process, many windows: must be asked over its own control socket.
SOCKET_TERMINALS = {"kitty"}
BROWSERS = {"google-chrome", "chromium", "brave-browser", "microsoft-edge"}

CDP_PORT = int(os.environ.get("HYPR_SPACES_CDP_PORT", "9333"))

# Shells are containers, not the interesting command. If a terminal's deepest
# child is one of these, the terminal is considered idle at a directory.
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "nu", "elvish"}


# --------------------------------------------------------------------- /proc


def _children(pid: int) -> list[int]:
    try:
        raw = Path(f"/proc/{pid}/task").iterdir()
    except OSError:
        return []
    kids: list[int] = []
    for task in raw:
        try:
            kids += [int(p) for p in (task / "children").read_text().split()]
        except (OSError, ValueError):
            continue
    return kids


def _comm(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return ""


def _cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return " ".join(p for p in raw.decode("utf-8", "replace").split("\0") if p)


def _cwd(pid: int) -> str:
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return ""


def _deepest_descendant(pid: int) -> int:
    """The leaf of the process tree - the command actually in the foreground.

    Depth-first, preferring the most recently started branch, because a shell
    that has spawned several background jobs should still report the job the
    user is looking at.
    """
    best, best_depth = pid, 0
    stack = [(pid, 0)]
    seen = {pid}
    while stack:
        current, depth = stack.pop()
        if depth > best_depth:
            best, best_depth = current, depth
        for kid in sorted(_children(current)):
            if kid not in seen:
                seen.add(kid)
                stack.append((kid, depth + 1))
    return best


def terminal_from_proc(pid: int) -> dict | None:
    """cwd + running command for a one-process-per-window terminal."""
    if pid <= 0:
        return None
    leaf = _deepest_descendant(pid)
    command = _cmdline(leaf)
    if _comm(leaf) in SHELLS:
        command = ""  # sitting at a prompt, not running anything
    return {"cwd": _cwd(leaf) or _cwd(pid), "command": command}


# ---------------------------------------------------------------------- kitty


def kitty_windows() -> dict[str, dict]:
    """Map kitty OS-window title -> {cwd, command}, via its control socket.

    hyprctl reports one shared PID for every kitty OS window, so /proc cannot
    distinguish them; kitty's own `@ ls` is the only source that can. Requires
    `allow_remote_control yes` and a `listen_on` socket in kitty.conf.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    out: dict[str, dict] = {}
    # kitty's socket name comes from the user's `listen_on`, so it cannot be
    # predicted; Omarchy uses omarchy-kitty-<pid>, upstream defaults to
    # kitty-<pid>. Try every plausible socket and ignore the ones that refuse.
    sockets = sorted({s for pattern in ("*kitty*", "kitty-*") for s in Path(runtime).glob(pattern)})
    for sock in sockets:
        if not sock.is_socket():
            continue
        try:
            proc = subprocess.run(
                ["kitty", "@", "--to", f"unix:{sock}", "ls"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if proc.returncode != 0:
                continue
            for os_window in json.loads(proc.stdout):
                for tab in os_window.get("tabs", []):
                    windows = tab.get("windows", [])
                    if not windows:
                        continue
                    win = next((w for w in windows if w.get("is_active")), windows[0])
                    procs = win.get("foreground_processes", []) or []
                    # The oldest foreground process is the shell or the command
                    # itself; the newest may be a transient helper such as a
                    # clipboard writer sitting at "/".
                    leaf = procs[-1] if procs else {}
                    if leaf.get("cwd") in ("/", "", None) and len(procs) > 1:
                        leaf = procs[0]
                    out[tab.get("title") or win.get("title", "")] = {
                        "cwd": leaf.get("cwd") or win.get("cwd", ""),
                        "command": " ".join(leaf.get("cmdline", []) or []),
                    }
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    return out


# -------------------------------------------------------------------- browser


def browser_tabs() -> list[dict] | None:
    """Open tabs via the DevTools protocol, or None when the port is closed.

    None and [] mean different things to the UI: None is "we cannot see tabs",
    [] is "this browser genuinely has none".
    """
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{CDP_PORT}/json/list", timeout=2
        ) as response:
            targets = json.load(response)
    except (TimeoutError, urllib.error.URLError, OSError, ValueError):
        return None
    return [
        {"url": t.get("url", ""), "title": t.get("title", "")}
        for t in targets
        if t.get("type") == "page" and not t.get("url", "").startswith("devtools://")
    ]


# ----------------------------------------------------------------- dispatcher


def describe(window: dict, kitty_cache: dict[str, dict], tabs: list | None) -> dict:
    """Enrich one hyprctl client with whatever detail we can get for its kind."""
    cls = window.get("initialClass") or window.get("class") or ""
    pid = window.get("pid", 0)
    comm = _comm(pid)
    detail: dict = {}
    kind = "window"

    if comm in SOCKET_TERMINALS or cls in SOCKET_TERMINALS:
        kind = "terminal"
        detail = kitty_cache.get(window.get("title", ""), {})
    elif comm in PROC_TERMINALS or cls in PROC_TERMINALS:
        kind = "terminal"
        detail = terminal_from_proc(pid) or {}
    elif cls in BROWSERS or cls.startswith("chrome-"):
        kind = "browser"
        if tabs is not None:
            detail = {"tabs": tabs}

    return {
        "class": cls,
        "icon": desktop.icon_for(cls, comm),
        "kind": kind,
        "workspace": window.get("workspace", {}).get("name", ""),
        "floating": window.get("floating", False),
        # Geometry in compositor coordinates. `at` is absolute across the whole
        # desktop, not relative to the window's monitor, so the editor has to
        # subtract the monitor origin before drawing a scale miniature.
        "at": window.get("at", []),
        "size": window.get("size", []),
        "monitorId": window.get("monitor", -1),
        "detail": detail,
    }
