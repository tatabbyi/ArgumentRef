import { Pool } from 'pg';
import type { QueryResultRow } from 'pg';
import type { AppConfig } from '../config.js';
import type {
  ArgumentRatingUpdatedEvent,
  ClaimDetectedEvent,
  CompromiseSuggestedEvent,
  FactCheckCompletedEvent,
  FactCheckFailedEvent,
  FactCheckSkippedEvent,
  FactCheckStartedEvent,
  FallacyDetectedEvent,
  RefereeInterventionSuggestedEvent,
  ServerEvent,
  SpeakerMappedEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';
import { withDefaultRefereeSettings } from '../referee/refereeSettings.js';

type HistoryEvent =
  | Extract<ServerEvent, { type: 'session.started' }>
  | Extract<ServerEvent, { type: 'session.ended' }>
  | TranscriptFinalEvent
  | ClaimDetectedEvent
  | FactCheckStartedEvent
  | FactCheckCompletedEvent
  | FactCheckSkippedEvent
  | FactCheckFailedEvent
  | FallacyDetectedEvent
  | ArgumentRatingUpdatedEvent
  | CompromiseSuggestedEvent
  | RefereeInterventionSuggestedEvent
  | SpeakerMappedEvent;

export interface HistoryStore {
  recordEvent(event: ServerEvent): Promise<void>;
  listSessions(limit: number): Promise<HistorySessionSummary[]>;
  getSession(sessionId: string): Promise<HistorySessionDetail | null>;
  isEnabled(): boolean;
  close(): Promise<void>;
}

export interface HistorySessionSummary {
  sessionId: string;
  createdAt: string;
  updatedAt: string;
  startedAt?: string;
  endedAt?: string;
  participantIds: string[];
  transcriptLineCount: number;
  claimCount: number;
  factCheckCount: number;
  fallacyCount: number;
  argumentRatingCount: number;
  interventionCount: number;
  compromiseCount: number;
  debriefStatus?: string;
}

export interface HistorySessionDetail extends HistorySessionSummary {
  streams: HistoryStreamSummary[];
  speakerMappings: HistorySpeakerMapping[];
  transcriptLines: HistoryTranscriptLine[];
  claims: HistoryClaim[];
  factChecks: HistoryFactCheck[];
  fallacies: HistoryFallacyDetection[];
  argumentRatings: HistoryArgumentRating[];
  interventions: HistoryRefereeIntervention[];
  compromises: HistoryCompromiseSuggestion[];
  events: HistoryRawEvent[];
}

export interface HistoryStreamSummary {
  streamId: string;
  participantId: string;
  audioFormat: unknown;
  startedAt: string;
  endedAt?: string;
  bytesReceived: number;
  chunksReceived: number;
  storagePath?: string;
  debriefStoragePath?: string;
  profileStoragePath?: string;
  debriefStatus?: string;
  refereeSettings: unknown;
}

export interface HistorySpeakerMapping {
  speaker: string;
  speakerLabel: string;
  source: string;
  createdAt: string;
}

export interface HistoryTranscriptLine {
  id: number;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  text: string;
  startMs?: number;
  endMs?: number;
  confidence?: number;
  words: unknown;
  createdAt: string;
}

export interface HistoryClaim {
  claimId: string;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  text: string;
  reason: string;
  status: string;
  startMs?: number;
  endMs?: number;
  createdAt: string;
}

export interface HistoryFactCheck {
  id: number;
  claimId: string;
  streamId: string;
  provider?: string;
  eventType: string;
  status?: string;
  summary?: string;
  reason?: string;
  message?: string;
  sources: unknown;
  createdAt: string;
}

export interface HistoryFallacyDetection {
  id: number;
  streamId: string;
  model: string;
  speaker: string;
  speakerLabel?: string;
  fallacy: string;
  confidence: string;
  severity: string;
  quote: string;
  explanation: string;
  suggestedRefereeResponse: string;
  transcriptLineCount: number;
  detectedAt: string;
  createdAt: string;
}

export interface HistoryCompromiseSuggestion {
  id: number;
  streamId: string;
  model: string;
  generatedAt?: string;
  transcriptLineCount: number;
  suggestions: unknown;
  createdAt: string;
}

export interface HistoryArgumentRating {
  id: number;
  streamId: string;
  model: string;
  generatedAt: string;
  transcriptLineCount: number;
  overallScore: number;
  dimensions: unknown;
  strengths: unknown;
  risks: unknown;
  refereeFocus: string;
  createdAt: string;
}

export interface HistoryRefereeIntervention {
  id: number;
  streamId: string;
  interventionId: string;
  generatedAt: string;
  category: string;
  priority: string;
  message: string;
  reason: string;
  sourceEvent: string;
  sourceId?: string;
  speaker?: string;
  speakerLabel?: string;
  createdAt: string;
}

export interface HistoryRawEvent {
  id: number;
  streamId?: string;
  eventType: string;
  payload: unknown;
  createdAt: string;
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

  async listSessions(): Promise<HistorySessionSummary[]> {
    return [];
  }

  async getSession(): Promise<HistorySessionDetail | null> {
    return null;
  }

  isEnabled(): boolean {
    return false;
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

  async listSessions(limit: number): Promise<HistorySessionSummary[]> {
    await this.ensureInitialized();
    const result = await this.pool.query<SessionSummaryRow>(
      `
        SELECT
          s.session_id,
          s.created_at,
          s.updated_at,
          MIN(st.started_at) AS started_at,
          MAX(st.ended_at) AS ended_at,
          ARRAY_REMOVE(ARRAY_AGG(DISTINCT st.participant_id), NULL) AS participant_ids,
          COUNT(DISTINCT tl.id)::int AS transcript_line_count,
          COUNT(DISTINCT dc.claim_id)::int AS claim_count,
          COUNT(DISTINCT fc.id)::int AS fact_check_count,
          COUNT(DISTINCT fd.id)::int AS fallacy_count,
          COUNT(DISTINCT ar.id)::int AS argument_rating_count,
          COUNT(DISTINCT ri.id)::int AS intervention_count,
          COUNT(DISTINCT cs.id)::int AS compromise_count,
          MAX(st.debrief_status) AS debrief_status
        FROM history_sessions s
        LEFT JOIN history_streams st ON st.session_id = s.session_id
        LEFT JOIN transcript_lines tl ON tl.session_id = s.session_id
        LEFT JOIN detected_claims dc ON dc.session_id = s.session_id
        LEFT JOIN fact_checks fc ON fc.session_id = s.session_id
        LEFT JOIN fallacy_detections fd ON fd.session_id = s.session_id
        LEFT JOIN argument_ratings ar ON ar.session_id = s.session_id
        LEFT JOIN referee_interventions ri ON ri.session_id = s.session_id
        LEFT JOIN compromise_suggestions cs ON cs.session_id = s.session_id
        GROUP BY s.session_id, s.created_at, s.updated_at
        ORDER BY s.updated_at DESC
        LIMIT $1
      `,
      [limit],
    );

    return result.rows.map(toSessionSummary);
  }

  async getSession(sessionId: string): Promise<HistorySessionDetail | null> {
    await this.ensureInitialized();
    const summaries = await this.pool.query<SessionSummaryRow>(
      `
        SELECT
          s.session_id,
          s.created_at,
          s.updated_at,
          MIN(st.started_at) AS started_at,
          MAX(st.ended_at) AS ended_at,
          ARRAY_REMOVE(ARRAY_AGG(DISTINCT st.participant_id), NULL) AS participant_ids,
          COUNT(DISTINCT tl.id)::int AS transcript_line_count,
          COUNT(DISTINCT dc.claim_id)::int AS claim_count,
          COUNT(DISTINCT fc.id)::int AS fact_check_count,
          COUNT(DISTINCT fd.id)::int AS fallacy_count,
          COUNT(DISTINCT ar.id)::int AS argument_rating_count,
          COUNT(DISTINCT ri.id)::int AS intervention_count,
          COUNT(DISTINCT cs.id)::int AS compromise_count,
          MAX(st.debrief_status) AS debrief_status
        FROM history_sessions s
        LEFT JOIN history_streams st ON st.session_id = s.session_id
        LEFT JOIN transcript_lines tl ON tl.session_id = s.session_id
        LEFT JOIN detected_claims dc ON dc.session_id = s.session_id
        LEFT JOIN fact_checks fc ON fc.session_id = s.session_id
        LEFT JOIN fallacy_detections fd ON fd.session_id = s.session_id
        LEFT JOIN argument_ratings ar ON ar.session_id = s.session_id
        LEFT JOIN referee_interventions ri ON ri.session_id = s.session_id
        LEFT JOIN compromise_suggestions cs ON cs.session_id = s.session_id
        WHERE s.session_id = $1
        GROUP BY s.session_id, s.created_at, s.updated_at
      `,
      [sessionId],
    );

    const summary = summaries.rows[0];
    if (!summary) {
      return null;
    }

    const [
      streams,
      speakerMappings,
      transcriptLines,
      claims,
      factChecks,
      fallacies,
      argumentRatings,
      interventions,
      compromises,
      events,
    ] = await Promise.all([
      this.pool.query<StreamRow>(
        `
          SELECT *
          FROM history_streams
          WHERE session_id = $1
          ORDER BY started_at ASC
        `,
        [sessionId],
      ),
      this.pool.query<SpeakerMappingRow>(
        `
          SELECT speaker, speaker_label, source, created_at
          FROM speaker_mappings
          WHERE session_id = $1
          ORDER BY created_at ASC
        `,
        [sessionId],
      ),
      this.pool.query<TranscriptLineRow>(
        `
          SELECT *
          FROM transcript_lines
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<ClaimRow>(
        `
          SELECT *
          FROM detected_claims
          WHERE session_id = $1
          ORDER BY created_at ASC
        `,
        [sessionId],
      ),
      this.pool.query<FactCheckRow>(
        `
          SELECT *
          FROM fact_checks
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<FallacyRow>(
        `
          SELECT *
          FROM fallacy_detections
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<ArgumentRatingRow>(
        `
          SELECT *
          FROM argument_ratings
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<RefereeInterventionRow>(
        `
          SELECT *
          FROM referee_interventions
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<CompromiseRow>(
        `
          SELECT *
          FROM compromise_suggestions
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
        `,
        [sessionId],
      ),
      this.pool.query<RawEventRow>(
        `
          SELECT id, stream_id, event_type, payload, created_at
          FROM history_events
          WHERE session_id = $1
          ORDER BY created_at ASC, id ASC
          LIMIT 500
        `,
        [sessionId],
      ),
    ]);

    return {
      ...toSessionSummary(summary),
      streams: streams.rows.map(toStreamSummary),
      speakerMappings: speakerMappings.rows.map(toSpeakerMapping),
      transcriptLines: transcriptLines.rows.map(toTranscriptLine),
      claims: claims.rows.map(toClaim),
      factChecks: factChecks.rows.map(toFactCheck),
      fallacies: fallacies.rows.map(toFallacy),
      argumentRatings: argumentRatings.rows.map(toArgumentRating),
      interventions: interventions.rows.map(toRefereeIntervention),
      compromises: compromises.rows.map(toCompromise),
      events: events.rows.map(toRawEvent),
    };
  }

  isEnabled(): boolean {
    return true;
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
        debrief_status TEXT,
        referee_settings JSONB NOT NULL DEFAULT '{}'::jsonb
      );

      ALTER TABLE history_streams
        ADD COLUMN IF NOT EXISTS referee_settings JSONB NOT NULL DEFAULT '{}'::jsonb;

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

      CREATE TABLE IF NOT EXISTS fallacy_detections (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        model TEXT NOT NULL,
        speaker TEXT NOT NULL,
        speaker_label TEXT,
        fallacy TEXT NOT NULL,
        confidence TEXT NOT NULL,
        severity TEXT NOT NULL,
        quote TEXT NOT NULL,
        explanation TEXT NOT NULL,
        suggested_referee_response TEXT NOT NULL,
        transcript_line_count INTEGER NOT NULL,
        detected_at TIMESTAMPTZ NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS fallacy_detections_session_created_idx
        ON fallacy_detections(session_id, created_at ASC);

      CREATE TABLE IF NOT EXISTS argument_ratings (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        model TEXT NOT NULL,
        generated_at TIMESTAMPTZ NOT NULL,
        transcript_line_count INTEGER NOT NULL,
        overall_score INTEGER NOT NULL,
        dimensions JSONB NOT NULL,
        strengths JSONB NOT NULL,
        risks JSONB NOT NULL,
        referee_focus TEXT NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE INDEX IF NOT EXISTS argument_ratings_session_created_idx
        ON argument_ratings(session_id, created_at ASC);

      CREATE TABLE IF NOT EXISTS referee_interventions (
        id BIGSERIAL PRIMARY KEY,
        session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        intervention_id TEXT NOT NULL,
        generated_at TIMESTAMPTZ NOT NULL,
        category TEXT NOT NULL,
        priority TEXT NOT NULL,
        message TEXT NOT NULL,
        reason TEXT NOT NULL,
        source_event TEXT NOT NULL,
        source_id TEXT,
        speaker TEXT,
        speaker_label TEXT,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(stream_id, intervention_id)
      );

      CREATE INDEX IF NOT EXISTS referee_interventions_session_created_idx
        ON referee_interventions(session_id, created_at ASC);

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
      case 'fallacy.detected':
        await this.persistFallacyDetected(event);
        return;
      case 'argument.rating.updated':
        await this.persistArgumentRatingUpdated(event);
        return;
      case 'compromise.suggested':
        await this.persistCompromiseSuggested(event);
        return;
      case 'referee.intervention.suggested':
        await this.persistRefereeIntervention(event);
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
          referee_settings,
          started_at
        )
        VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, now())
        ON CONFLICT (stream_id)
        DO UPDATE SET
          participant_id = EXCLUDED.participant_id,
          audio_format = EXCLUDED.audio_format,
          referee_settings = EXCLUDED.referee_settings
      `,
      [
        event.streamId,
        event.sessionId,
        event.participantId,
        JSON.stringify(event.audio),
        JSON.stringify(event.refereeSettings),
      ],
    );
  }

  private async persistSessionEnded(
    event: Extract<ServerEvent, { type: 'session.ended' }>,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO history_sessions (session_id, updated_at)
        VALUES ($1, now())
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
          ended_at,
          bytes_received,
          chunks_received,
          storage_path,
          debrief_storage_path,
          profile_storage_path,
          debrief_status
        )
        VALUES ($1, $2, $3, now(), $4, $5, $6, $7, $8, $9)
        ON CONFLICT (stream_id)
        DO UPDATE SET
          ended_at = now(),
          bytes_received = EXCLUDED.bytes_received,
          chunks_received = EXCLUDED.chunks_received,
          storage_path = EXCLUDED.storage_path,
          debrief_storage_path = EXCLUDED.debrief_storage_path,
          profile_storage_path = EXCLUDED.profile_storage_path,
          debrief_status = EXCLUDED.debrief_status
      `,
      [
        event.streamId,
        event.sessionId,
        event.participantId,
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

  private async persistFallacyDetected(event: FallacyDetectedEvent): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO fallacy_detections (
          session_id,
          stream_id,
          model,
          speaker,
          speaker_label,
          fallacy,
          confidence,
          severity,
          quote,
          explanation,
          suggested_referee_response,
          transcript_line_count,
          detected_at,
          payload
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::jsonb)
      `,
      [
        event.sessionId,
        event.streamId,
        event.model,
        event.speaker,
        event.speakerLabel,
        event.fallacy,
        event.confidence,
        event.severity,
        event.quote,
        event.explanation,
        event.suggestedRefereeResponse,
        event.transcriptLineCount,
        event.detectedAt,
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

  private async persistArgumentRatingUpdated(
    event: ArgumentRatingUpdatedEvent,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO argument_ratings (
          session_id,
          stream_id,
          model,
          generated_at,
          transcript_line_count,
          overall_score,
          dimensions,
          strengths,
          risks,
          referee_focus,
          payload
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9::jsonb, $10, $11::jsonb)
      `,
      [
        event.sessionId,
        event.streamId,
        event.model,
        event.generatedAt,
        event.transcriptLineCount,
        event.overallScore,
        JSON.stringify(event.dimensions),
        JSON.stringify(event.strengths),
        JSON.stringify(event.risks),
        event.refereeFocus,
        JSON.stringify(event),
      ],
    );
  }

  private async persistRefereeIntervention(
    event: RefereeInterventionSuggestedEvent,
  ): Promise<void> {
    await this.pool.query(
      `
        INSERT INTO referee_interventions (
          session_id,
          stream_id,
          intervention_id,
          generated_at,
          category,
          priority,
          message,
          reason,
          source_event,
          source_id,
          speaker,
          speaker_label,
          payload
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb)
        ON CONFLICT (stream_id, intervention_id)
        DO NOTHING
      `,
      [
        event.sessionId,
        event.streamId,
        event.interventionId,
        event.generatedAt,
        event.category,
        event.priority,
        event.message,
        event.reason,
        event.sourceEvent,
        event.sourceId,
        event.speaker,
        event.speakerLabel,
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
    event.type === 'fallacy.detected' ||
    event.type === 'argument.rating.updated' ||
    event.type === 'compromise.suggested' ||
    event.type === 'referee.intervention.suggested' ||
    event.type === 'speaker.mapped'
  );
}

function eventSessionId(event: HistoryEvent): string {
  return 'sessionId' in event ? event.sessionId : '';
}

function eventStreamId(event: HistoryEvent): string {
  return 'streamId' in event ? event.streamId : '';
}

interface SessionSummaryRow extends QueryResultRow {
  session_id: string;
  created_at: Date;
  updated_at: Date;
  started_at: Date | null;
  ended_at: Date | null;
  participant_ids: string[] | null;
  transcript_line_count: number;
  claim_count: number;
  fact_check_count: number;
  fallacy_count: number;
  argument_rating_count: number;
  intervention_count: number;
  compromise_count: number;
  debrief_status: string | null;
}

interface StreamRow extends QueryResultRow {
  stream_id: string;
  participant_id: string;
  audio_format: unknown;
  started_at: Date;
  ended_at: Date | null;
  bytes_received: number;
  chunks_received: number;
  storage_path: string | null;
  debrief_storage_path: string | null;
  profile_storage_path: string | null;
  debrief_status: string | null;
  referee_settings: unknown;
}

interface SpeakerMappingRow extends QueryResultRow {
  speaker: string;
  speaker_label: string;
  source: string;
  created_at: Date;
}

interface TranscriptLineRow extends QueryResultRow {
  id: string | number;
  stream_id: string;
  speaker: string;
  speaker_label: string | null;
  text: string;
  start_ms: number | null;
  end_ms: number | null;
  confidence: number | null;
  words: unknown;
  created_at: Date;
}

interface ClaimRow extends QueryResultRow {
  claim_id: string;
  stream_id: string;
  speaker: string;
  speaker_label: string | null;
  text: string;
  reason: string;
  status: string;
  start_ms: number | null;
  end_ms: number | null;
  created_at: Date;
}

interface FactCheckRow extends QueryResultRow {
  id: string | number;
  claim_id: string;
  stream_id: string;
  provider: string | null;
  event_type: string;
  status: string | null;
  summary: string | null;
  reason: string | null;
  message: string | null;
  sources: unknown;
  created_at: Date;
}

interface FallacyRow extends QueryResultRow {
  id: string | number;
  stream_id: string;
  model: string;
  speaker: string;
  speaker_label: string | null;
  fallacy: string;
  confidence: string;
  severity: string;
  quote: string;
  explanation: string;
  suggested_referee_response: string;
  transcript_line_count: number;
  detected_at: Date | string;
  created_at: Date;
}

interface CompromiseRow extends QueryResultRow {
  id: string | number;
  stream_id: string;
  model: string;
  generated_at: Date | string | null;
  transcript_line_count: number;
  suggestions: unknown;
  created_at: Date;
}

interface ArgumentRatingRow extends QueryResultRow {
  id: string | number;
  stream_id: string;
  model: string;
  generated_at: Date | string;
  transcript_line_count: number;
  overall_score: number;
  dimensions: unknown;
  strengths: unknown;
  risks: unknown;
  referee_focus: string;
  created_at: Date;
}

interface RefereeInterventionRow extends QueryResultRow {
  id: string | number;
  stream_id: string;
  intervention_id: string;
  generated_at: Date | string;
  category: string;
  priority: string;
  message: string;
  reason: string;
  source_event: string;
  source_id: string | null;
  speaker: string | null;
  speaker_label: string | null;
  created_at: Date;
}

interface RawEventRow extends QueryResultRow {
  id: string | number;
  stream_id: string | null;
  event_type: string;
  payload: unknown;
  created_at: Date;
}

function toSessionSummary(row: SessionSummaryRow): HistorySessionSummary {
  return {
    sessionId: row.session_id,
    createdAt: toIso(row.created_at),
    updatedAt: toIso(row.updated_at),
    startedAt: optionalIso(row.started_at),
    endedAt: optionalIso(row.ended_at),
    participantIds: row.participant_ids ?? [],
    transcriptLineCount: Number(row.transcript_line_count),
    claimCount: Number(row.claim_count),
    factCheckCount: Number(row.fact_check_count),
    fallacyCount: Number(row.fallacy_count),
    argumentRatingCount: Number(row.argument_rating_count),
    interventionCount: Number(row.intervention_count),
    compromiseCount: Number(row.compromise_count),
    debriefStatus: row.debrief_status ?? undefined,
  };
}

function toStreamSummary(row: StreamRow): HistoryStreamSummary {
  return {
    streamId: row.stream_id,
    participantId: row.participant_id,
    audioFormat: row.audio_format,
    startedAt: toIso(row.started_at),
    endedAt: optionalIso(row.ended_at),
    bytesReceived: Number(row.bytes_received),
    chunksReceived: Number(row.chunks_received),
    storagePath: row.storage_path ?? undefined,
    debriefStoragePath: row.debrief_storage_path ?? undefined,
    profileStoragePath: row.profile_storage_path ?? undefined,
    debriefStatus: row.debrief_status ?? undefined,
    refereeSettings: withDefaultRefereeSettings(
      isRecord(row.referee_settings) ? row.referee_settings : {},
    ),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function toSpeakerMapping(row: SpeakerMappingRow): HistorySpeakerMapping {
  return {
    speaker: row.speaker,
    speakerLabel: row.speaker_label,
    source: row.source,
    createdAt: toIso(row.created_at),
  };
}

function toTranscriptLine(row: TranscriptLineRow): HistoryTranscriptLine {
  return {
    id: Number(row.id),
    streamId: row.stream_id,
    speaker: row.speaker,
    speakerLabel: row.speaker_label ?? undefined,
    text: row.text,
    startMs: row.start_ms ?? undefined,
    endMs: row.end_ms ?? undefined,
    confidence: row.confidence ?? undefined,
    words: row.words,
    createdAt: toIso(row.created_at),
  };
}

function toClaim(row: ClaimRow): HistoryClaim {
  return {
    claimId: row.claim_id,
    streamId: row.stream_id,
    speaker: row.speaker,
    speakerLabel: row.speaker_label ?? undefined,
    text: row.text,
    reason: row.reason,
    status: row.status,
    startMs: row.start_ms ?? undefined,
    endMs: row.end_ms ?? undefined,
    createdAt: toIso(row.created_at),
  };
}

function toFactCheck(row: FactCheckRow): HistoryFactCheck {
  return {
    id: Number(row.id),
    claimId: row.claim_id,
    streamId: row.stream_id,
    provider: row.provider ?? undefined,
    eventType: row.event_type,
    status: row.status ?? undefined,
    summary: row.summary ?? undefined,
    reason: row.reason ?? undefined,
    message: row.message ?? undefined,
    sources: row.sources,
    createdAt: toIso(row.created_at),
  };
}

function toFallacy(row: FallacyRow): HistoryFallacyDetection {
  return {
    id: Number(row.id),
    streamId: row.stream_id,
    model: row.model,
    speaker: row.speaker,
    speakerLabel: row.speaker_label ?? undefined,
    fallacy: row.fallacy,
    confidence: row.confidence,
    severity: row.severity,
    quote: row.quote,
    explanation: row.explanation,
    suggestedRefereeResponse: row.suggested_referee_response,
    transcriptLineCount: Number(row.transcript_line_count),
    detectedAt: toIso(row.detected_at),
    createdAt: toIso(row.created_at),
  };
}

function toCompromise(row: CompromiseRow): HistoryCompromiseSuggestion {
  return {
    id: Number(row.id),
    streamId: row.stream_id,
    model: row.model,
    generatedAt: optionalIso(row.generated_at),
    transcriptLineCount: Number(row.transcript_line_count),
    suggestions: row.suggestions,
    createdAt: toIso(row.created_at),
  };
}

function toArgumentRating(row: ArgumentRatingRow): HistoryArgumentRating {
  return {
    id: Number(row.id),
    streamId: row.stream_id,
    model: row.model,
    generatedAt: toIso(row.generated_at),
    transcriptLineCount: Number(row.transcript_line_count),
    overallScore: Number(row.overall_score),
    dimensions: row.dimensions,
    strengths: row.strengths,
    risks: row.risks,
    refereeFocus: row.referee_focus,
    createdAt: toIso(row.created_at),
  };
}

function toRefereeIntervention(
  row: RefereeInterventionRow,
): HistoryRefereeIntervention {
  return {
    id: Number(row.id),
    streamId: row.stream_id,
    interventionId: row.intervention_id,
    generatedAt: toIso(row.generated_at),
    category: row.category,
    priority: row.priority,
    message: row.message,
    reason: row.reason,
    sourceEvent: row.source_event,
    sourceId: row.source_id ?? undefined,
    speaker: row.speaker ?? undefined,
    speakerLabel: row.speaker_label ?? undefined,
    createdAt: toIso(row.created_at),
  };
}

function toRawEvent(row: RawEventRow): HistoryRawEvent {
  return {
    id: Number(row.id),
    streamId: row.stream_id ?? undefined,
    eventType: row.event_type,
    payload: row.payload,
    createdAt: toIso(row.created_at),
  };
}

function optionalIso(value: Date | string | null): string | undefined {
  if (!value) {
    return undefined;
  }

  return toIso(value);
}

function toIso(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function assertNever(value: never): never {
  throw new Error(`Unhandled history event: ${JSON.stringify(value)}`);
}
