"""Tests for the command layer.

This is where the awkward reasoning lives -- inferring which monitor holds
which band of workspaces, and deciding how to launch a desktop entry on a
system that may not have the tools we would prefer. hyprctl is faked, so none
of it needs a compositor.
"""

from __future__ import annotations

from typing import ClassVar

import pytest

from hyprpages import cli
from hyprpages.model import App, PagesConfig

MONITORS = [
    {"id": 0, "name": "HDMI-A-1", "x": 2560, "y": 0, "width": 3440, "height": 1440},
    {"id": 1, "name": "DP-3", "x": 0, "y": 0, "width": 2560, "height": 1440},
]


def fake_workspaces(monkeypatch, workspaces):
    monkeypatch.setattr(cli.hypr, "query", lambda *a: workspaces)


class TestInferMonitorOrder:
    def test_reads_the_live_pinning_rather_than_physical_order(self, monkeypatch):
        """DP-3 is physically left, but workspaces 1-10 live on HDMI-A-1, so
        HDMI-A-1 is the first band. Guessing left-to-right mirrors the layout."""
        fake_workspaces(
            monkeypatch,
            [
                {"id": 1, "monitor": "HDMI-A-1"},
                {"id": 2, "monitor": "HDMI-A-1"},
                {"id": 12, "monitor": "DP-3"},
            ],
        )
        assert cli.infer_monitor_order(MONITORS, 10) == ["HDMI-A-1", "DP-3"]

    def test_falls_back_to_physical_order_without_evidence(self, monkeypatch):
        fake_workspaces(monkeypatch, [])
        # hypr.monitors() sorts left-to-right, so the given order is the fallback.
        assert cli.infer_monitor_order(MONITORS, 10) == ["HDMI-A-1", "DP-3"]

    def test_a_monitor_with_no_workspaces_keeps_a_place(self, monkeypatch):
        fake_workspaces(monkeypatch, [{"id": 11, "monitor": "DP-3"}])
        order = cli.infer_monitor_order(MONITORS, 10)
        assert set(order) == {"HDMI-A-1", "DP-3"}
        assert order[1] == "DP-3"

    def test_special_workspaces_are_ignored(self, monkeypatch):
        """Named workspaces have non-integer or negative ids and say nothing
        about which band a monitor holds."""
        fake_workspaces(
            monkeypatch,
            [
                {"id": -99, "monitor": "DP-3"},
                {"id": "special:magic", "monitor": "DP-3"},
                {"id": 3, "monitor": "HDMI-A-1"},
            ],
        )
        assert cli.infer_monitor_order(MONITORS, 10)[0] == "HDMI-A-1"

    def test_the_busiest_band_wins_a_tie_break(self, monkeypatch):
        """A window dragged to the wrong band should not flip the whole order."""
        fake_workspaces(
            monkeypatch,
            [
                {"id": 1, "monitor": "DP-3"},
                {"id": 11, "monitor": "DP-3"},
                {"id": 12, "monitor": "DP-3"},
                {"id": 13, "monitor": "DP-3"},
            ],
        )
        assert cli.infer_monitor_order(MONITORS, 10)[1] == "DP-3"


class TestMonitorShapes:
    """Configurations other than the author's own two side-by-side screens."""

    def test_single_monitor_needs_no_pairing(self):
        from hyprpages.model import PagesConfig

        cfg = PagesConfig(monitors=["eDP-1"])
        assert "workspace.active" not in cfg.to_lua()
        assert cfg.workspace_for(2, "eDP-1") == 2

    def test_three_monitors_get_three_bands(self):
        from hyprpages.model import PagesConfig

        cfg = PagesConfig(monitors=["DP-1", "DP-2", "HDMI-A-1"])
        assert cfg.workspace_for(3, "HDMI-A-1") == 23
        assert cfg.page_of(23) == (3, "HDMI-A-1")

    def test_a_configured_monitor_that_is_unplugged_emits_no_rule(self):
        """Better a comment than a rule pointing at a workspace that is not
        pinned to anything."""
        from hyprpages.model import App, PagesConfig

        cfg = PagesConfig(
            monitors=["HDMI-A-1"],
            apps=[App(pattern="^steam$", page=4, monitor="DP-9", label="steam")],
        )
        assert "-- (no rules for ^steam$)" in cfg.to_lua()


class TestLaunchCommand:
    def test_prefers_uwsm_when_present(self, monkeypatch):
        monkeypatch.setattr(cli.shutil, "which", lambda name: f"/usr/bin/{name}")
        assert cli._launch_command("spotify") == [
            "uwsm-app",
            "--",
            "gtk-launch",
            "spotify",
        ]

    def test_works_without_uwsm(self, monkeypatch):
        """uwsm is a session manager many setups do not run; requiring it would
        make the tool Omarchy-only."""
        monkeypatch.setattr(
            cli.shutil, "which", lambda name: None if name == "uwsm-app" else f"/usr/bin/{name}"
        )
        assert cli._launch_command("spotify") == ["gtk-launch", "spotify"]

    def test_falls_back_to_gio(self, monkeypatch):
        monkeypatch.setattr(
            cli.shutil, "which", lambda name: "/usr/bin/gio" if name == "gio" else None
        )
        assert cli._launch_command("spotify")[:2] == ["gio", "launch"]

    def test_none_when_nothing_can_launch(self, monkeypatch):
        monkeypatch.setattr(cli.shutil, "which", lambda name: None)
        assert cli._launch_command("spotify") is None


