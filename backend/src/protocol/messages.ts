import { z } from 'zod';

export const audioFormatSchema = z.object({
  encoding: z
    .enum(['pcm16', 'webm-opus', 'aac', 'unknown'])
    .default('unknown'),
  sampleRateHz: z.number().int().positive().optional(),
  channels: z.number().int().positive().max(8).optional(),
});

export type AudioFormat = z.infer<typeof audioFormatSchema>;

export const clientControlMessageSchema = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('session.start'),
    sessionId: z.string().min(1).max(120).optional(),
    participantId: z.string().min(1).max(120).optional(),
    audio: audioFormatSchema.optional(),
  }),
  z.object({
    type: z.literal('audio.commit'),
  }),
  z.object({
    type: z.literal('session.stop'),
  }),
]);

export type ClientControlMessage = z.infer<typeof clientControlMessageSchema>;

export interface TranscriptWord {
  word: string;
  speaker: string;
  speakerLabel?: string;
  startMs?: number;
  endMs?: number;
  confidence?: number;
}

interface BaseTranscriptEvent {
  provider: 'deepgram';
  sessionId: string;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  text: string;
  startMs?: number;
  endMs?: number;
  confidence?: number;
  words: TranscriptWord[];
}

export type TranscriptPartialEvent = BaseTranscriptEvent & {
  type: 'transcript.partial';
};

export type TranscriptFinalEvent = BaseTranscriptEvent & {
  type: 'transcript.final';
};

export interface ClaimDetectedEvent {
  type: 'claim.detected';
  claimId: string;
  sessionId: string;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  text: string;
  reason: string;
  status: 'queued';
  sourceEvent: 'transcript.final';
  startMs?: number;
  endMs?: number;
}

export type CompromiseQuality =
  | 'weak'
  | 'promising'
  | 'strong'
  | 'really_good';

export type CompromisePushLevel = 'normal' | 'firm' | 'urgent';

export interface CompromiseSuggestion {
  id: string;
  rank: number;
  title: string;
  summary: string;
  whyItCouldWork: string;
  score: number;
  quality: CompromiseQuality;
  pushLevel: CompromisePushLevel;
}

export interface CompromiseSuggestedEvent {
  type: 'compromise.suggested';
  provider: 'gemini';
  sessionId: string;
  streamId: string;
  model: string;
  generatedAt: string;
  transcriptLineCount: number;
  suggestions: CompromiseSuggestion[];
}

export interface CompromiseDisabledEvent {
  type: 'compromise.disabled';
  provider: 'gemini';
  reason: 'missing_gemini_api_key';
}

export interface CompromiseErrorEvent {
  type: 'compromise.error';
  provider: 'gemini';
  message: string;
}

export type FallacyKind =
  | 'ad_hominem'
  | 'straw_man'
  | 'false_dichotomy'
  | 'slippery_slope'
  | 'hasty_generalization'
  | 'circular_reasoning'
  | 'red_herring'
  | 'whataboutism'
  | 'burden_of_proof_shift'
  | 'appeal_to_authority'
  | 'correlation_causation';

export type FallacyConfidence = 'low' | 'medium' | 'high';

export type FallacySeverity = 'minor' | 'moderate' | 'serious';

export interface FallacyDetectedEvent {
  type: 'fallacy.detected';
  provider: 'gemini';
  sessionId: string;
  streamId: string;
  model: string;
  detectedAt: string;
  transcriptLineCount: number;
  speaker: string;
  speakerLabel?: string;
  fallacy: FallacyKind;
  confidence: FallacyConfidence;
  severity: FallacySeverity;
  quote: string;
  explanation: string;
  suggestedRefereeResponse: string;
}

export interface FallacyDisabledEvent {
  type: 'fallacy.disabled';
  provider: 'gemini';
  reason: 'disabled' | 'missing_gemini_api_key';
}

export interface FallacyErrorEvent {
  type: 'fallacy.error';
  provider: 'gemini';
  message: string;
}

export interface ArgumentRatingDimensions {
  clarity: number;
  evidenceQuality: number;
  logicalConsistency: number;
  listening: number;
  emotionalControl: number;
  fairness: number;
}

export interface ArgumentRatingUpdatedEvent {
  type: 'argument.rating.updated';
  provider: 'gemini';
  sessionId: string;
  streamId: string;
  model: string;
  generatedAt: string;
  transcriptLineCount: number;
  overallScore: number;
  dimensions: ArgumentRatingDimensions;
  strengths: string[];
  risks: string[];
  refereeFocus: string;
}

