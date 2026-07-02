import numpy as np

try:
    import librosa
except Exception:  # pragma: no cover - optional dependency
    librosa = None


def get_audio_metrics(audio_chunk):
    audio = np.asarray(audio_chunk, dtype=np.float32).reshape(-1)
    if audio.size == 0:
        raise ValueError("Audio chunk is empty.")

    peak_amplitude = float(np.max(np.abs(audio)))
    rms_amplitude = float(np.sqrt(np.mean(np.square(audio))))
    return {
        "peak_amplitude": peak_amplitude,
        "rms_amplitude": rms_amplitude,
        "signal_strength": round(max(peak_amplitude, rms_amplitude), 6),
    }


def _parabolic_peak_offset(values, index):
    if index <= 0 or index >= values.size - 1:
        return 0.0

    left = values[index - 1]
    center = values[index]
    right = values[index + 1]
    denominator = left - 2 * center + right
    if abs(denominator) < 1e-12:
        return 0.0

    return float(0.5 * (left - right) / denominator)


def detect_pitch(
    audio_chunk,
    sample_rate=16000,
    min_freq=80.0,
    max_freq=500.0,
    min_peak_amplitude=0.0005,
    min_rms_amplitude=0.00005,
    min_correlation=0.12,
):
    audio = np.asarray(audio_chunk, dtype=np.float32).reshape(-1)
    if audio.size == 0:
        raise ValueError("Audio chunk is empty.")

    metrics = get_audio_metrics(audio)
    peak_amplitude = metrics["peak_amplitude"]
    rms_amplitude = metrics["rms_amplitude"]
    if peak_amplitude < min_peak_amplitude or rms_amplitude < min_rms_amplitude:
        raise ValueError(
            "Audio too quiet. "
            f"Peak amplitude {peak_amplitude:.6f}, RMS amplitude {rms_amplitude:.6f}. "
            "Increase microphone gain or speak closer to the mic."
        )

    audio = audio - float(np.mean(audio))
    audio = audio / max(peak_amplitude, 1e-4)

    if librosa is not None:
        try:
            pitches, voiced_flags, voiced_probs = librosa.pyin(audio, fmin=min_freq, fmax=max_freq, sr=sample_rate)
            voiced = np.isfinite(pitches) & voiced_flags & (voiced_probs >= 0.1)
            if np.any(voiced):
                return float(np.median(pitches[voiced]))
        except Exception:
            pass

        try:
            pitches = librosa.yin(audio, fmin=min_freq, fmax=max_freq, sr=sample_rate)
            pitches = pitches[np.isfinite(pitches)]
            if pitches.size:
                return float(np.median(pitches))
        except Exception:
            pass

    max_lag = min(max(2, len(audio) // 2), int(sample_rate / min_freq))
    min_lag = max(1, min(max_lag - 1, int(sample_rate / max_freq)))
    if max_lag <= min_lag:
        raise ValueError("Pitch range is invalid.")

    window = np.hanning(audio.size).astype(np.float32)
    windowed = audio * window
    lag_values = np.arange(min_lag, max_lag + 1)
    correlations = []
    for lag in lag_values:
        first = windowed[:-lag]
        second = windowed[lag:]
        energy = float(np.sqrt(np.sum(first * first) * np.sum(second * second)))
        if energy <= 1e-12:
            correlations.append(0.0)
        else:
            correlations.append(float(np.sum(first * second) / energy))

    correlation_segment = np.asarray(correlations, dtype=np.float32)
    if correlation_segment.size == 0:
        raise ValueError("Unable to estimate pitch.")

    best_index = int(np.argmax(correlation_segment))
    best_correlation = float(correlation_segment[best_index])
    if best_correlation < min_correlation:
        raise ValueError(f"Unable to detect a clear voiced pitch. Correlation {best_correlation:.3f}.")

    lag = float(lag_values[best_index]) + _parabolic_peak_offset(correlation_segment, best_index)
    if lag <= 0:
        raise ValueError("Unable to estimate pitch.")

    return float(sample_rate / lag)
