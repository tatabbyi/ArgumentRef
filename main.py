import argparse
import json
import sys

import numpy as np

from audio_capture import record_audio_chunk
from baseline_manager import load_baseline, save_baseline
from pitch_detector import get_audio_metrics
from voice_analyzer import analyze_voice_chunk


def run_baseline(duration=30.0, block_duration=1.0, sample_rate=16000, baseline_path=None):
    print(f"Baseline mode: speak normally for {duration:.0f} seconds...")

    rms_values = []
    peak_values = []
    total_blocks = int(duration / block_duration)
    for index in range(total_blocks):
        try:
            chunk = record_audio_chunk(duration=block_duration, sample_rate=sample_rate)
            metrics = get_audio_metrics(chunk)
            if metrics["rms_amplitude"] < 0.00005:
                raise ValueError("Audio too quiet. Speak normally into the microphone.")
            rms_values.append(metrics["rms_amplitude"])
            peak_values.append(metrics["peak_amplitude"])
            print(
                f"Block {index + 1}/{total_blocks}: "
                f"RMS volume {metrics['rms_amplitude']:.6f}, peak {metrics['peak_amplitude']:.6f}"
            )
        except (RuntimeError, ValueError) as exc:
            print(f"Skipping block {index + 1}/{total_blocks}: {exc}")
            continue

    if not rms_values:
        raise RuntimeError("No voice volume was detected during baseline recording.")

    average_rms = float(np.mean(rms_values))
    average_peak = float(np.mean(peak_values))
    baseline = save_baseline(average_rms, average_peak, path=baseline_path)
    print(
        f"Baseline saved: RMS volume {baseline['average_rms_amplitude']:.6f}, "
        f"peak {baseline['average_peak_amplitude']:.6f}"
    )
    return baseline


def run_live_monitoring(block_duration=1.0, sample_rate=16000, baseline_path=None):
    try:
        baseline = load_baseline(path=baseline_path)
    except FileNotFoundError as exc:
        raise FileNotFoundError("Baseline file is missing. Run baseline mode first.") from exc

    print("Live monitoring mode: press Ctrl+C to stop")
    print(
        f"Using baseline RMS volume: {baseline['average_rms_amplitude']:.6f} "
        f"(peak {baseline['average_peak_amplitude']:.6f})"
    )

    try:
        while True:
            try:
                chunk = record_audio_chunk(duration=block_duration, sample_rate=sample_rate)
                result = analyze_voice_chunk(chunk, baseline, sample_rate=sample_rate)
            except (RuntimeError, ValueError) as exc:
                result = {
                    "current_rms_amplitude": None,
                    "baseline_rms_amplitude": baseline.get("average_rms_amplitude"),
                    "volume_status": "no_voice_detected",
                    "message": str(exc),
                    "signal_strength": None,
                }

            baseline_volume = result.get("baseline_rms_amplitude")
            current_volume = result.get("current_rms_amplitude")
            if current_volume is not None and baseline_volume is not None:
                db_change = result.get("db_change")
                percent_change = result.get("percent_change")
                db_display = f", {db_change:+.2f} dB" if db_change is not None else ""
                percent_display = f", {percent_change:+.1f}%" if percent_change is not None else ""
                comparison_display = (
                    f"(baseline {baseline_volume:.6f} -> current {current_volume:.6f}"
                    f"{db_display}{percent_display})"
                )
            else:
                comparison_display = ""

            print(
                f"Current volume: {current_volume if current_volume is not None else 'n/a'} | "
                f"signal strength: {result.get('signal_strength')} | status: {result.get('volume_status')} "
                f"{comparison_display}"
            )
            print(json.dumps(result, indent=2))
    except KeyboardInterrupt:
        print("Monitoring stopped.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Voice volume analysis prototype")
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
