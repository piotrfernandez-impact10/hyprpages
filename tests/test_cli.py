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


class TestClose:
    def test_refuses_an_address_no_window_has(self, monkeypatch, capsys):
        """Dispatching blind at an address would be a silent no-op at best."""
        monkeypatch.setattr(cli.hypr, "query", lambda *a: [{"address": "0xAAA"}])
        assert cli.main(["close", "0xZZZ"]) == 1
        assert "no window with address" in capsys.readouterr().err

    def test_asks_the_known_window_to_close(self, monkeypatch):
        monkeypatch.setattr(cli.hypr, "query", lambda *a: [{"address": "0xAAA"}])
        closed = []
        monkeypatch.setattr(cli.hypr, "close_window", closed.append)
        assert cli.main(["close", "0xAAA"]) == 0
        assert closed == ["0xAAA"]


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


class TestCapture:
    """Capture folds what is running into the configuration.

    The hazard it has to avoid is that it can only see open windows: treating
    that as the whole truth deletes every rule for an application that happens
    to be closed, which is most of them, most of the time.
    """

    def _run(self, monkeypatch, tmp_path, windows, argv=("capture",), existing=()):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A", "B"], apps=list(existing)).save()
        monkeypatch.setattr(
            cli,
            "build_state",
            lambda: {"monitors": MONITORS, "windows": windows, "config": {}},
        )
        monkeypatch.setattr(cli.hypr, "monitors", lambda: MONITORS)
        assert cli.main(list(argv)) == 0
        return PagesConfig.load()

    def _window(self, cls, page, monitor="A", floating=False, size=(800, 600)):
        return {
            "class": cls,
            "page": page,
            "monitor": monitor,
            "floating": floating,
            "size": list(size),
        }

    def test_keeps_the_rules_for_applications_that_are_closed(self, monkeypatch, tmp_path):
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 2)],
            existing=[App(pattern="^spotify$", page=5, monitor="B", label="spotify")],
        )
        assert [a.pattern for a in cfg.apps] == ["^spotify$", "^foot$"]
        assert cfg.apps[0].page == 5

    def test_updates_the_rule_for_a_window_that_moved(self, monkeypatch, tmp_path):
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 4, monitor="B")],
            existing=[App(pattern="^foot$", page=1, monitor="A")],
        )
        assert len(cfg.apps) == 1
        assert (cfg.apps[0].page, cfg.apps[0].monitor) == (4, "B")

    def test_preserves_what_cannot_be_read_off_a_window(self, monkeypatch, tmp_path):
        """`together` and `label` are intent, not observable state."""
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 4)],
            existing=[App(pattern="^foot$", page=1, monitor="A", together=True, label="Terminal")],
        )
        assert cfg.apps[0].together is True
        assert cfg.apps[0].label == "Terminal"

    def test_a_class_open_on_two_pages_invents_no_rule(self, monkeypatch, tmp_path, capsys):
        """The usual state of a terminal. One rule would drag them all together."""
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 1), self._window("foot", 3)],
        )
        assert cfg.apps == []
        assert "more than one page" in capsys.readouterr().err

    def test_an_ambiguous_class_leaves_its_existing_rule_alone(self, monkeypatch, tmp_path):
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 1), self._window("foot", 3)],
            existing=[App(pattern="^foot$", page=7, monitor="B")],
        )
        assert (cfg.apps[0].page, cfg.apps[0].monitor) == (7, "B")

    def test_a_pinned_app_keeps_its_size(self, monkeypatch, tmp_path):
        """Pinned means floating by rule, not by anything visible yet: reading
        the live window back would clear the size before the rule applied."""
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("Spotify", 2, floating=False)],
            existing=[
                App(pattern="^Spotify$", page=2, monitor="A", pin=True, float=True, size="700 900")
            ],
        )
        assert (cfg.apps[0].float, cfg.apps[0].size) == (True, "700 900")

    def test_replace_drops_what_is_not_running(self, monkeypatch, tmp_path):
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 2)],
            argv=("capture", "--replace"),
            existing=[App(pattern="^spotify$", page=5, monitor="B")],
        )
        assert [a.pattern for a in cfg.apps] == ["^foot$"]

    def test_dry_run_writes_nothing(self, monkeypatch, tmp_path, capsys):
        cfg = self._run(
            monkeypatch,
            tmp_path,
            [self._window("foot", 2)],
            argv=("capture", "--dry-run"),
        )
        assert cfg.apps == []
        assert "^foot$" in capsys.readouterr().out

    def test_floating_geometry_is_recorded_only_while_floating(self, monkeypatch, tmp_path):
        cfg = self._run(
            monkeypatch, tmp_path, [self._window("mpv", 2, floating=True, size=(1280, 720))]
        )
        assert (cfg.apps[0].float, cfg.apps[0].size) == (True, "1280 720")


