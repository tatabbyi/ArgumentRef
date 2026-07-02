# Argument Referee Backend

This backend accepts live audio streams from the mobile app over WebSocket. If `DEEPGRAM_API_KEY` is configured, it also forwards those audio chunks to Deepgram streaming speech-to-text and emits transcript events with speaker labels.

Important: the phone should not depend on a laptop in real use. Running this service on `localhost` is only for development. For actual mobile testing outside your laptop, deploy this backend to a public host and connect the app to a `wss://.../v1/audio` URL.

## Run

```sh
npm install
npm run dev
```

Default endpoints:

- Health: `http://localhost:8081/health`
- Audio WebSocket: `ws://localhost:8081/v1/audio`

For a deployed backend, use:

- Health: `https://your-backend.example.com/health`
- Audio WebSocket: `wss://your-backend.example.com/v1/audio`

## Audio Stream Protocol

Connect the mobile app to:

```text
ws://localhost:8081/v1/audio?sessionId=demo-session&participantId=device-1&encoding=pcm16&sampleRateHz=16000&channels=1
```

For a real phone with no laptop dependency, this must become a hosted URL:

```text
wss://your-backend.example.com/v1/audio?sessionId=demo-session&participantId=device-1&encoding=pcm16&sampleRateHz=16000&channels=1
```

After the WebSocket opens, the server sends:

```json
{
  "type": "session.started",
  "sessionId": "demo-session",
  "streamId": "...",
  "participantId": "device-1",
  "audio": {
    "encoding": "pcm16",
    "sampleRateHz": 16000,
    "channels": 1
  },
  "acceptedBinaryAudio": true
}
```

The mobile client should then send audio chunks as binary WebSocket messages. The server replies with:

```json
{
  "type": "audio.ack",
  "sessionId": "demo-session",
  "streamId": "...",
  "bytesReceived": 4096,
  "chunksReceived": 1
}
```

If Deepgram is enabled, the server also emits:

```json
{
  "type": "transcription.connected",
  "provider": "deepgram",
  "sessionId": "demo-session",
  "streamId": "...",
  "model": "nova-3",
  "language": "en-US"
}
```

And transcript events:

```json
{
  "type": "transcript.final",
  "provider": "deepgram",
  "sessionId": "demo-session",
  "streamId": "...",
  "speaker": "speaker_0",
  "text": "The budget increased by 20 percent.",
  "startMs": 12400,
  "endMs": 15900,
  "words": []
}
```

To flush metadata without ending the connection, send:

```json
{ "type": "audio.commit" }
```

To end the stream cleanly, send:

```json
{ "type": "session.stop" }
```

Received streams are written under `data/sessions/<sessionId>/` with a `.audio` file and matching JSON metadata. `data/` is intentionally ignored by Git.

## Environment

```sh
PORT=8081
HOST=0.0.0.0
AUDIO_STORAGE_DIR=data/sessions
MAX_AUDIO_CHUNK_BYTES=1048576
DEEPGRAM_API_KEY=
DEEPGRAM_MODEL=nova-3
DEEPGRAM_LANGUAGE=en-US
```

## Deploy to Render

The repo includes a root-level `render.yaml` and this backend includes a `Dockerfile`. That means Render can create the service from the repository automatically.

Steps:

1. Push this repo to GitHub.
2. In Render, create a new Blueprint from the GitHub repo.
3. Render reads `render.yaml` and creates the `argumentref-backend` web service.
4. Wait for the first deploy to finish.
5. Copy the service URL Render gives you, for example:

```text
https://argumentref-backend.onrender.com
```

The mobile WebSocket endpoint is the same URL with `https` changed to `wss` and `/v1/audio` added:

```text
wss://argumentref-backend.onrender.com/v1/audio
```

The user does not type this URL into the mobile app. The frontend team should put it in app configuration, for example:

```sh
flutter run --dart-define=ARGUMENTREF_BACKEND_WSS=wss://argumentref-backend.onrender.com/v1/audio
```

For production builds, the same value should be set by the build pipeline or app config, not a visible text box.

Local Docker test:

```sh
docker build -t argumentref-backend .
docker run --rm -p 8081:8081 argumentref-backend
```

Any host that supports a Node service or Docker container will work. Good student-project choices are Render, Fly.io, Railway, Google Cloud Run, or AWS ECS/App Runner.

Production requirements:

- Use HTTPS/WSS, not plain HTTP/WS.
- Store API keys on the backend only.
- Do not point the phone at `localhost`.
- Persist session audio somewhere durable if you need replay, for example S3, Cloud Storage, or a database-backed object store. The current Render free setup writes temporary audio under `/tmp`, which is fine for ingestion testing but not permanent storage.

Future environment variables:

```sh
DEEPGRAM_API_KEY=...
DATABASE_URL=...
PERPLEXITY_API_KEY=...
```

Add `DEEPGRAM_API_KEY` in Render's Environment tab to activate transcription. Do not put it in the Flutter app.

For the first mobile-to-Deepgram test, send raw PCM 16-bit mono audio:

```text
wss://argumentref-backend.onrender.com/v1/audio?sessionId=demo-session&participantId=device-1&encoding=pcm16&sampleRateHz=16000&channels=1
```

Deepgram diarization is enabled with `diarize_model=latest`.

## Fully On-Device Mode

If the app must work with no internet connection at all, this backend is not part of that path. The phone would need on-device speech recognition. That can produce a transcript, but reliable speaker diarization on one phone is much harder and usually needs a cloud diarization service or a heavy native ML model. For v1, the professional recommendation is:

1. On-device mode: transcript only, maybe manual speaker tagging.
2. Cloud mode: transcript plus real speaker diarization through Deepgram or another provider.

## Verify

```sh
npm run lint
npm test
```

## Test Deepgram Transcript Events

After the Render service has `DEEPGRAM_API_KEY` configured and redeployed, test transcript events with an audio file that contains clear speech.

For a WAV or encoded audio file:

```sh
npm run test:remote-audio -- --file ./sample.wav
```

For raw PCM16 mono audio:

```sh
npm run test:remote-audio -- --file ./sample.pcm --encoding pcm16 --sampleRateHz 16000 --channels 1
```

The command connects to:

```text
wss://argumentref-backend.onrender.com/v1/audio
```

Expected output:

```json
{"type":"session.started", "...":"..."}
{"type":"transcription.connected", "provider":"deepgram", "...":"..."}
{"type":"transcript.partial", "speaker":"speaker_0", "text":"..."}
{"type":"transcript.final", "speaker":"speaker_0", "text":"..."}
{"type":"claim.detected", "speaker":"speaker_0", "text":"...", "reason":"contains_number"}
```

For speaker diarization, use audio with two clearly different speakers. Deepgram labels them as `speaker_0`, `speaker_1`, and so on. It does not know real names unless the app maps those labels later.

## Next Step

The backend now detects checkable claims from `transcript.final` events and emits `claim.detected`. The next module should send those queued claims to a fact-checking provider. The frontend should consume normalized transcript and claim events from the backend, not talk to Deepgram directly.
