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
  -> backend emits transcript events to mobile app
```

Example event:

```json
{
  "type": "transcript.final",
  "sessionId": "demo-session",
  "speaker": "speaker_0",
  "text": "The budget increased by 20 percent.",
  "startMs": 12400,
  "endMs": 15900
}
```

## Phase 3: Claim Queue

The backend watches final transcript text for checkable claims.

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

The backend sends claims to a fact-checking provider such as Perplexity.

```text
claim.detected
  -> Perplexity/search-backed checker
  -> fact_check.completed event
```

Example event:

```json
{
  "type": "fact_check.completed",
  "claimId": "claim-123",
  "verdict": "supported",
  "summary": "The claim matches the cited budget report.",
  "sources": ["https://example.com/report"]
}
```

## Phase 5: Session Storage

Add a database and object storage.

Recommended:

- Postgres for sessions, speakers, transcript lines, claims, and verdicts
- S3-compatible object storage for raw audio files if replay is required

The mobile app should still use the same backend API. Storage changes should not require a frontend rewrite.
