import json
import os
from datetime import datetime


def get_baseline_path(path=None):
    if path:
        return path
    return os.path.join(os.path.dirname(__file__), "baseline.json")


def save_baseline(average_rms_amplitude, average_peak_amplitude, path=None):
    if not isinstance(average_rms_amplitude, (int, float)) or average_rms_amplitude <= 0:
        raise ValueError("Invalid baseline RMS volume.")
    if not isinstance(average_peak_amplitude, (int, float)) or average_peak_amplitude <= 0:
        raise ValueError("Invalid baseline peak volume.")

    baseline = {
        "average_rms_amplitude": float(average_rms_amplitude),
        "average_peak_amplitude": float(average_peak_amplitude),
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

    average_rms = data.get("average_rms_amplitude")
    average_peak = data.get("average_peak_amplitude")
    if not isinstance(average_rms, (int, float)) or average_rms <= 0:
        raise ValueError("Invalid volume baseline data. Run baseline mode again.")
    if not isinstance(average_peak, (int, float)) or average_peak <= 0:
        raise ValueError("Invalid volume baseline data. Run baseline mode again.")

    return {
        "average_rms_amplitude": float(average_rms),
        "average_peak_amplitude": float(average_peak),
    }
