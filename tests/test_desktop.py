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
        "StartupWMClass=Google-chrome\n"
        "\n[Desktop Action new-window]\nName=New Window\nIcon=chrome-action-icon\n"
    ),
    "org.qbittorrent.qBittorrent.desktop": (
        "[Desktop Entry]\nName=qBittorrent\nIcon=qbittorrent\n"
    ),
    "steam.desktop": "[Desktop Entry]\nName=Steam\nIcon=steam\n",
    "noicon.desktop": "[Desktop Entry]\nName=Nothing\n",
}


@pytest.fixture(autouse=True)
def fake_applications(tmp_path, monkeypatch):
    apps = tmp_path / "applications"
    apps.mkdir()
    for name, body in ENTRIES.items():
        (apps / name).write_text(body)
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_DIRS", str(tmp_path))
    desktop.icon_index.cache_clear()
    yield
    desktop.icon_index.cache_clear()


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
