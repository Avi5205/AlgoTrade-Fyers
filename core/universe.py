import os
import yaml

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETTINGS_PATH = os.path.join(PROJECT_ROOT, "config", "settings.yaml")


def load_settings():
    with open(SETTINGS_PATH, "r") as f:
        return yaml.safe_load(f)


def get_universe() -> list:
    settings = load_settings()
    u = settings.get("universe", {})
    if u.get("type") == "static":
        return u.get("symbols", [])
    return []
