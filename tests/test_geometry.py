"""Tests for the geometry the editor projects.

The editor draws a scale miniature of the desktop, so the state it consumes has
to carry real coordinates. These tests pin the shape of that data and the one
subtlety in it: window positions are absolute across the whole desktop, not
relative to the monitor the window sits on.
"""

from __future__ import annotations

from typing import ClassVar

import pytest

from hyprpages import capture


@pytest.fixture(autouse=True)
def _no_proc(monkeypatch):
    monkeypatch.setattr(capture, "_comm", lambda pid: "")


class TestWindowGeometry:
    def test_position_and_size_are_carried_through(self):
        window = {
            "class": "steam",
            "pid": 1,
            "at": [2572, 38],
            "size": [1701, 1390],
            "monitor": 1,
            "workspace": {"name": "4"},
        }
        described = capture.describe(window, {}, None)
        assert described["at"] == [2572, 38]
        assert described["size"] == [1701, 1390]
        assert described["monitorId"] == 1

    def test_missing_geometry_degrades_to_empty_lists(self):
        """A window the compositor reports without geometry must not crash the
        editor; it is simply not drawable."""
        described = capture.describe({"class": "x", "pid": 1, "workspace": {"name": "1"}}, {}, None)
        assert described["at"] == []
        assert described["size"] == []

    def test_absolute_coordinates_are_not_rebased(self):
        """`at` stays in compositor space. The editor subtracts the monitor
        origin itself, so rebasing here would double-correct and draw every
        window on the first screen."""
        window = {
            "class": "x",
            "pid": 1,
            "at": [2572, 38],
            "size": [100, 100],
            "monitor": 1,
            "workspace": {"name": "1"},
        }
        assert capture.describe(window, {}, None)["at"][0] == 2572


class TestProjection:
    """The maths the QML canvas performs, checked here so it is not only
    verifiable by looking at a screen."""

    monitors: ClassVar[list[dict]] = [
        {"name": "DP-3", "x": 0, "y": 0, "width": 2560, "height": 1440},
        {"name": "HDMI-A-1", "x": 2560, "y": 0, "width": 3440, "height": 1440},
    ]

    @staticmethod
    def bounds(monitors):
        return (
            min(m["x"] for m in monitors),
            min(m["y"] for m in monitors),
            max(m["x"] + m["width"] for m in monitors),
            max(m["y"] + m["height"] for m in monitors),
        )

    def test_bounding_box_spans_every_monitor(self):
        assert self.bounds(self.monitors) == (0, 0, 6000, 1440)

    def test_one_scale_for_both_axes_preserves_aspect(self):
        min_x, min_y, max_x, max_y = self.bounds(self.monitors)
        width, height = max_x - min_x, max_y - min_y
        fit = min(1200 / width, 700 / height)

        drawn = [(m["width"] * fit, m["height"] * fit) for m in self.monitors]
        # Each screen keeps its own aspect ratio...
        for (dw, dh), m in zip(drawn, self.monitors, strict=True):
            assert dw / dh == pytest.approx(m["width"] / m["height"])
        # ...and their relative widths are preserved.
        assert drawn[0][0] / drawn[1][0] == pytest.approx(2560 / 3440)

    def test_vertically_stacked_monitors_are_handled(self):
        stacked = [
            {"name": "A", "x": 0, "y": 0, "width": 1920, "height": 1080},
            {"name": "B", "x": 0, "y": 1080, "width": 1920, "height": 1080},
        ]
        assert self.bounds(stacked) == (0, 0, 1920, 2160)

    def test_a_scaled_monitor_is_measured_in_logical_pixels(self):
        """A 2560px monitor at 1.5x is 1707 logical px wide, and windows are
        positioned in logical space. Drawing against the mode's pixel size
        would shrink every window on that screen by the scale factor."""
        monitor = {"width": 2560, "height": 1440, "scale": 1.5}
        logical_w = round(monitor["width"] / monitor["scale"])
        logical_h = round(monitor["height"] / monitor["scale"])
        assert (logical_w, logical_h) == (1707, 960)

        # A maximised window in logical space fills the logical size exactly.
        window = {"at": [0, 0], "size": [1707, 960]}
        assert window["size"][0] == logical_w

    @pytest.mark.parametrize("transform", [1, 3, 5, 7])
    def test_a_rotated_monitor_swaps_its_dimensions(self, transform):
        """Hyprland reports the mode unrotated, but a quarter-turned monitor
        occupies its height in width. Confirmed on a live compositor: a second
        output auto-placed beside a transform-3 1920x1080 screen landed 1080px
        along, not 1920."""
        from hyprpages.hypr import _logical_size

        size = _logical_size({"width": 1920, "height": 1080, "scale": 1, "transform": transform})
        assert (size["logicalWidth"], size["logicalHeight"]) == (1080, 1920)

    @pytest.mark.parametrize("transform", [0, 2, 4, 6])
    def test_upright_and_flipped_monitors_keep_their_shape(self, transform):
        from hyprpages.hypr import _logical_size

        size = _logical_size({"width": 1920, "height": 1080, "scale": 1, "transform": transform})
        assert (size["logicalWidth"], size["logicalHeight"]) == (1920, 1080)

    def test_rotation_and_scaling_together(self):
        from hyprpages.hypr import _logical_size

        size = _logical_size({"width": 2560, "height": 1440, "scale": 2, "transform": 1})
        assert (size["logicalWidth"], size["logicalHeight"]) == (720, 1280)

    def test_unscaled_monitors_are_unaffected(self):
        monitor = {"width": 2560, "height": 1440, "scale": 1}
        assert round(monitor["width"] / monitor["scale"]) == monitor["width"]

    def test_negative_origins_are_handled(self):
        """A monitor left of the primary has a negative x; the bounding box has
        to shift rather than clip it."""
        offset = [
            {"name": "A", "x": -1920, "y": 0, "width": 1920, "height": 1080},
            {"name": "B", "x": 0, "y": 0, "width": 2560, "height": 1440},
        ]
        min_x, _, max_x, _ = self.bounds(offset)
        assert (min_x, max_x) == (-1920, 2560)
        # Drawing subtracts min_x, so the leftmost screen lands at zero.
        assert offset[0]["x"] - min_x == 0
