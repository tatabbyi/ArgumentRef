# Backend Roadmap

The mobile app should have one stable backend connection:

```text
wss://<deployed-backend>/v1/audio
```

The app should not know about Deepgram, Perplexity, database credentials, or any provider API key. Those live behind the backend.

## Phase 1: Audio Ingestion

Current implementation.

```text
Mobile app
  -> binary audio chunks
  -> backend /v1/audio
  -> audio.ack events
```

Purpose: prove that a phone can stream audio to an internet-hosted backend.

## Phase 2: Deepgram Streaming

Current implementation when `DEEPGRAM_API_KEY` is configured.

```text
Mobile app
  -> backend /v1/audio
  -> Deepgram streaming API
  -> transcript + speaker labels
  -> optional backend calibration labels
  -> backend emits transcript events to mobile app
```

Example event:

```json
{
  "type": "transcript.final",
  "sessionId": "demo-session",
  "speaker": "speaker_0",
  "speakerLabel": "PersonA",
  "text": "The budget increased by 20 percent.",
  "startMs": 12400,
  "endMs": 15900
}
```

Deepgram returns anonymous IDs like `speaker_0`; the backend can map those IDs to calibration labels supplied by the app or test script.

## Phase 3: Claim Queue

Current implementation. The backend watches final transcript text for checkable claims.

```text
transcript.final
  -> claim detector
  -> claim.detected event
```

Example event:

```json
{
  "type": "claim.detected",
  "sessionId": "demo-session",
  "claimId": "claim-123",
  "speaker": "speaker_0",
  "text": "The budget increased by 20 percent."
}
```

## Phase 4: Fact Checking

Current implementation when `GOOGLE_FACT_CHECK_API_KEY` is configured. The backend searches published fact checks through Google Fact Check Tools.

```text
claim.detected
  -> Google Fact Check Tools API
  -> fact_check.completed event
```

Example event:

```json
{
  "type": "fact_check.completed",
  "claimId": "claim-123",
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

This is a free published-fact-check lookup, not an unrestricted truth engine. `no_match` means no matching published fact check was found.

## Phase 5: Compromise Suggestions

Current implementation when `GEMINI_API_KEY` is configured. The backend keeps a
rolling final transcript, checks it after one minute, then every 30 seconds, and
emits ranked compromise suggestions to the mobile app.

```text
transcript.final
  -> rolling transcript
  -> Gemini Interactions API
  -> compromise.suggested event
```

Top-tier suggestions carry `quality: "really_good"` and `pushLevel: "urgent"`
so the frontend can make the referee push them harder.

## Phase 6: Logical Fallacy Detection

Current implementation when `GEMINI_API_KEY` is configured. The backend keeps a
rolling final transcript window and emits conservative fallacy hints.

```text
transcript.final
  -> rolling transcript
  -> Gemini Interactions API
  -> fallacy.detected event
```

Example event:

```json
{
  "type": "fallacy.detected",
  "speaker": "speaker_0",
  "speakerLabel": "PersonA",
  "fallacy": "straw_man",
  "confidence": "medium",
  "severity": "moderate",
  "quote": "So you are saying I should never have any free time.",
  "suggestedRefereeResponse": "Pause there and restate the other person's actual point before responding."
}
```

Only medium/high confidence detections are emitted by default.

## Phase 7: Argument Ratings

Current implementation when `GEMINI_API_KEY` is configured. The backend keeps a
rolling final transcript window and emits neutral argument quality ratings.

```text
transcript.final
  -> rolling transcript
  -> Gemini Interactions API
  -> argument.rating.updated event
```

The rating includes `overallScore`, dimension scores, short strengths, short
risks, and one `refereeFocus` action for the live UI. It rates the conversation
process, not which person is correct.

## Phase 8: Session Storage

Current implementation when `DATABASE_URL` is configured. The backend stores
session history in Postgres while still keeping temporary raw audio files on
disk, and exposes read endpoints for the app.

Stored history:

- sessions and streams
- speaker mappings
- final transcript lines
- detected claims
- fact-check lifecycle events and results
- fallacy detections
- argument ratings
- compromise suggestions
- raw event JSON for future features

Read endpoints:

```text
GET /v1/sessions
GET /v1/sessions/:sessionId
```

Still recommended later:

- S3-compatible object storage for raw audio files if replay is required

The mobile app should still use the same backend API. Storage changes should not require a frontend rewrite.
