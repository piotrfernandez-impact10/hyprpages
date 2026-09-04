"""Tests for window introspection.

These use fake /proc trees and fake hyprctl payloads rather than the live
desktop, so they run in CI where there is no compositor at all.
"""

from __future__ import annotations

import json

import pytest

from hypr_spaces import capture


@pytest.fixture
def fake_proc(monkeypatch):
    """Build a process tree in memory and point capture's readers at it."""
    tree: dict[int, dict] = {}

    def add(pid: int, comm: str, cmdline: str, cwd: str, parent: int | None = None):
        tree[pid] = {"comm": comm, "cmdline": cmdline, "cwd": cwd, "children": []}
        if parent is not None:
            tree[parent]["children"].append(pid)

    monkeypatch.setattr(capture, "_children", lambda pid: tree.get(pid, {}).get("children", []))
    monkeypatch.setattr(capture, "_comm", lambda pid: tree.get(pid, {}).get("comm", ""))
    monkeypatch.setattr(capture, "_cmdline", lambda pid: tree.get(pid, {}).get("cmdline", ""))
    monkeypatch.setattr(capture, "_cwd", lambda pid: tree.get(pid, {}).get("cwd", ""))
    return add


class TestTerminalFromProc:
    def test_finds_the_command_running_under_the_shell(self, fake_proc):
        fake_proc(100, "foot", "foot", "/home/u")
        fake_proc(101, "bash", "bash", "/home/u/project", parent=100)
        fake_proc(102, "vim", "vim notes.md", "/home/u/project", parent=101)

        assert capture.terminal_from_proc(100) == {
            "cwd": "/home/u/project",
            "command": "vim notes.md",
        }

    def test_an_idle_shell_reports_a_directory_and_no_command(self, fake_proc):
        fake_proc(100, "foot", "foot", "/home/u")
        fake_proc(101, "bash", "bash", "/home/u/project", parent=100)

        result = capture.terminal_from_proc(100)
        assert result["cwd"] == "/home/u/project"
        assert result["command"] == ""

    def test_falls_back_to_the_terminal_cwd_when_the_leaf_has_none(self, fake_proc):
        fake_proc(100, "foot", "foot", "/home/u")
        fake_proc(101, "bash", "bash", "", parent=100)
        assert capture.terminal_from_proc(100)["cwd"] == "/home/u"

    def test_deepest_branch_wins_over_a_shallow_sibling(self, fake_proc):
        fake_proc(100, "foot", "foot", "/home/u")
        fake_proc(101, "bash", "bash", "/a", parent=100)
        fake_proc(102, "sleep", "sleep 99", "/a", parent=100)
        fake_proc(103, "claude", "claude --resume abc", "/b", parent=101)

        assert capture.terminal_from_proc(100)["command"] == "claude --resume abc"

    def test_a_cycle_cannot_hang_the_walk(self, monkeypatch):
        monkeypatch.setattr(capture, "_children", lambda pid: [100] if pid == 101 else [101])
        monkeypatch.setattr(capture, "_comm", lambda pid: "bash")
        monkeypatch.setattr(capture, "_cmdline", lambda pid: "bash")
        monkeypatch.setattr(capture, "_cwd", lambda pid: "/")
        assert capture.terminal_from_proc(100) is not None

    def test_invalid_pid_is_refused(self):
        assert capture.terminal_from_proc(0) is None
        assert capture.terminal_from_proc(-1) is None


class TestBrowserTabs:
    def test_none_when_the_debug_port_is_closed(self, monkeypatch):
        def refuse(*_a, **_k):
            raise OSError("connection refused")

        monkeypatch.setattr(capture.urllib.request, "urlopen", refuse)
        assert capture.browser_tabs() is None

    def test_empty_list_is_distinct_from_unavailable(self, monkeypatch):
        _stub_cdp(monkeypatch, [])
        assert capture.browser_tabs() == []

    def test_only_pages_are_returned(self, monkeypatch):
        _stub_cdp(
            monkeypatch,
            [
                {"type": "page", "url": "https://example.com", "title": "Example"},
                {"type": "service_worker", "url": "https://example.com/sw.js", "title": "sw"},
                {"type": "page", "url": "devtools://devtools/x", "title": "DevTools"},
            ],
        )
        assert capture.browser_tabs() == [{"url": "https://example.com", "title": "Example"}]


class TestDescribe:
    def test_kitty_is_matched_by_process_not_class(self, monkeypatch):
        """Omarchy users give kitty a custom class such as `restore-terms`,
        so class-based detection misses it entirely."""
        monkeypatch.setattr(capture, "_comm", lambda pid: "kitty")
        cache = {"Odin": {"cwd": "/src/odin", "command": "claude"}}
        window = {"class": "restore-terms", "pid": 42, "title": "Odin", "workspace": {"name": "2"}}

        result = capture.describe(window, cache, None)
        assert result["kind"] == "terminal"
        assert result["detail"]["cwd"] == "/src/odin"

    def test_unknown_windows_degrade_to_a_plain_class(self, monkeypatch):
        monkeypatch.setattr(capture, "_comm", lambda pid: "steam")
        window = {"class": "steam", "pid": 7, "workspace": {"name": "4"}}
        result = capture.describe(window, {}, None)
        assert result["kind"] == "window"
        assert result["detail"] == {}

    def test_initial_class_is_preferred_over_the_live_one(self, monkeypatch):
        """A window that renames itself must still match its original rule."""
        monkeypatch.setattr(capture, "_comm", lambda pid: "")
        window = {
            "class": "renamed",
            "initialClass": "original",
            "pid": 1,
            "workspace": {"name": "1"},
        }
        assert capture.describe(window, {}, None)["class"] == "original"

    def test_chrome_web_apps_count_as_browsers(self, monkeypatch):
        monkeypatch.setattr(capture, "_comm", lambda pid: "")
        window = {
            "class": "chrome-web.whatsapp.com__-Default",
            "pid": 1,
            "workspace": {"name": "12"},
        }
        assert capture.describe(window, {}, [])["kind"] == "browser"


def _stub_cdp(monkeypatch, payload):
    class Response:
        def read(self):
            return json.dumps(payload).encode()

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    monkeypatch.setattr(capture.json, "load", lambda r: payload)
    monkeypatch.setattr(capture.urllib.request, "urlopen", lambda *a, **k: Response())