export interface ArgumentRatingDisabledEvent {
  type: 'argument.rating.disabled';
  provider: 'gemini';
  reason: 'disabled' | 'missing_gemini_api_key';
}

export interface ArgumentRatingErrorEvent {
  type: 'argument.rating.error';
  provider: 'gemini';
  message: string;
}

export type ConversationDebriefStatus =
  | 'completed'
  | 'disabled'
  | 'skipped'
  | 'failed';

export type SpeakerDiarizationStatus =
  | 'no_words'
  | 'missing_speaker_labels'
  | 'single_speaker'
  | 'multiple_speakers';

export interface SpeakerDiarizationStatusEvent {
  type: 'speaker.diarization_status';
  provider: 'deepgram';
  sessionId: string;
  streamId: string;
  status: SpeakerDiarizationStatus;
  speakers: string[];
  totalWords: number;
  wordsWithSpeaker: number;
  message: string;
}

export interface SpeakerMappedEvent {
  type: 'speaker.mapped';
  sessionId: string;
  streamId: string;
  speaker: string;
  speakerLabel: string;
  source: 'query_calibration';
}

export type FactCheckStatus = 'matched_fact_check' | 'no_match';

export interface FactCheckSource {
  title: string;
  url: string;
  publisher?: string;
  rating?: string;
  reviewedClaim?: string;
}

export interface FactCheckStartedEvent {
  type: 'fact_check.started';
  provider: 'google-fact-check';
  claimId: string;
  sessionId: string;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  claim: string;
}

export interface FactCheckCompletedEvent {
  type: 'fact_check.completed';
  provider: 'google-fact-check';
  claimId: string;
  sessionId: string;
  streamId: string;
  speaker: string;
  speakerLabel?: string;
  claim: string;
  status: FactCheckStatus;
  summary: string;
  sources: FactCheckSource[];
}

export interface FactCheckSkippedEvent {
  type: 'fact_check.skipped';
  claimId: string;
  sessionId: string;
  streamId: string;
  reason:
    | 'disabled'
    | 'missing_api_key'
    | 'session_limit_reached'
    | 'provider_unavailable';
}

export interface FactCheckFailedEvent {
  type: 'fact_check.failed';
  provider: 'google-fact-check';
  claimId: string;
  sessionId: string;
  streamId: string;
  message: string;
}

export type ServerEvent =
  | {
      type: 'session.started';
      sessionId: string;
      streamId: string;
      participantId: string;
      audio: AudioFormat;
      acceptedBinaryAudio: true;
    }
  | {
      type: 'audio.ack';
      sessionId: string;
      streamId: string;
      bytesReceived: number;
      chunksReceived: number;
    }
  | {
      type: 'audio.committed';
      sessionId: string;
      streamId: string;
      bytesReceived: number;
      chunksReceived: number;
    }
  | {
      type: 'session.ended';
      sessionId: string;
      streamId: string;
      participantId: string;
      bytesReceived: number;
      chunksReceived: number;
      storagePath: string;
      debriefStoragePath?: string;
      profileStoragePath?: string;
      debriefStatus?: ConversationDebriefStatus;
    }
  | {
      type: 'transcription.connected';
      provider: 'deepgram';
      sessionId: string;
      streamId: string;
      model: string;
      language: string;
      diarization: {
        requested: true;
        model: 'latest';
      };
    }
  | {
      type: 'transcription.disabled';
      reason: string;
    }
  | {
      type: 'transcription.error';
      provider: 'deepgram';
      message: string;
    }
  | TranscriptPartialEvent
  | TranscriptFinalEvent
  | ClaimDetectedEvent
  | CompromiseSuggestedEvent
  | CompromiseDisabledEvent
  | CompromiseErrorEvent
  | FallacyDetectedEvent
  | FallacyDisabledEvent
  | FallacyErrorEvent
  | ArgumentRatingUpdatedEvent
  | ArgumentRatingDisabledEvent
  | ArgumentRatingErrorEvent
  | SpeakerDiarizationStatusEvent
  | SpeakerMappedEvent
  | FactCheckStartedEvent
  | FactCheckCompletedEvent
  | FactCheckSkippedEvent
  | FactCheckFailedEvent
  | {
      type: 'error';
      code: string;
      message: string;
    };

export function parseClientControlMessage(data: string): ClientControlMessage {
  return clientControlMessageSchema.parse(JSON.parse(data));
}

export function serializeServerEvent(event: ServerEvent): string {
  return JSON.stringify(event);
}
