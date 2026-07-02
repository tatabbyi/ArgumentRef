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

If Gemini is enabled, the backend watches the final transcript after 30 seconds,
then every 30 seconds, and emits ranked compromise ideas:

```json
{
  "type": "compromise.suggested",
  "provider": "gemini",
  "model": "gemini-3.5-flash",
  "sessionId": "demo-session",
  "streamId": "...",
  "generatedAt": "2026-07-02T12:00:00.000Z",
  "transcriptLineCount": 8,
  "suggestions": [
    {
      "id": "compromise-1-two-week-trial",
      "rank": 1,
      "title": "Two-week trial",
      "summary": "Try the new plan for two weeks, then review it together.",
      "whyItCouldWork": "It lowers commitment risk while addressing both concerns.",
      "score": 94,
      "quality": "really_good",
      "pushLevel": "urgent"
    }
  ]
}
```

It also analyzes each final sentence with `ROOM_TONE_GEMINI_MODEL`
(`gemini-3.1-flash-lite` by default) and emits fast room-tone readings:

```json
{
  "type": "room_tone.analyzed",
  "provider": "gemini",
  "model": "gemini-3.1-flash-lite",
  "sessionId": "demo-session",
  "streamId": "...",
  "generatedAt": "2026-07-02T12:00:02.000Z",
  "lineNumber": 4,
  "sentenceIndex": 1,
  "speaker": "speaker_0",
  "text": "You never listen.",
  "dominantTone": "angry",
  "trend": "escalating",
  "intensity": 86,
  "confidence": 0.91,
  "summary": "Sharp accusation",
  "signals": ["angry", "accusatory"],
  "phrases": [{ "text": "never listen", "signal": "accusatory" }]
}
```

When the stream ends, the backend also sends the final transcript to Gemini for
a full conversation debrief and writes the result locally. The debrief file
includes the raw final transcript, what the users argued about, the outcome or
solution, per-person argument traits, observable interaction characteristics,
and profile signals for the pair and each individual.

The `session.ended` event points at the local files:

```json
{
  "type": "session.ended",
  "sessionId": "demo-session",
  "streamId": "...",
  "storagePath": "data/sessions/demo-session/device-1-....audio",
  "debriefStatus": "completed",
  "debriefStoragePath": "data/sessions/demo-session/device-1-...-debrief.json",
  "profileStoragePath": "data/sessions/argument-profiles.json"
}
```

If Gemini is not configured, the backend still writes the transcript JSON with
`analysisStatus: "disabled"` and a `missing_gemini_api_key` reason. If no final
transcript arrived, it writes `analysisStatus: "skipped"`.

To flush metadata without ending the connection, send:

```json
{ "type": "audio.commit" }
```

To end the stream cleanly, send:

```json
{ "type": "session.stop" }
```

Received streams are written under `data/sessions/<sessionId>/` with a `.audio`
file, matching JSON metadata, and a `*-debrief.json` file. Aggregate argument
profiles are stored locally at `data/sessions/argument-profiles.json`. `data/`
is intentionally ignored by Git.

## Environment

For local development, put secrets in `backend/.env`. That file is ignored by
Git and loaded automatically by `npm run dev` and `npm start`.

```sh
PORT=8081
HOST=0.0.0.0
AUDIO_STORAGE_DIR=data/sessions
MAX_AUDIO_CHUNK_BYTES=1048576
DATABASE_URL=
DATABASE_SSL=false
DEEPGRAM_API_KEY=
DEEPGRAM_MODEL=nova-3
DEEPGRAM_LANGUAGE=en-US
FACT_CHECK_ENABLED=true
GOOGLE_FACT_CHECK_API_KEY=
GOOGLE_FACT_CHECK_LANGUAGE_CODE=en-US
GOOGLE_FACT_CHECK_PAGE_SIZE=3
FACT_CHECK_MAX_CLAIMS_PER_SESSION=5
GEMINI_API_KEY=
GEMINI_MODEL=gemini-3.5-flash
COMPROMISE_INITIAL_DELAY_MS=30000
COMPROMISE_INTERVAL_MS=30000
FALLACY_DETECTION_ENABLED=true
FALLACY_ANALYSIS_INTERVAL_MS=20000
FALLACY_MIN_CONFIDENCE=medium
ARGUMENT_RATING_ENABLED=true
ARGUMENT_RATING_INTERVAL_MS=30000
ARGUMENT_RATING_MIN_TRANSCRIPT_LINES=4
REFEREE_INTERVENTIONS_ENABLED=true
REFEREE_INTERVENTION_COOLDOWN_MS=10000
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

Optional private referee settings can be added as query parameters:

```text
wss://argumentref-backend.onrender.com/v1/audio?interventionStyle=gentle&fallacySensitivity=medium&factCheckStrictness=high&compromisePreference=balanced&interventionFrequency=normal
```

Supported values:

- `interventionStyle`: `gentle`, `balanced`, `direct`
- `fallacySensitivity`: `low`, `medium`, `high`
- `factCheckStrictness`: `low`, `medium`, `high`
- `compromisePreference`: `balanced`, `practical`, `fair`
- `interventionFrequency`: `low`, `normal`, `high`

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
GEMINI_API_KEY=...
DATABASE_URL=...
GOOGLE_FACT_CHECK_API_KEY=...
```

