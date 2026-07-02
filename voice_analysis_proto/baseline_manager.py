import json
import os
from datetime import datetime


def get_baseline_path(path=None):
    if path:
        return path
    return os.path.join(os.path.dirname(__file__), "baseline.json")


def save_baseline(average_pitch_hz, path=None):
    if not isinstance(average_pitch_hz, (int, float)) or average_pitch_hz <= 0:
        raise ValueError("Invalid baseline pitch.")

    baseline = {
        "average_pitch_hz": float(average_pitch_hz),
        "recorded_at": datetime.utcnow().isoformat() + "Z",
    }

    target_path = get_baseline_path(path)
    with open(target_path, "w", encoding="utf-8") as handle:
        json.dump(baseline, handle, indent=2)

    return baseline


def load_baseline(path=None):
    target_path = get_baseline_path(path)
    if not os.path.exists(target_path):
        raise FileNotFoundError(f"Baseline file not found: {target_path}")

    with open(target_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise ValueError("Invalid baseline data format.")

    average_pitch = data.get("average_pitch_hz")
    if not isinstance(average_pitch, (int, float)) or average_pitch <= 0:
        raise ValueError("Invalid baseline data.")

    return {"average_pitch_hz": float(average_pitch)}
