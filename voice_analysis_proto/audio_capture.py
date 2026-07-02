import numpy as np
import sounddevice as sd


DEFAULT_SAMPLE_RATE = 16000
DEFAULT_CHANNELS = 1


def get_input_devices():
    try:
        devices = sd.query_devices()
    except Exception:
        return []

    if not isinstance(devices, (list, tuple)):
        return []

    return [device for device in devices if isinstance(device, dict) and device.get("max_input_channels", 0) > 0]


def has_microphone():
    return bool(get_input_devices())


def record_audio_chunk(duration=0.5, sample_rate=DEFAULT_SAMPLE_RATE, channels=DEFAULT_CHANNELS):
    if not has_microphone():
        raise RuntimeError("No microphone found. Please connect a microphone and allow access.")

    try:
        audio = sd.rec(int(duration * sample_rate), samplerate=sample_rate, channels=channels, dtype="float32")
        sd.wait()
    except Exception as exc:
        raise RuntimeError(f"Unable to read microphone audio: {exc}") from exc

    if audio.ndim > 1:
        audio = audio[:, 0]

    audio = np.asarray(audio, dtype=np.float32)
    if audio.size == 0:
        raise ValueError("Captured audio is empty.")

    return audio
