# Argument Referee

Argument Referee is a Flutter app for live conversation moderation. The current app implements the product shell from the build plan and now includes real local speech capture:

- Microphone start/stop with platform speech recognition
- Live partial transcript while someone is speaking
- Committed transcript lines when the recognizer returns final text
- Live input-level meter and detected speech-time counter
- Claim detection for statements with numbers, dates, or assertive phrasing
- Async fact-check queue cards for detected claims
- Session recap with summary metrics

Local mode captures one device microphone stream. True speaker diarization, interruption detection, and source-backed verdicts still need the Deepgram, VAD, Perplexity, and backend WebSocket adapters from the full build plan.

## Run

```sh
flutter pub get
flutter run
```

Use a real iOS or Android device for best results. Speech recognition support varies across emulators and simulators.

## Test

```sh
flutter test
```

## Next integration steps

1. Add a backend WebSocket session service for persisted sessions.
2. Stream microphone audio through the backend proxy to Deepgram for diarized speakers.
3. Feed WebRTC VAD events into the scoreboard aggregation model.
4. Send queued claim cards to a Perplexity-backed fact-check worker.
5. Push source-backed verdict updates back into the feed over WebSocket.
