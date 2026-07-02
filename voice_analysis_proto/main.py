import argparse
import json
import sys

import numpy as np

from audio_capture import record_audio_chunk
from baseline_manager import load_baseline, save_baseline
from pitch_detector import detect_pitch
from voice_analyzer import analyze_voice_chunk


def run_baseline(duration=30.0, block_duration=1.0, sample_rate=16000, baseline_path=None):
    print(f"Baseline mode: speak normally for {duration:.0f} seconds...")

    pitches = []
    total_blocks = int(duration / block_duration)
    for index in range(total_blocks):
        try:
            chunk = record_audio_chunk(duration=block_duration, sample_rate=sample_rate)
            pitch = detect_pitch(chunk, sample_rate=sample_rate)
            pitches.append(pitch)
            print(f"Block {index + 1}/{total_blocks}: detected pitch {pitch:.2f} Hz")
        except (RuntimeError, ValueError) as exc:
            print(f"Skipping block {index + 1}/{total_blocks}: {exc}")
            continue

    if not pitches:
        raise RuntimeError("No voice data was detected during baseline recording.")

    average_pitch = float(np.mean(pitches))
    baseline = save_baseline(average_pitch, path=baseline_path)
    print(f"Baseline saved: {baseline['average_pitch_hz']:.2f} Hz")
    return baseline


def run_live_monitoring(block_duration=1.0, sample_rate=16000, baseline_path=None):
    try:
        baseline = load_baseline(path=baseline_path)
    except FileNotFoundError as exc:
        raise FileNotFoundError("Baseline file is missing. Run baseline mode first.") from exc

    print("Live monitoring mode: press Ctrl+C to stop")
    print(f"Using baseline pitch: {baseline['average_pitch_hz']:.2f} Hz")

    try:
        while True:
            try:
                chunk = record_audio_chunk(duration=block_duration, sample_rate=sample_rate)
                result = analyze_voice_chunk(chunk, baseline, sample_rate=sample_rate)
            except (RuntimeError, ValueError) as exc:
                result = {
                    "current_pitch": None,
                    "baseline_pitch": baseline["average_pitch_hz"],
                    "pitch_status": "no_voice_detected",
                    "message": str(exc),
                    "signal_strength": None,
                }

            delta_hz = result.get("delta_hz")
            baseline_pitch = result.get("baseline_pitch")
            current_pitch = result.get("current_pitch")
            if current_pitch is not None and baseline_pitch is not None:
                percent_change = result.get("percent_change")
                percent_display = f", {percent_change:+.1f}%" if percent_change is not None else ""
                delta_display = f"(baseline {baseline_pitch:.2f} Hz -> current {current_pitch:.2f} Hz, delta {delta_hz:+.2f} Hz{percent_display})"
            else:
                delta_display = ""

            print(
                f"Detected pitch: {current_pitch if current_pitch is not None else 'n/a'} Hz | "
                f"signal strength: {result.get('signal_strength')} | status: {result.get('pitch_status')} {delta_display}"
            )
            print(json.dumps(result, indent=2))
    except KeyboardInterrupt:
        print("Monitoring stopped.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Voice pitch analysis prototype")
    parser.add_argument("--mode", choices=["baseline", "live"], default="live")
    parser.add_argument("--duration", type=float, default=30.0, help="Baseline recording duration in seconds")
    parser.add_argument("--block-duration", type=float, default=1.0, help="Audio chunk size in seconds")
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--baseline-path", default=None, help="Path to the baseline JSON file")
    args = parser.parse_args()

    try:
        if args.mode == "baseline":
            run_baseline(
                duration=args.duration,
                block_duration=args.block_duration,
                sample_rate=args.sample_rate,
                baseline_path=args.baseline_path,
            )
        else:
            run_live_monitoring(
                block_duration=args.block_duration,
                sample_rate=args.sample_rate,
                baseline_path=args.baseline_path,
            )
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