Add `DEEPGRAM_API_KEY` in Render's Environment tab to activate transcription. Do not put it in the Flutter app.
Add `GEMINI_API_KEY` there too to activate compromise suggestions, conversation debriefs, logical fallacy detection, and argument ratings. Do not put it in the Flutter app.

Add `GOOGLE_FACT_CHECK_API_KEY` in Render's Environment tab to activate published fact-check lookup. Do not put it in the Flutter app.

Add `DATABASE_URL` in Render's Environment tab to activate Postgres history. Use Render's internal database URL when the database and backend are in the same Render account/region. Keep `DATABASE_SSL=false` for the internal URL unless Render gives you a URL with `sslmode=require`.

When `DATABASE_URL` is configured, the backend creates these tables automatically on first history write:

- `history_sessions`
- `history_streams`
- `history_events`
- `transcript_lines`
- `detected_claims`
- `fact_checks`
- `fallacy_detections`
- `argument_ratings`
- `referee_interventions`
- `compromise_suggestions`
- `speaker_mappings`

Referee settings are stored on each `history_streams` row as `referee_settings`.

## History API

After `DATABASE_URL` is configured and at least one session has produced history
events, the backend exposes session history over HTTP.

List recent sessions:

```sh
curl https://argumentref-backend.onrender.com/v1/sessions
```

Optional limit, capped at 100:

```sh
curl https://argumentref-backend.onrender.com/v1/sessions?limit=20
```

Read one session:

```sh
curl https://argumentref-backend.onrender.com/v1/sessions/demo-session
```

If `DATABASE_URL` is not configured, these endpoints return:

```json
{
  "error": "history_disabled",
  "message": "Set DATABASE_URL on the backend to enable session history."
}
```

The session detail response includes streams, speaker mappings, final transcript
lines, detected claims, fact-check events, compromise suggestions, and raw stored
events.

For the first mobile-to-Deepgram test, send raw PCM 16-bit mono audio:

```text
wss://argumentref-backend.onrender.com/v1/audio?sessionId=demo-session&participantId=device-1&encoding=pcm16&sampleRateHz=16000&channels=1
```

Deepgram diarization is enabled with `diarize_model=latest`.

