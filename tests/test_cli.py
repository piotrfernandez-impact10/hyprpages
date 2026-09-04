"""Tests for the command layer.

This is where the awkward reasoning lives -- inferring which monitor holds
which band of workspaces, and deciding how to launch a desktop entry on a
system that may not have the tools we would prefer. hyprctl is faked, so none
of it needs a compositor.
"""

from __future__ import annotations

import pytest

from hypr_spaces import cli
from hypr_spaces.model import App, SpacesConfig

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


class TestNotLoadedWarning:
    def test_quiet_once_the_lua_config_requires_it(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        hypr = tmp_path / "hypr"
        hypr.mkdir()
        (hypr / "hyprland.lua").write_text('require("hypr.spaces")\n')

        cli._warn_if_not_loaded(hypr / "spaces.lua", "lua")
        assert capsys.readouterr().err == ""

    def test_warns_when_nothing_loads_the_file(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        (tmp_path / "hypr").mkdir()

        cli._warn_if_not_loaded(tmp_path / "hypr" / "spaces.lua", "lua")
        assert 'require("hypr.spaces")' in capsys.readouterr().err

    def test_conf_format_names_the_source_line(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        (tmp_path / "hypr").mkdir()

        cli._warn_if_not_loaded(tmp_path / "hypr" / "spaces.conf", "conf")
        assert "source = ~/.config/hypr/spaces.conf" in capsys.readouterr().err


class TestApplyEndToEnd:
    def test_writes_the_chosen_format_and_reports_where(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        SpacesConfig(monitors=["A", "B"], apps=[App(pattern="^x$", page=1, monitor="B")]).save()
        monkeypatch.setattr(cli.hypr, "reload", lambda: None)
        monkeypatch.setattr(cli.hypr, "config_errors", lambda: "")

        assert cli.main(["apply", "--format", "conf"]) == 0

        written = (tmp_path / "hypr" / "spaces.conf").read_text()
        assert "windowrule = workspace 11 silent, class:^x$" in written
        assert "wrote" in capsys.readouterr().out

    def test_config_errors_fail_the_command(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        SpacesConfig(monitors=["A"]).save()
        monkeypatch.setattr(cli.hypr, "reload", lambda: None)
        monkeypatch.setattr(cli.hypr, "config_errors", lambda: "line 3: bad rule")

        assert cli.main(["apply", "--format", "conf"]) == 1

    def test_dry_run_writes_nothing(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        SpacesConfig(monitors=["A"]).save()

        assert cli.main(["apply", "--dry-run", "--format", "lua"]) == 0
        assert not (tmp_path / "hypr" / "spaces.lua").exists()


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
