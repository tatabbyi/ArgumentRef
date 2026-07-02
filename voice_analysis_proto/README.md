# Voice Analysis Prototype

This project is a modular Python prototype for detecting when a voice becomes higher in pitch than a saved baseline. It is designed so Hume AI EVI can be added later for emotional tone and prosody analysis.

## Project structure

- main.py - CLI entrypoint for baseline capture and live monitoring
- audio_capture.py - microphone audio capture helpers
- pitch_detector.py - pitch estimation from audio chunks
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

This records your voice for 30 seconds and saves the average pitch to baseline.json.

```bash
python main.py --mode baseline --duration 30
```

## Run live monitoring mode

This loads the saved baseline and compares the current pitch against it in real time.

```bash
python main.py --mode live
```

## Example output

```json
{
  "current_pitch": 245.2,
  "baseline_pitch": 180.0,
  "pitch_status": "much_higher",
  "message": "Your voice is much higher than usual."
}
```

## Hume AI EVI preparation

The placeholder module is ready for future integration:

- [hume_placeholder.py](hume_placeholder.py)

Later, the analyze_tone_with_hume(audio_chunk) function can be replaced with a WebSocket or REST-based Hume EVI connection for emotional tone and prosody analysis.