Deepgram does not know real names. It returns anonymous speaker IDs such as `speaker_0` and `speaker_1`. If the app needs names like "Alice" or "Ben", the backend needs a calibration/mapping step.

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
{"type":"transcription.connected", "provider":"deepgram", "diarization":{"requested":true,"model":"latest"}, "...":"..."}
{"type":"speaker.diarization_status", "status":"single_speaker", "speakers":["speaker_0"], "...":"..."}
{"type":"transcript.partial", "speaker":"speaker_0", "text":"..."}
{"type":"transcript.final", "speaker":"speaker_0", "text":"..."}
{"type":"claim.detected", "speaker":"speaker_0", "text":"...", "reason":"contains_number"}
{"type":"fact_check.started", "claimId":"...", "provider":"google-fact-check"}
{"type":"fact_check.completed", "claimId":"...", "status":"matched_fact_check", "sources":[...]}
{"type":"fallacy.detected", "speaker":"speaker_0", "fallacy":"straw_man", "confidence":"medium", "quote":"..."}
```

For speaker diarization, use audio with two clearly different speakers who take turns speaking. Deepgram labels them as `speaker_0`, `speaker_1`, and so on. It does not know real names unless the app maps those labels later.

To test backend speaker calibration without frontend work, pass labels in the known order you expect speakers to appear:

```sh
npm run test:remote-audio -- --file ./two-speakers.wav --speakerLabels PersonA,PersonB
```

The backend maps the first Deepgram speaker ID it sees to `PersonA`, the second to `PersonB`, and emits:

```json
{"type":"speaker.mapped", "speaker":"speaker_0", "speakerLabel":"PersonA"}
{"type":"transcript.final", "speaker":"speaker_0", "speakerLabel":"PersonA", "text":"..."}
```

This is a controlled test mapping, not voiceprint recognition. The final app can use the same idea by asking each participant to speak a short calibration sentence before the argument starts. If the test only shows `single_speaker`, Deepgram is not hearing enough difference/turn-taking in the audio yet.

## Test Google Fact Check Events

After the Render service has `GOOGLE_FACT_CHECK_API_KEY` configured and redeployed, any `claim.detected` event can trigger a fact-check lookup.

The backend emits:

```json
{"type":"fact_check.started", "provider":"google-fact-check", "claimId":"..."}
```

Then either:

```json
{
  "type": "fact_check.completed",
  "provider": "google-fact-check",
  "claimId": "...",
  "status": "matched_fact_check",
  "summary": "Found 1 published fact check result from Example Publisher. Rating: False.",
  "sources": [
    {
      "title": "Example fact check title",
      "publisher": "Example Publisher",
      "rating": "False",
      "url": "https://example.com/fact-check"
    }
  ]
}
```

Or:

```json
{
  "type": "fact_check.completed",
  "provider": "google-fact-check",
  "claimId": "...",
  "status": "no_match",
  "summary": "No matching published fact check was found.",
  "sources": []
}
```

This free integration searches existing published fact checks. It should not claim that an unmatched statement is true or false.

## Test Logical Fallacy Events

Fallacy detection reuses `GEMINI_API_KEY`. No extra secret is required.

The backend watches final transcript lines and periodically emits conservative
fallacy events:

```json
{
  "type": "fallacy.detected",
  "provider": "gemini",
  "speaker": "speaker_0",
  "speakerLabel": "PersonA",
  "fallacy": "straw_man",
  "confidence": "medium",
  "severity": "moderate",
  "quote": "So you are saying I should never have any free time.",
  "explanation": "This may exaggerate the other person's position rather than responding to the actual request.",
  "suggestedRefereeResponse": "Pause there and restate the other person's actual point before responding."
}
```

Only `medium` and `high` confidence detections are emitted by default. This is a
referee hint, not a final judgment.

## Test Argument Rating Events

Argument ratings reuse `GEMINI_API_KEY`. No extra secret is required.

The backend watches final transcript lines and periodically emits a neutral score
for the argument process:

```json
{
  "type": "argument.rating.updated",
  "provider": "gemini",
  "overallScore": 78,
  "dimensions": {
    "clarity": 82,
    "evidenceQuality": 68,
    "logicalConsistency": 76,
    "listening": 70,
    "emotionalControl": 84,
    "fairness": 75
  },
  "strengths": ["Both speakers are naming practical constraints."],
  "risks": ["Some claims still need concrete examples."],
  "refereeFocus": "Ask each person for one specific example and one next step."
}
```

This rates the conversation quality, not which person is right. It is intended as
live guidance for the referee UI.

## Test Private Referee Settings

Private referee settings are per-session WebSocket options. They do not need a
new Render secret and they are returned on `session.started`:

```json
{
  "type": "session.started",
  "refereeSettings": {
    "interventionStyle": "gentle",
    "fallacySensitivity": "medium",
    "factCheckStrictness": "high",
    "compromisePreference": "balanced",
    "interventionFrequency": "normal"
  }
}
```

They adjust only backend referee behavior. For example, `interventionStyle=gentle`
softens intervention wording, `factCheckStrictness=high` prompts earlier on
factual claims, and `interventionFrequency=low` reduces rating prompts and
increases cooldowns.

## Test Referee Intervention Events

Referee interventions do not need another API key. They convert existing backend
events into one concise action the UI can surface.

Example:

```json
{
  "type": "referee.intervention.suggested",
  "category": "logic",
  "priority": "medium",
  "message": "Pause there and restate the other person's actual point before responding.",
  "reason": "PersonA may be using straw man: This may exaggerate the other person's position.",
  "sourceEvent": "fallacy.detected"
}
```

The engine currently listens to detected claims, completed fact-checks, fallacy
detections, compromise suggestions, and low argument ratings. It uses
`REFEREE_INTERVENTION_COOLDOWN_MS` to avoid repeated prompts in the same category.

## Next Step

The backend now detects checkable claims, fact-checks them when configured, suggests compromises, stores history, emits conservative fallacy hints, rates argument quality, supports private referee settings, and turns those signals into referee intervention suggestions. The frontend should consume normalized transcript, claim, fact-check, compromise, fallacy, rating, intervention, settings, and history data from the backend.
