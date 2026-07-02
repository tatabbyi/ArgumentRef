import { randomUUID } from 'node:crypto';
import type {
  ClaimDetectedEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

export class ClaimDetector {
  private readonly seenClaims = new Set<string>();

  detect(event: TranscriptFinalEvent): ClaimDetectedEvent | null {
    const result = evaluateClaim(event.text);
    if (!result.checkable) {
      return null;
    }

    const dedupeKey = normalizeClaimKey(event.speaker, event.text);
    if (this.seenClaims.has(dedupeKey)) {
      return null;
    }

    this.seenClaims.add(dedupeKey);

    return {
      type: 'claim.detected',
      claimId: randomUUID(),
      sessionId: event.sessionId,
      streamId: event.streamId,
      speaker: event.speaker,
      text: event.text,
      reason: result.reason,
      status: 'queued',
      sourceEvent: 'transcript.final',
      startMs: event.startMs,
      endMs: event.endMs,
    };
  }
}

export interface ClaimEvaluation {
  checkable: boolean;
  reason: string;
}

export function evaluateClaim(text: string): ClaimEvaluation {
  const normalized = text.replace(/\s+/g, ' ').trim();
  const lower = ` ${normalized.toLowerCase()} `;
  const wordCount = normalized.split(/\s+/).filter(Boolean).length;

  if (wordCount < 5) {
    return notCheckable('too_short');
  }

  if (normalized.endsWith('?')) {
    return notCheckable('question');
  }

  if (/\b\d+(\.\d+)?%?\b/.test(lower)) {
    return checkable('contains_number');
  }

  if (/[£$€]\s?\d+/.test(normalized)) {
    return checkable('contains_money');
  }

  if (
    /\b(january|february|march|april|may|june|july|august|september|october|november|december|today|yesterday|tomorrow)\b/.test(
      lower,
    )
  ) {
    return checkable('contains_date_or_time_reference');
  }

  if (/\b(19|20)\d\d\b/.test(lower)) {
    return checkable('contains_year');
  }

  const checkablePhrases = [
    ' increased ',
    ' decreased ',
    ' reduced ',
    ' rose ',
    ' fell ',
    ' doubled ',
    ' tripled ',
    ' caused ',
    ' led to ',
    ' due to ',
    ' because ',
    ' always ',
    ' never ',
    ' every ',
    ' all ',
    ' none ',
    ' more than ',
    ' less than ',
    ' higher than ',
    ' lower than ',
    ' the most ',
    ' the least ',
  ];

  const phrase = checkablePhrases.find((candidate) => lower.includes(candidate));
  if (phrase) {
    return checkable(`contains_assertive_signal:${phrase.trim()}`);
  }

  return notCheckable('no_checkable_signal');
}

function checkable(reason: string): ClaimEvaluation {
  return {
    checkable: true,
    reason,
  };
}

function notCheckable(reason: string): ClaimEvaluation {
  return {
    checkable: false,
    reason,
  };
}

function normalizeClaimKey(speaker: string, text: string): string {
  return `${speaker}:${text.toLowerCase().replace(/\W+/g, ' ').trim()}`;
}