class TestLaunchMovesWhatIsOpen:
    """Picking a running application must not ask it to start again.

    Single-instance applications answer a second launch by raising the window
    they already have, on the workspace it is already on -- from the editor,
    the picker appears to do nothing.
    """

    CLIENTS: ClassVar[list[dict]] = [
        {
            "address": "0xAAA",
            "initialClass": "Spotify",
            "workspace": {"name": "5"},
            "focusHistoryID": 3,
            "pid": 1,
        },
        {
            "address": "0xBBB",
            "initialClass": "Spotify",
            "workspace": {"name": "7"},
            "focusHistoryID": 1,
            "pid": 2,
        },
        {
            "address": "0xCCC",
            "initialClass": "foot",
            "workspace": {"name": "2"},
            "focusHistoryID": 0,
            "pid": 3,
        },
    ]

    @pytest.fixture(autouse=True)
    def _desktop(self, monkeypatch, tmp_path):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        PagesConfig(monitors=["A", "B"]).save()
        monkeypatch.setattr(cli.hypr, "query", lambda *a: self.CLIENTS)
        monkeypatch.setattr(cli.hypr, "monitors", lambda: MONITORS)
        monkeypatch.setattr(cli.capture, "process_name", lambda pid: "")
        monkeypatch.setattr(
            cli.desktop,
            "entry_for",
            lambda cls, proc="": {"spotify": "spotify.desktop", "foot": "foot.desktop"}.get(
                cls.lower(), ""
            ),
        )

    def _run(self, monkeypatch, argv):
        moved, focused, started = [], [], []
        monkeypatch.setattr(cli.hypr, "move_to_workspace", lambda a, w: moved.append((a, w)))
        monkeypatch.setattr(cli.hypr, "focus_workspace", lambda m, w: None)
        monkeypatch.setattr(cli.hypr, "focus_window", focused.append)
        monkeypatch.setattr(cli.subprocess, "Popen", lambda *a, **k: started.append(a))
        monkeypatch.setattr(cli, "_launch_command", lambda entry: ["gtk-launch", entry])
        assert cli.main(argv) == 0
        return moved, focused, started

    def test_moves_the_most_recently_focused_window(self, monkeypatch):
        moved, focused, started = self._run(
            monkeypatch, ["launch", "spotify.desktop", "--page", "3", "--monitor", "A"]
        )
        assert moved == [("0xBBB", 3)]
        assert focused == ["0xBBB"]
        assert started == []

    def test_starts_another_when_one_is_already_on_that_page(self, monkeypatch):
        """ "Add it here" is already satisfied, so a second window is the ask."""
        moved, _, started = self._run(
            monkeypatch, ["launch", "spotify.desktop", "--page", "5", "--monitor", "A"]
        )
        assert moved == []
        assert len(started) == 1

    def test_starts_one_when_nothing_of_the_kind_is_open(self, monkeypatch):
        moved, _, started = self._run(
            monkeypatch, ["launch", "vlc.desktop", "--page", "3", "--monitor", "A"]
        )
        assert moved == []
        assert len(started) == 1

    def test_new_always_starts_another(self, monkeypatch):
        moved, _, started = self._run(
            monkeypatch, ["launch", "spotify.desktop", "--page", "3", "--monitor", "A", "--new"]
        )
        assert moved == []
        assert len(started) == 1

    def test_an_exact_class_beats_one_matched_by_fallback(self, monkeypatch):
        """steam_app_1234 resolves to Steam for its icon, and must not be moved
        when Steam itself is what was picked."""
        monkeypatch.setattr(
            cli.desktop,
            "entry_match",
            lambda cls, proc="": ("steam.desktop", cls.lower() == "steam"),
        )
        monkeypatch.setattr(
            cli.hypr,
            "query",
            lambda *a: [
                {
                    "address": "0xGAME",
                    "initialClass": "steam_app_1234",
                    "workspace": {"name": "9"},
                    "focusHistoryID": 0,
                    "pid": 1,
                },
                {
                    "address": "0xSTEAM",
                    "initialClass": "steam",
                    "workspace": {"name": "8"},
                    "focusHistoryID": 4,
                    "pid": 2,
                },
            ],
        )
        moved, _, _ = self._run(
            monkeypatch, ["launch", "steam.desktop", "--page", "3", "--monitor", "A"]
        )
        assert moved == [("0xSTEAM", 3)]


class TestSwap:
    """Two windows trade places. Position inside a screen belongs to the
    layout, so this is the only rearrangement a tiler offers."""

    CLIENTS: ClassVar[list[dict]] = [
        {"address": "0xAAA"},
        {"address": "0xBBB"},
    ]

    def _run(self, monkeypatch, argv):
        monkeypatch.setattr(cli.hypr, "query", lambda *a: self.CLIENTS)
        swapped = []
        monkeypatch.setattr(cli.hypr, "swap_windows", lambda a, b: swapped.append((a, b)))
        return cli.main(argv), swapped

    def test_swaps_two_known_windows(self, monkeypatch):
        code, swapped = self._run(monkeypatch, ["swap", "0xAAA", "0xBBB"])
        assert (code, swapped) == (0, [("0xAAA", "0xBBB")])

    def test_refuses_an_address_no_window_has(self, monkeypatch, capsys):
        """Dispatching at an unknown address is a silent no-op, and a drag that
        appears to do nothing is the worst outcome the editor can produce."""
        code, swapped = self._run(monkeypatch, ["swap", "0xAAA", "0xZZZ"])
        assert (code, swapped) == (1, [])
        assert "no window with address" in capsys.readouterr().err

    def test_swapping_a_window_with_itself_does_nothing(self, monkeypatch):
        code, swapped = self._run(monkeypatch, ["swap", "0xAAA", "0xAAA"])
        assert (code, swapped) == (0, [])
