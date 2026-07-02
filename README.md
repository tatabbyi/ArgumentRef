# Voice Analysis Prototype

This project is a modular Python prototype for detecting when a voice becomes louder or quieter than a saved baseline. It uses microphone volume instead of pitch, so it is not biased by natural differences between lower and higher voices. It is designed so Hume AI EVI can be added later for emotional tone and prosody analysis.

## Project structure

- main.py - CLI entrypoint for baseline capture and live monitoring
- audio_capture.py - microphone audio capture helpers
- pitch_detector.py - audio metrics and optional pitch estimation helpers
- baseline_manager.py - baseline save/load logic in JSON
- voice_analyzer.py - reusable voice analysis logic
- hume_placeholder.py - placeholder for future Hume EVI integration
- requirements.txt - Python dependencies

## Setup

1. Create and activate a Python virtual environment (recommended):
   - python -m venv .venv
   - .venv\Scripts\activate

2. Install dependencies:
   - pip install -r requirements.txt

3. If you do not have a microphone, the app will report a clear error message.

## Run baseline mode

This records your normal speaking volume for 30 seconds and saves the average RMS/peak microphone volume to baseline.json.

```bash
python main.py --mode baseline --duration 30
```

## Run live monitoring mode

This loads the saved baseline and compares the current microphone volume against it in real time.

```bash
python main.py --mode live
```

## Example output

```json
{
  "current_rms_amplitude": 0.132,
  "baseline_rms_amplitude": 0.075,
  "volume_ratio": 1.76,
  "db_change": 4.91,
  "volume_status": "slightly_louder",
  "message": "Your voice is louder than your baseline."
}
```

## Hume AI EVI preparation

The placeholder module is ready for future integration:

- [hume_placeholder.py](hume_placeholder.py)

Later, the analyze_tone_with_hume(audio_chunk) function can be replaced with a WebSocket or REST-based Hume EVI connection for emotional tone and prosody analysis.