class TestMove:
    CLIENTS: ClassVar[list[dict]] = [
        {"address": "0xAAA", "initialClass": "foot", "workspace": {"name": "1"}},
        {"address": "0xBBB", "initialClass": "foot", "workspace": {"name": "1"}},
        {"address": "0xCCC", "initialClass": "steam", "workspace": {"name": "1"}},
    ]

    def _run(self, monkeypatch, tmp_path, argv):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A", "B"]).save()
        monkeypatch.setattr(cli.hypr, "query", lambda *a: self.CLIENTS)
        monkeypatch.setattr(cli.hypr, "monitors", lambda: [])
        moved = []
        monkeypatch.setattr(
            cli.hypr, "move_to_workspace", lambda addr, ws: moved.append((addr, ws))
        )
        assert cli.main(argv) == 0
        return moved

    def test_without_an_address_the_whole_class_moves(self, monkeypatch, tmp_path):
        """Right for the menu: "send this app to page 4"."""
        moved = self._run(monkeypatch, tmp_path, ["move", "foot", "--page", "2", "--monitor", "A"])
        assert sorted(a for a, _ in moved) == ["0xAAA", "0xBBB"]

    def test_an_address_moves_only_that_window(self, monkeypatch, tmp_path):
        """Right for a drag: dragging one of two terminals must not take both."""
        moved = self._run(
            monkeypatch,
            tmp_path,
            ["move", "foot", "--page", "2", "--monitor", "A", "--address", "0xBBB"],
        )
        assert moved == [("0xBBB", 2)]

    def test_a_window_already_there_is_left_alone(self, monkeypatch, tmp_path):
        moved = self._run(monkeypatch, tmp_path, ["move", "foot", "--page", "1", "--monitor", "A"])
        assert moved == []


class TestNotLoadedWarning:
    def test_quiet_once_the_lua_config_requires_it(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        hypr = tmp_path / "hypr"
        hypr.mkdir()
        (hypr / "hyprland.lua").write_text('require("hypr.hyprpages")\n')

        cli._warn_if_not_loaded(hypr / "hyprpages.lua", "lua")
        assert capsys.readouterr().err == ""

    def test_warns_when_nothing_loads_the_file(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        (tmp_path / "hypr").mkdir()

        cli._warn_if_not_loaded(tmp_path / "hypr" / "hyprpages.lua", "lua")
        assert 'require("hypr.hyprpages")' in capsys.readouterr().err

    def test_conf_format_names_the_source_line(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        (tmp_path / "hypr").mkdir()

        cli._warn_if_not_loaded(tmp_path / "hypr" / "hyprpages.conf", "conf")
        assert "source = ~/.config/hypr/hyprpages.conf" in capsys.readouterr().err


class TestApplyEndToEnd:
    def test_writes_the_chosen_format_and_reports_where(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A", "B"], apps=[App(pattern="^x$", page=1, monitor="B")]).save()
        monkeypatch.setattr(cli.hypr, "reload", lambda: None)
        monkeypatch.setattr(cli.hypr, "config_errors", lambda: "")

        assert cli.main(["apply", "--format", "conf"]) == 0

        written = (tmp_path / "hypr" / "hyprpages.conf").read_text()
        assert "windowrule = workspace 11 silent, class:^x$" in written
        assert "wrote" in capsys.readouterr().out

    def test_config_errors_fail_the_command(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A"]).save()
        monkeypatch.setattr(cli.hypr, "reload", lambda: None)
        monkeypatch.setattr(cli.hypr, "config_errors", lambda: "line 3: bad rule")

        assert cli.main(["apply", "--format", "conf"]) == 1

    def test_dry_run_writes_nothing(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A"]).save()

        assert cli.main(["apply", "--dry-run", "--format", "lua"]) == 0
        assert not (tmp_path / "hypr" / "hyprpages.lua").exists()


class TestErrorHandling:
    def test_missing_hyprctl_is_a_sentence_not_a_traceback(self, monkeypatch, capsys):
        def missing(*_a, **_k):
            raise FileNotFoundError("hyprctl")

        monkeypatch.setattr(cli.hypr, "monitors", missing)
        assert cli.main(["state"]) == 1
        assert "hyprctl not found" in capsys.readouterr().err

    def test_hypr_errors_are_reported(self, monkeypatch, capsys):
        def failing(*_a, **_k):
            raise cli.hypr.HyprError("no such monitor")

        monkeypatch.setattr(cli.hypr, "monitors", failing)
        assert cli.main(["state"]) == 1
        assert "no such monitor" in capsys.readouterr().err

    @pytest.mark.parametrize("command", ["state", "apps"])
    def test_commands_exist(self, command):
        """A typo in a subparser name is only caught by invoking it."""
        with pytest.raises(SystemExit):
            cli.main([command, "--help"])
