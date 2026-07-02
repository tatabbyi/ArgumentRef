from pitch_detector import detect_pitch, get_audio_metrics
from hume_placeholder import analyze_tone_with_hume


def analyze_voice_chunk(
    audio_chunk,
    baseline,
    sample_rate=16000,
    slightly_above_threshold=1.08,
    much_above_threshold=1.15,
    minimum_hz_delta=10.0,
):
    if not isinstance(baseline, dict):
        raise ValueError("Baseline must be a dictionary.")

    baseline_pitch = baseline.get("average_pitch_hz")
    if not isinstance(baseline_pitch, (int, float)) or baseline_pitch <= 0:
        raise ValueError("Invalid baseline.")

    metrics = get_audio_metrics(audio_chunk)
    try:
        current_pitch = detect_pitch(audio_chunk, sample_rate=sample_rate)
    except ValueError as exc:
        return {
            "current_pitch": None,
            "baseline_pitch": float(baseline_pitch),
            "pitch_status": "no_voice_detected",
            "message": str(exc),
            "signal_strength": metrics["signal_strength"],
            "tone_analysis": analyze_tone_with_hume(audio_chunk),
        }

    delta_hz = current_pitch - float(baseline_pitch)
    ratio = current_pitch / float(baseline_pitch)
    percent_change = (ratio - 1.0) * 100.0
    if ratio >= much_above_threshold or delta_hz >= minimum_hz_delta * 2.5:
        status = "much_higher"
        message = "Your voice is much higher than usual."
    elif ratio >= slightly_above_threshold or delta_hz >= minimum_hz_delta:
        status = "slightly_higher"
        message = "Your voice is slightly higher than usual."
    else:
        status = "normal"
        message = "Your voice is within the normal range."

    return {
        "current_pitch": round(current_pitch, 2),
        "baseline_pitch": round(float(baseline_pitch), 2),
        "delta_hz": round(delta_hz, 2),
        "percent_change": round(percent_change, 1),
        "pitch_status": status,
        "message": message,
        "signal_strength": metrics["signal_strength"],
        "tone_analysis": analyze_tone_with_hume(audio_chunk),
    }
