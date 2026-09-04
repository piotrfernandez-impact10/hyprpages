"""Tests for building a configuration from untrusted JSON.

The editor posts a whole configuration back in one call, so `from_dict` is the
boundary where a malformed or version-skewed payload has to fail safely rather
than corrupt someone's Hyprland config.
"""

from __future__ import annotations

import pytest

from hypr_spaces.model import SpacesConfig


class TestFromDict:
    def test_reads_a_full_payload(self):
        cfg = SpacesConfig.from_dict(
            {
                "pages": 4,
                "offset": 20,
                "monitors": ["A", "B"],
                "apps": [{"pattern": "^x$", "page": 2, "monitor": "B", "label": "x"}],
            }
        )
        assert cfg.pages == 4
        assert cfg.apps[0].workspace(cfg) == 22

    def test_unknown_top_level_keys_are_ignored(self):
        """An older binary must not crash on a config from a newer one."""
        cfg = SpacesConfig.from_dict({"monitors": ["A"], "invented_later": True})
        assert cfg.monitors == ["A"]

    def test_unknown_app_keys_are_ignored(self):
        cfg = SpacesConfig.from_dict(
            {"monitors": ["A"], "apps": [{"pattern": "^x$", "page": 1, "monitor": "A", "wat": 1}]}
        )
        assert cfg.apps[0].pattern == "^x$"

    def test_empty_payload_yields_defaults(self):
        cfg = SpacesConfig.from_dict({})
        assert cfg.monitors == []
        assert cfg.apps == []

    def test_missing_required_app_field_is_an_error(self):
        """Better to refuse than to silently place a window nowhere."""
        with pytest.raises(TypeError):
            SpacesConfig.from_dict({"apps": [{"pattern": "^x$"}]})

    def test_round_trips_through_save_and_load(self, tmp_path, monkeypatch):
        monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
        source = {
            "pages": 3,
            "offset": 10,
            "monitors": ["A", "B"],
            "apps": [{"pattern": "^x$", "page": 1, "monitor": "A", "label": "x"}],
            "pair_monitors": False,
        }
        SpacesConfig.from_dict(source).save()

        restored = SpacesConfig.load()
        assert restored.pages == 3
        assert restored.pair_monitors is False
        assert restored.apps[0].pattern == "^x$"

    def test_pairing_hook_can_be_switched_off(self):
        cfg = SpacesConfig.from_dict({"monitors": ["A", "B"], "pair_monitors": False})
        assert "workspace.active" not in cfg.to_lua()
        assert "workspace_rule" in cfg.to_lua()
