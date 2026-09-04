"""Tests for the page/workspace mapping and the Lua it generates.

The mapping is the part worth guarding: a wrong page/workspace calculation
silently sends windows to another screen, which is exactly the failure this
tool exists to remove.
"""

from __future__ import annotations

import json

import pytest

from hyprpages.model import App, PagesConfig, class_to_pattern, state_path


@pytest.fixture
def cfg() -> PagesConfig:
    return PagesConfig(pages=10, offset=10, monitors=["HDMI-A-1", "DP-3"])


class TestWorkspaceMapping:
    def test_first_monitor_uses_the_page_number_unchanged(self, cfg):
        assert cfg.workspace_for(1, "HDMI-A-1") == 1
        assert cfg.workspace_for(10, "HDMI-A-1") == 10

    def test_later_monitors_are_offset_by_a_full_band(self, cfg):
        assert cfg.workspace_for(1, "DP-3") == 11
        assert cfg.workspace_for(4, "DP-3") == 14

    def test_third_monitor_lands_in_the_next_band(self):
        cfg = PagesConfig(monitors=["A", "B", "C"])
        assert cfg.workspace_for(3, "C") == 23

    def test_unknown_monitor_has_no_workspace(self, cfg):
        assert cfg.workspace_for(1, "DP-9") is None

    def test_pages_outside_the_configured_range_are_rejected(self, cfg):
        assert cfg.workspace_for(0, "HDMI-A-1") is None
        assert cfg.workspace_for(11, "HDMI-A-1") is None

    @pytest.mark.parametrize("page", range(1, 11))
    @pytest.mark.parametrize("monitor", ["HDMI-A-1", "DP-3"])
    def test_page_of_inverts_workspace_for(self, cfg, page, monitor):
        workspace = cfg.workspace_for(page, monitor)
        assert cfg.page_of(workspace) == (page, monitor)

    def test_workspaces_beyond_the_last_band_are_not_pages(self, cfg):
        assert cfg.page_of(99) is None

    def test_a_smaller_offset_than_page_count_would_overlap(self):
        """offset <= pages makes bands collide; page_of returns the first match.

        Documented rather than prevented: the UI clamps offset >= pages, and
        this test pins the behaviour so a future change is a deliberate one.
        """
        cfg = PagesConfig(pages=10, offset=5, monitors=["A", "B"])
        assert cfg.workspace_for(6, "A") == 6
        assert cfg.page_of(6) == (6, "A")


class TestLuaGeneration:
    def test_no_monitors_produces_a_comment_not_broken_lua(self):
        lua = PagesConfig().to_lua()
        assert "No monitors configured" in lua
        assert "workspace_rule" not in lua

    def test_pins_every_monitor(self, cfg):
        lua = cfg.to_lua()
        assert 'monitor = "HDMI-A-1"' in lua
        assert 'monitor = "DP-3"' in lua
        assert "tostring(page)" in lua
        assert "tostring(page + 10)" in lua

    def test_app_rule_carries_the_resolved_workspace(self, cfg):
        cfg.apps = [App(pattern="^steam$", page=4, monitor="DP-3", label="steam")]
        assert (
            'hl.window_rule({ match = { class = "^steam$" }, workspace = "14 silent" })'
            in cfg.to_lua()
        )

    def test_floating_app_emits_float_and_size(self, cfg):
        cfg.apps = [App(pattern="^vlc$", page=1, monitor="HDMI-A-1", float=True, size="1280 720")]
        lua = cfg.to_lua()
        assert "float = true" in lua
        assert 'size = "1280 720"' in lua

    def test_app_on_an_unknown_monitor_is_still_emitted_when_floating(self, cfg):
        """A float-only rule is valid without a workspace."""
        cfg.apps = [App(pattern="^vlc$", page=1, monitor="", float=True)]
        lua = cfg.to_lua()
        assert "float = true" in lua
        assert "workspace" not in lua.split("-- Window placement.")[1].split("\n")[1]

    def test_uses_only_hyprland_api_not_a_distro_helper(self, cfg):
        """The generated file must load on any Hyprland, not just one distro:
        `o.window` is an Omarchy wrapper around hl.window_rule."""
        cfg.apps = [App(pattern="^x$", page=1, monitor="HDMI-A-1")]
        lua = cfg.to_lua()
        assert "o.window(" not in lua
        assert "o.bind(" not in lua
        assert "hl.window_rule(" in lua

    def test_app_with_nothing_to_say_becomes_a_comment(self, cfg):
        cfg.apps = [App(pattern="^ghost$", page=1, monitor="", float=False)]
        assert "-- (no rules for ^ghost$)" in cfg.to_lua()

    def test_pairing_hook_is_omitted_for_a_single_monitor(self):
        cfg = PagesConfig(monitors=["HDMI-A-1"])
        assert "workspace.active" not in cfg.to_lua()

    def test_pairing_hook_guards_against_recursion(self, cfg):
        """Without the flag, each focus re-fires the event and the monitors
        chase each other indefinitely."""
        lua = cfg.to_lua()
        assert "page_syncing = true" in lua
        assert "page_syncing = false" in lua
        assert "if page_syncing then" in lua

    def test_quotes_in_a_monitor_name_cannot_break_out_of_the_string(self):
        cfg = PagesConfig(monitors=['DP-"evil'])
        assert r'monitor = "DP-\"evil"' in cfg.to_lua()


class TestPatterns:
    @pytest.mark.parametrize(
        "cls,expected",
        [
            ("steam", "^steam$"),
            ("org.qbittorrent.qBittorrent", r"^org\.qbittorrent\.qBittorrent$"),
            ("chrome-web.whatsapp.com__-Default", r"^chrome-web\.whatsapp\.com__-Default$"),
        ],
    )
    def test_metacharacters_are_escaped(self, cls, expected):
        assert class_to_pattern(cls) == expected

    def test_a_dot_is_not_left_as_a_wildcard(self):
        """`org.qbittorrent` unescaped would also match `orgXqbittorrent`."""
        assert r"\." in class_to_pattern("org.qbittorrent.qBittorrent")


class TestPersistence:
    def test_round_trips_through_disk(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        original = PagesConfig(
            pages=6,
            offset=20,
            monitors=["A", "B"],
            apps=[App(pattern="^x$", page=2, monitor="B", label="x")],
        )
        original.save()

        restored = PagesConfig.load()
        assert restored.pages == 6
        assert restored.offset == 20
        assert restored.monitors == ["A", "B"]
        assert restored.apps[0].pattern == "^x$"
        assert restored.apps[0].workspace(restored) == 22

    def test_missing_file_yields_defaults(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        assert PagesConfig.load().apps == []

    def test_paths_follow_xdg_at_call_time(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        assert state_path() == tmp_path / "hyprpages" / "pages.json"

    def test_saved_file_is_readable_json(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A"]).save()
        assert json.loads(state_path().read_text())["monitors"] == ["A"]
