"""Tests for mapping a window class to an application icon.

Built against a fake XDG tree rather than the machine's own applications, so
the expectations do not depend on what happens to be installed.
"""

from __future__ import annotations

import pytest

from hyprpages import desktop

ENTRIES = {
    "kitty.desktop": "[Desktop Entry]\nName=kitty\nIcon=kitty\n",
    "google-chrome.desktop": (
        "[Desktop Entry]\nName=Google Chrome\nIcon=google-chrome\n"
        "StartupWMClass=Google-chrome\nExec=/usr/bin/google-chrome-stable %U\n"
        "Actions=new-window;\n"
        "\n[Desktop Action new-window]\nName=New Window\nIcon=chrome-action-icon\n"
        "Exec=/usr/bin/google-chrome-stable\n"
    ),
    "org.qbittorrent.qBittorrent.desktop": (
        "[Desktop Entry]\nName=qBittorrent\nIcon=qbittorrent\n"
    ),
    "steam.desktop": "[Desktop Entry]\nName=Steam\nIcon=steam\n",
    "noicon.desktop": "[Desktop Entry]\nName=Nothing\n",
    "onlyprivate.desktop": (
        "[Desktop Entry]\nName=Private Only\nIcon=p\nExec=/usr/bin/p\n"
        "Actions=new-private-window;\n"
        "\n[Desktop Action new-private-window]\nName=New Incognito\nExec=/usr/bin/p --incognito\n"
    ),
    "term.desktop": (
        "[Desktop Entry]\nName=Term\nIcon=t\nExec=/usr/bin/term\n"
        "Categories=System;TerminalEmulator;\n"
    ),
    "withcodes.desktop": (
        "[Desktop Entry]\nName=Thing\nIcon=t\nExec=/usr/bin/thing %U\n"
        "Actions=new-window;\n"
        "\n[Desktop Action new-window]\nName=New Window\nExec=/usr/bin/thing --new-window %U\n"
    ),
}


@pytest.fixture(autouse=True)
def fake_applications(tmp_path, monkeypatch):
    apps = tmp_path / "applications"
    apps.mkdir()
    for name, body in ENTRIES.items():
        (apps / name).write_text(body)
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_DIRS", str(tmp_path))
    desktop.clear_cache()
    yield
    desktop.clear_cache()


class TestIconFor:
    def test_exact_entry_name(self):
        assert desktop.icon_for("kitty") == "kitty"

    def test_startup_wm_class_wins(self):
        """Chrome's class is Google-chrome, which matches no filename."""
        assert desktop.icon_for("Google-chrome") == "google-chrome"

    def test_matching_is_case_insensitive(self):
        assert desktop.icon_for("GOOGLE-CHROME") == "google-chrome"

    def test_reverse_dns_class_falls_back_to_its_tail(self):
        assert desktop.icon_for("org.qbittorrent.qBittorrent") == "qbittorrent"

    def test_chrome_web_app_uses_the_browser_icon(self):
        """These classes encode a site, not an application."""
        assert desktop.icon_for("chrome-web.whatsapp.com__-Default") == "google-chrome"

    def test_suffixed_class_falls_back_to_its_first_word(self):
        assert desktop.icon_for("steam_app_battlenet") == "steam"

    def test_process_name_rescues_a_custom_class(self):
        """`kitty --class restore-terms` is still kitty; the class alone
        resolves to nothing at all."""
        assert desktop.icon_for("restore-terms") == ""
        assert desktop.icon_for("restore-terms", "kitty") == "kitty"

    def test_class_is_preferred_over_process(self):
        assert desktop.icon_for("steam", "kitty") == "steam"

    def test_unknown_class_yields_empty_string(self):
        assert desktop.icon_for("no-such-application") == ""

    def test_empty_input_is_safe(self):
        assert desktop.icon_for("") == ""
        assert desktop.icon_for("", "") == ""

    def test_entry_without_an_icon_is_skipped(self):
        assert desktop.icon_for("noicon") == ""


class TestEntryParsing:
    def test_only_the_main_group_is_read(self):
        """Desktop actions repeat Icon=; letting them through would give
        Chrome its "New Window" action icon."""
        fields = desktop._entry_fields(ENTRIES["google-chrome.desktop"])
        assert fields["Icon"] == "google-chrome"

    def test_comments_and_blank_lines_are_ignored(self):
        fields = desktop._entry_fields("[Desktop Entry]\n# a comment\n\nIcon=x\n")
        assert fields == {"Icon": "x"}

    def test_values_containing_equals_are_kept_whole(self):
        fields = desktop._entry_fields("[Desktop Entry]\nExec=app --flag=value\n")
        assert fields["Exec"] == "app --flag=value"


class TestIndexCaching:
    def test_index_is_cached_between_calls(self):
        first = desktop.icon_index()
        assert desktop.icon_index() is first


class TestNewWindow:
    """An application that ships a "new window" action can have several at
    once. That is the difference between "add Chrome here", which means another
    window, and "add Spotify here", which can only mean the one that exists."""

    def test_an_entry_without_the_action_says_so(self):
        assert desktop.new_window_command("kitty.desktop") == []

    def test_an_action_that_adds_nothing_asks_for_a_window_explicitly(self):
        """Chrome's action Exec is the bare binary, identical to its main one --
        running that again only raises the window it already has."""
        assert desktop.new_window_command("google-chrome.desktop") == [
            "/usr/bin/google-chrome-stable",
            "--new-window",
        ]

    def test_a_private_window_action_is_not_a_new_window(self):
        assert desktop.new_window_command("onlyprivate.desktop") == []

    def test_field_codes_are_dropped(self):
        """%U stands for the files being opened, and there are none."""
        assert desktop.new_window_command("withcodes.desktop") == ["/usr/bin/thing", "--new-window"]

    def test_a_terminal_counts_even_without_an_action(self):
        """foot and kitty ship no actions at all, and opening a second terminal
        is the most ordinary thing on the desktop."""
        assert desktop.is_multi_window("term.desktop") is True
        assert desktop.new_window_command("term.desktop") == []

    def test_an_ordinary_app_is_assumed_single_window(self):
        assert desktop.is_multi_window("kitty.desktop") is False
        assert desktop.is_multi_window("google-chrome.desktop") is True

    def test_applications_carry_the_flag(self):
        entries = {a["id"]: a for a in desktop.applications()}
        assert entries["google-chrome.desktop"]["newWindow"] is True
        assert entries["kitty.desktop"]["newWindow"] is False
        assert entries["term.desktop"]["newWindow"] is True
