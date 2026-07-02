import { Pool } from 'pg';
import type { AppConfig } from '../config.js';
import type {
  ClaimDetectedEvent,
  CompromiseSuggestedEvent,
  FactCheckCompletedEvent,
  FactCheckFailedEvent,
  FactCheckSkippedEvent,
  FactCheckStartedEvent,
  ServerEvent,
  SpeakerMappedEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

type HistoryEvent =
  | Extract<ServerEvent, { type: 'session.started' }>
  | Extract<ServerEvent, { type: 'session.ended' }>
  | TranscriptFinalEvent
  | ClaimDetectedEvent
  | FactCheckStartedEvent
  | FactCheckCompletedEvent
  | FactCheckSkippedEvent
  | FactCheckFailedEvent
  | CompromiseSuggestedEvent
  | SpeakerMappedEvent;

export interface HistoryStore {
  recordEvent(event: ServerEvent): Promise<void>;
  close(): Promise<void>;
}

export function createHistoryStore(config: AppConfig): HistoryStore {
  if (!config.databaseUrl) {
    return new NoopHistoryStore();
  }

  return new PostgresHistoryStore(config);
}

class NoopHistoryStore implements HistoryStore {
  async recordEvent(): Promise<void> {
    return;
  }

  async close(): Promise<void> {
    return;
  }
}

class PostgresHistoryStore implements HistoryStore {
  private readonly pool: Pool;
  private initPromise?: Promise<void>;

  constructor(config: AppConfig) {
    this.pool = new Pool({
      connectionString: config.databaseUrl,
      ssl: config.databaseSsl ? { rejectUnauthorized: false } : undefined,
    });
  }

  async recordEvent(event: ServerEvent): Promise<void> {
    if (!shouldPersist(event)) {
      return;
    }

    await this.ensureInitialized();
    await this.persistEvent(event);
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  private async initialize(): Promise<void> {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS history_sessions (
        session_id TEXT PRIMARY KEY,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS history_streams (
        stream_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES history_sessions(session_id) ON DELETE CASCADE,
        participant_id TEXT NOT NULL,
        audio_format JSONB NOT NULL DEFAULT '{}'::jsonb,
        started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        ended_at TIMESTAMPTZ,
        bytes_received INTEGER NOT NULL DEFAULT 0,
        chunks_received INTEGER NOT NULL DEFAULT 0,
        storage_path TEXT,
        debrief_storage_path TEXT,
        profile_storage_path TEXT,
        debrief_status TEXT
      );

      CREATE TABLE IF NOT EXISTS history_events (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT,
        stream_id TEXT,
        event_type TEXT NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS history_events_session_created_idx
        ON history_events(session_id, created_at DESC);

      CREATE TABLE IF NOT EXISTS transcript_lines (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        speaker TEXT NOT NULL,
        speaker_label TEXT,
        text TEXT NOT NULL,
        start_ms INTEGER,
        end_ms INTEGER,
        confidence DOUBLE PRECISION,
        words JSONB NOT NULL DEFAULT '[]'::jsonb,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS transcript_lines_session_created_idx
        ON transcript_lines(session_id, created_at ASC);

      CREATE TABLE IF NOT EXISTS detected_claims (
        claim_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        speaker TEXT NOT NULL,
        speaker_label TEXT,
        text TEXT NOT NULL,
        reason TEXT NOT NULL,
        status TEXT NOT NULL,
        start_ms INTEGER,
        end_ms INTEGER,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS fact_checks (
        id BIGSERIAL PRIMARY KEY,
        claim_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        provider TEXT,
        event_type TEXT NOT NULL,
        status TEXT,
        summary TEXT,
        reason TEXT,
        message TEXT,
        sources JSONB NOT NULL DEFAULT '[]'::jsonb,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS fact_checks_claim_created_idx
        ON fact_checks(claim_id, created_at ASC);

      CREATE TABLE IF NOT EXISTS compromise_suggestions (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        model TEXT NOT NULL,
        generated_at TIMESTAMPTZ,
        transcript_line_count INTEGER NOT NULL,
        suggestions JSONB NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS speaker_mappings (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        speaker TEXT NOT NULL,
        speaker_label TEXT NOT NULL,
        source TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(stream_id, speaker)
      );
    `);
  }

  private ensureInitialized(): Promise<void> {
    this.initPromise ??= this.initialize();
    return this.initPromise;
  }

  private async persistEvent(event: HistoryEvent): Promise<void> {
    await this.insertRawEvent(event);

    switch (event.type) {
      case 'session.started':
        await this.persistSessionStarted(event);
        return;
      case 'session.ended':
        await this.persistSessionEnded(event);
        return;
      case 'transcript.final':
        await this.persistTranscriptFinal(event);
        return;
      case 'claim.detected':
        await this.persistClaimDetected(event);
        return;
      case 'fact_check.started':
      case 'fact_check.completed':
      case 'fact_check.skipped':
      case 'fact_check.failed':
        await this.persistFactCheckEvent(event);
        return;
      case 'compromise.suggested':
        await this.persistCompromiseSuggested(event);
        return;
      case 'speaker.mapped':
        await this.persistSpeakerMapped(event);
        return;
      default:
        assertNever(event);
    }
  }

  private async insertRawEvent(event: HistoryEvent): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO history_events (session_id, stream_id, event_type, payload)
        VALUES ($1, $2, $3, $4::jsonb)
      `,
      [
        eventSessionId(event),
        eventStreamId(event),
        event.type,
        JSON.stringify(event),
      ],
    );
  }

  private async persistSessionStarted(
    event: Extract<ServerEvent, { type: 'session.started' }>,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO history_sessions (session_id)
        VALUES ($1)
        ON CONFLICT (session_id)
        DO UPDATE SET updated_at = now()
      `,
      [event.sessionId],
    );
    await this.pool.query(
      `
        INSERT INTO history_streams (
          stream_id,
          session_id,
          participant_id,
          audio_format,
          started_at
        )
        VALUES ($1, $2, $3, $4::jsonb, now())
        ON CONFLICT (stream_id)
        DO UPDATE SET
          participant_id = EXCLUDED.participant_id,
          audio_format = EXCLUDED.audio_format
      `,
      [
        event.streamId,
        event.sessionId,
        event.participantId,
        JSON.stringify(event.audio),
      ],
    );
  }

  private async persistSessionEnded(
    event: Extract<ServerEvent, { type: 'session.ended' }>,
  ): Promise<void> {
    await this.pool.query(
      `
        UPDATE history_sessions
        SET updated_at = now()
        WHERE session_id = $1
      `,
      [event.sessionId],
    );
    await this.pool.query(
      `
        UPDATE history_streams
        SET
          ended_at = now(),
          bytes_received = $3,
          chunks_received = $4,
          storage_path = $5,
          debrief_storage_path = $6,
          profile_storage_path = $7,
          debrief_status = $8
        WHERE stream_id = $1 AND session_id = $2
      `,
      [
        event.streamId,
        event.sessionId,
        event.bytesReceived,
        event.chunksReceived,
        event.storagePath,
        event.debriefStoragePath,
        event.profileStoragePath,
        event.debriefStatus,
      ],
    );
  }

  private async persistTranscriptFinal(event: TranscriptFinalEvent): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO transcript_lines (
          session_id,
          stream_id,
          speaker,
          speaker_label,
          text,
          start_ms,
          end_ms,
          confidence,
          words
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)
      `,
      [
        event.sessionId,
        event.streamId,
        event.speaker,
        event.speakerLabel,
        event.text,
        event.startMs,
        event.endMs,
        event.confidence,
        JSON.stringify(event.words),
      ],
    );
  }

  private async persistClaimDetected(event: ClaimDetectedEvent): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO detected_claims (
          claim_id,
          session_id,
          stream_id,
          speaker,
          speaker_label,
          text,
          reason,
          status,
          start_ms,
          end_ms
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT (claim_id)
        DO UPDATE SET
          status = EXCLUDED.status,
          reason = EXCLUDED.reason
      `,
      [
        event.claimId,
        event.sessionId,
        event.streamId,
        event.speaker,
        event.speakerLabel,
        event.text,
        event.reason,
        event.status,
        event.startMs,
        event.endMs,
      ],
    );
  }

  private async persistFactCheckEvent(
    event:
      | FactCheckStartedEvent
      | FactCheckCompletedEvent
      | FactCheckSkippedEvent
      | FactCheckFailedEvent,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO fact_checks (
          claim_id,
          session_id,
          stream_id,
          provider,
          event_type,
          status,
          summary,
          reason,
          message,
          sources,
          payload
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11::jsonb)
      `,
      [
        event.claimId,
        event.sessionId,
        event.streamId,
        'provider' in event ? event.provider : undefined,
        event.type,
        'status' in event ? event.status : undefined,
        'summary' in event ? event.summary : undefined,
        'reason' in event ? event.reason : undefined,
        'message' in event ? event.message : undefined,
        JSON.stringify('sources' in event ? event.sources : []),
        JSON.stringify(event),
      ],
    );
  }

  private async persistCompromiseSuggested(
    event: CompromiseSuggestedEvent,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO compromise_suggestions (
          session_id,
          stream_id,
          model,
          generated_at,
          transcript_line_count,
          suggestions,
          payload
        )
        VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb)
      `,
      [
        event.sessionId,
        event.streamId,
        event.model,
        event.generatedAt,
        event.transcriptLineCount,
        JSON.stringify(event.suggestions),
        JSON.stringify(event),
      ],
    );
  }

  private async persistSpeakerMapped(event: SpeakerMappedEvent): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO speaker_mappings (
          session_id,
          stream_id,
          speaker,
          speaker_label,
          source
        )
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (stream_id, speaker)
        DO UPDATE SET
          speaker_label = EXCLUDED.speaker_label,
          source = EXCLUDED.source
      `,
      [
        event.sessionId,
        event.streamId,
        event.speaker,
        event.speakerLabel,
        event.source,
      ],
    );
  }
}

function shouldPersist(event: ServerEvent): event is HistoryEvent {
  return (
    event.type === 'session.started' ||
    event.type === 'session.ended' ||
    event.type === 'transcript.final' ||
    event.type === 'claim.detected' ||
    event.type === 'fact_check.started' ||
    event.type === 'fact_check.completed' ||
    event.type === 'fact_check.skipped' ||
    event.type === 'fact_check.failed' ||
    event.type === 'compromise.suggested' ||
    event.type === 'speaker.mapped'
  );
}

function eventSessionId(event: HistoryEvent): string {
  return 'sessionId' in event ? event.sessionId : '';
}

function eventStreamId(event: HistoryEvent): string {
  return 'streamId' in event ? event.streamId : '';
}

function assertNever(value: never): never {
  throw new Error(`Unhandled history event: ${JSON.stringify(value)}`);
}
