import math

from hume_placeholder import analyze_tone_with_hume
from pitch_detector import detect_pitch, get_audio_metrics


def _classify_pitch_change(current_pitch, baseline_pitch):
    if not isinstance(current_pitch, (int, float)) or current_pitch <= 0:
        return "no_voice_detected", None, "No clear voice pitch detected."

    delta_hz = float(current_pitch) - float(baseline_pitch)
    if delta_hz >= 20:
        return "much_higher", round(delta_hz, 2), "Your pitch is much higher than your baseline."
    if delta_hz >= 10:
        return "slightly_higher", round(delta_hz, 2), "Your pitch is slightly higher than your baseline."
    if delta_hz <= -20:
        return "much_lower", round(delta_hz, 2), "Your pitch is much lower than your baseline."
    if delta_hz <= -10:
        return "slightly_lower", round(delta_hz, 2), "Your pitch is slightly lower than your baseline."
    return "normal", round(delta_hz, 2), "Your pitch is within your normal range."


def analyze_voice_chunk(
    audio_chunk,
    baseline,
    sample_rate=16000,  # Kept for API compatibility with main.py.
    slightly_louder_db=3.0,
    much_louder_db=6.0,
    quieter_db=-6.0,
    silence_rms_floor=0.00005,
):
    if not isinstance(baseline, dict):
        raise ValueError("Baseline must be a dictionary.")

    metrics = get_audio_metrics(audio_chunk)
    current_rms = metrics["rms_amplitude"]
    current_peak = metrics["peak_amplitude"]
    signal_strength = metrics["signal_strength"]
    tone_analysis = analyze_tone_with_hume(audio_chunk)

    baseline_rms = baseline.get("average_rms_amplitude")
    baseline_peak = baseline.get("average_peak_amplitude")
    baseline_pitch = baseline.get("average_pitch_hz")

    volume_result = {
        "current_rms_amplitude": round(current_rms, 6),
        "current_peak_amplitude": round(current_peak, 6),
        "volume_ratio": None,
        "db_change": None,
        "percent_change": None,
        "volume_status": "baseline_unavailable",
        "message": "Volume baseline data is not available.",
    }

    if isinstance(baseline_rms, (int, float)) and baseline_rms > 0:
        if not isinstance(baseline_peak, (int, float)) or baseline_peak <= 0:
            baseline_peak = baseline_rms

        noise_floor = max(silence_rms_floor, float(baseline_rms) * 0.05)
        if current_rms < noise_floor:
            volume_result.update(
                {
                    "baseline_rms_amplitude": round(float(baseline_rms), 6),
                    "baseline_peak_amplitude": round(float(baseline_peak), 6),
                    "volume_ratio": 0.0,
                    "db_change": None,
                    "volume_status": "no_voice_detected",
                    "message": "No clear voice volume detected.",
                }
            )
        else:
            volume_ratio = current_rms / float(baseline_rms)
            db_change = 20.0 * math.log10(volume_ratio)
            percent_change = (volume_ratio - 1.0) * 100.0

            if db_change >= much_louder_db:
                status = "much_louder"
                message = "Your voice is much louder than your baseline."
            elif db_change >= slightly_louder_db:
                status = "slightly_louder"
                message = "Your voice is louder than your baseline."
            elif db_change <= quieter_db:
                status = "quieter"
                message = "Your voice is quieter than your baseline."
            else:
                status = "normal"
                message = "Your voice volume is within your normal range."

            volume_result.update(
                {
                    "baseline_rms_amplitude": round(float(baseline_rms), 6),
                    "baseline_peak_amplitude": round(float(baseline_peak), 6),
                    "volume_ratio": round(volume_ratio, 2),
                    "db_change": round(db_change, 2),
                    "percent_change": round(percent_change, 1),
                    "volume_status": status,
                    "message": message,
                }
            )
    else:
        volume_result["baseline_rms_amplitude"] = round(float(baseline_rms), 6) if isinstance(baseline_rms, (int, float)) else None
        volume_result["baseline_peak_amplitude"] = round(float(baseline_peak), 6) if isinstance(baseline_peak, (int, float)) else None

    try:
        current_pitch = detect_pitch(audio_chunk, sample_rate=sample_rate)
    except ValueError:
        pitch_status = "no_voice_detected"
        current_pitch = None
        delta_hz = None
        pitch_message = "No clear voice pitch detected."
    else:
        if not isinstance(baseline_pitch, (int, float)) or baseline_pitch <= 0:
            baseline_pitch = current_pitch
        pitch_status, delta_hz, pitch_message = _classify_pitch_change(current_pitch, baseline_pitch)

    return {
        **volume_result,
        "pitch_status": pitch_status,
        "current_pitch": current_pitch,
        "baseline_pitch": round(float(baseline_pitch), 2) if isinstance(baseline_pitch, (int, float)) and baseline_pitch > 0 else None,
        "delta_hz": delta_hz,
        "pitch_message": pitch_message,
        "signal_strength": signal_strength,
        "tone_analysis": tone_analysis,
    }
