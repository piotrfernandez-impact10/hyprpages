"""Map a window class to the icon its application ships.

A window class is not an icon name, and the gap is not cosmetic: `kitty
--class restore-terms` still wants kitty's icon, and Chrome's web apps carry
classes like `chrome-web.whatsapp.com__-Default` that no icon theme knows.

Desktop entries are the authority. `StartupWMClass` exists precisely to state
"windows with this class belong to me", so it is checked first; only then do we
fall back to guessing from the entry's own filename.
"""

from __future__ import annotations

import os
import re
from functools import lru_cache
from pathlib import Path


# Freedesktop search path, most specific first: a user's own entry should win
# over the packaged one.
def data_dirs() -> list[Path]:
    home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    system = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    return [home, *(Path(p) for p in system.split(":") if p)]


def _entry_fields(text: str) -> dict[str, str]:
    """Read the [Desktop Entry] group only.

    Actions and other groups repeat Icon= and Name= keys; reading the whole
    file would let a "New Window" action's icon override the application's.
    """
    fields: dict[str, str] = {}
    in_main = False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            in_main = line == "[Desktop Entry]"
            continue
        if not in_main or "=" not in line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        fields.setdefault(key.strip(), value.strip())
    return fields


@lru_cache(maxsize=1)
def _entries() -> list[tuple[str, str, dict[str, str]]]:
    """(stem, id, fields) for every installed entry, deduped the XDG way.

    A user's own ~/.local/share entry replaces the packaged one of the same
    name outright, rather than the two being merged key by key.
    """
    seen: dict[str, tuple[str, str, dict[str, str]]] = {}
    for root in data_dirs():
        directory = root / "applications"
        if not directory.is_dir():
            continue
        for entry in sorted(directory.glob("*.desktop")):
            if entry.stem in seen:
                continue  # a more specific directory already provided it
            try:
                fields = _entry_fields(entry.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            seen[entry.stem] = (entry.stem, entry.name, fields)
    return list(seen.values())


def _launchable(fields: dict[str, str]) -> bool:
    """Whether a person could start this entry.

    NoDisplay and Hidden entries are infrastructure - mime handlers, session
    pieces - and an entry that is not an Application cannot be started at all.
    """
    return (
        fields.get("Type", "Application") == "Application"
        and fields.get("NoDisplay", "").lower() != "true"
        and fields.get("Hidden", "").lower() != "true"
    )


@lru_cache(maxsize=1)
def icon_index() -> tuple[dict[str, str], dict[str, str]]:
    """(by StartupWMClass, by entry stem) -> icon name.

    Cached: scanning a few hundred small files on every window is wasteful, and
    the set of installed applications does not change mid-edit.
    """
    by_class: dict[str, str] = {}
    by_stem: dict[str, str] = {}
    for stem, _id, fields in _entries():
        icon = fields.get("Icon")
        if not icon:
            continue
        wm_class = fields.get("StartupWMClass")
        if wm_class:
            by_class.setdefault(wm_class.lower(), icon)
        by_stem.setdefault(stem.lower(), icon)
    return by_class, by_stem


@lru_cache(maxsize=1)
def entry_index() -> tuple[dict[str, str], dict[str, str]]:
    """(by StartupWMClass, by entry stem) -> desktop entry id.

    The same shape as icon_index, over the entries a person can actually start:
    the answer is used to decide "the app you picked is that window over
    there", so an entry the picker never offers would be a useless match.
    """
    by_class: dict[str, str] = {}
    by_stem: dict[str, str] = {}
    for stem, entry_id, fields in _entries():
        if not _launchable(fields):
            continue
        wm_class = fields.get("StartupWMClass")
        if wm_class:
            by_class.setdefault(wm_class.lower(), entry_id)
        by_stem.setdefault(stem.lower(), entry_id)
    return by_class, by_stem


def clear_cache() -> None:
    """Forget the scanned entries, after something is installed or removed."""
    _entries.cache_clear()
    icon_index.cache_clear()
    entry_index.cache_clear()


def _resolve(
    window_class: str, process: str, by_class: dict[str, str], by_stem: dict[str, str]
) -> str:
    """Walk a window class down to whatever an index knows about it.

    One ladder, used for both icons and entry ids, so the two can never
    disagree about which application a window belongs to.
    """
    lowered = window_class.lower()

    if lowered in by_class:
        return by_class[lowered]
    if lowered in by_stem:
        return by_stem[lowered]

    # Chrome web apps: chrome-web.whatsapp.com__-Default. The class encodes the
    # site, not an application, so the browser is the honest answer.
    if lowered.startswith("chrome-"):
        for candidate in ("google-chrome", "chromium"):
            if candidate in by_stem:
                return by_stem[candidate]

    # Reverse-DNS ids: org.qbittorrent.qBittorrent -> qbittorrent.
    tail = lowered.rsplit(".", 1)[-1]
    if tail != lowered and tail in by_stem:
        return by_stem[tail]

    # Last resort: the leading word, so `kitty --class restore-terms` style
    # renames and suffixed classes still land on something sensible.
    head = re.split(r"[-_.\s]", lowered, maxsplit=1)[0]
    if head and head in by_stem:
        return by_stem[head]

    # The class led nowhere; ask what is actually running.
    process = process.lower()
    if process:
        if process in by_class:
            return by_class[process]
        if process in by_stem:
            return by_stem[process]

    return ""


def icon_for(window_class: str, process: str = "") -> str:
    """Best icon name for a window class, or "" when nothing plausible matches.

    `process` is the window's own process name, used only when the class leads
    nowhere: a class is whatever the user chose (`kitty --class restore-terms`),
    while the process is what is actually running.

    Returning a name rather than a path keeps theme resolution in the UI, which
    already knows the icon theme and can fall back on its own.
    """
    if not window_class and not process:
        return ""
    return _resolve(window_class, process, *icon_index())


def entry_match(window_class: str, process: str = "") -> tuple[str, bool]:
    """(desktop entry id, whether the class named it outright).

    Lets the editor answer "is the app you just picked already open?", so
    choosing a running application moves its window instead of asking it to
    start again - which single-instance applications answer by raising the
    window they already have, wherever it happens to be.

    The second half matters because the fallbacks are deliberately generous:
    `steam_app_1234` resolving to Steam is the right icon and the wrong window
    to drag across pages. An exact match is preferred wherever one exists.
    """
    if not window_class and not process:
        return "", False
    by_class, by_stem = entry_index()
    entry = _resolve(window_class, process, by_class, by_stem)
    lowered = window_class.lower()
    exact = bool(entry) and entry in (by_class.get(lowered), by_stem.get(lowered))
    return entry, exact


def entry_for(window_class: str, process: str = "") -> str:
    """The desktop entry id a window belongs to, e.g. "spotify.desktop"."""
    return entry_match(window_class, process)[0]


def applications() -> list[dict]:
    """Launchable desktop entries, sorted by name."""
    out = []
    for _stem, entry_id, fields in _entries():
        name = fields.get("Name")
        if not name or not _launchable(fields):
            continue
        out.append(
            {
                "id": entry_id,
                "name": name,
                "icon": fields.get("Icon", ""),
                "comment": fields.get("Comment", ""),
            }
        )
    return sorted(out, key=lambda a: a["name"].lower())
