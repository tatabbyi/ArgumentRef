import type {
  InterruptionDetectedEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

const MIN_OVERLAP_MS = 120;
const TIGHT_TAKEOVER_MS = 320;
const RECENT_WINDOW_MS = 8000;
const MAX_RECENT_TURNS = 24;
const DEDUPE_BUCKET_MS = 250;

const backchannels = new Set([
  'ah',
  'alright',
  'fine',
  'got it',
  'hm',
  'hmm',
  'mhm',
  'mm',
  'mmhm',
  'okay',
  'ok',
  'right',
  'sure',
  'uh huh',
  'uh-huh',
  'yeah',
  'yep',
  'yes',
]);

interface Turn {
  speaker: string;
  speakerLabel?: string;
  text: string;
  startMs: number;
  endMs: number;
  wordCount: number;
}

interface Assessment {
  reason: InterruptionDetectedEvent['reason'];
  overlapMs: number;
  gapMs: number;
  confidence: number;
}

export class InterruptionDetector {
  private readonly recentTurns: Turn[] = [];
  private readonly emittedKeys = new Set<string>();

  recordTranscript(event: TranscriptFinalEvent): InterruptionDetectedEvent | null {
    const current = toTurn(event);
    if (!current) {
      return null;
    }

    const candidate = this.findInterruptedTurn(current);
    this.remember(current);

    if (!candidate) {
      return null;
    }

    const assessment = assessInterruption(candidate, current);
    if (!assessment) {
      return null;
    }

    const key = [
      current.speaker,
      candidate.speaker,
      bucket(current.startMs),
      bucket(candidate.endMs),
    ].join(':');

    if (this.emittedKeys.has(key)) {
      return null;
    }
    this.emittedKeys.add(key);

    return {
      type: 'interruption.detected',
      provider: 'argumentref',
      sessionId: event.sessionId,
      streamId: event.streamId,
      interrupter: current.speaker,
      interrupterLabel: current.speakerLabel,
      interrupted: candidate.speaker,
      interruptedLabel: candidate.speakerLabel,
      interrupterText: truncate(current.text, 160),
      interruptedText: truncate(candidate.text, 160),
      startMs: current.startMs,
      endMs: current.endMs,
      overlapMs: assessment.overlapMs,
      gapMs: assessment.gapMs,
      confidence: assessment.confidence,
      reason: assessment.reason,
      sourceEvent: 'transcript.final',
    };
  }

  private findInterruptedTurn(current: Turn): Turn | null {
    for (let i = this.recentTurns.length - 1; i >= 0; i -= 1) {
      const previous = this.recentTurns[i];
      if (!previous || previous.speaker === current.speaker) {
        continue;
      }

      if (previous.speaker === 'speaker_unknown' || isBackchannel(previous)) {
        continue;
      }

      const currentStartedAfterPrevious = current.startMs > previous.startMs + 80;
      const nearPrevious = current.startMs - previous.endMs <= TIGHT_TAKEOVER_MS;
      if (currentStartedAfterPrevious && nearPrevious) {
        return previous;
      }
    }

    return null;
  }

  private remember(turn: Turn): void {
    if (turn.speaker === 'speaker_unknown') {
      return;
    }

    this.recentTurns.push(turn);
    this.recentTurns.sort((a, b) => a.startMs - b.startMs);

    const cutoff = turn.startMs - RECENT_WINDOW_MS;
    while (
      this.recentTurns.length > 0 &&
      (this.recentTurns.length > MAX_RECENT_TURNS ||
        this.recentTurns[0].endMs < cutoff)
    ) {
      this.recentTurns.shift();
    }
  }
}

function assessInterruption(previous: Turn, current: Turn): Assessment | null {
  const overlapMs = Math.max(0, previous.endMs - current.startMs);
  const gapMs = Math.max(0, current.startMs - previous.endMs);

  if (isBackchannel(current)) {
    return null;
  }

  if (overlapMs >= MIN_OVERLAP_MS) {
    const confidence = clamp(
      0.68 +
        Math.min(overlapMs, 1200) / 1200 * 0.22 +
        (isLikelyUnfinished(previous) ? 0.06 : 0) +
        (current.wordCount >= 3 ? 0.04 : 0),
      0.68,
      0.96,
    );

    return {
      reason: 'speaker_overlap',
      overlapMs,
      gapMs,
      confidence: roundConfidence(confidence),
    };
  }

  if (
    gapMs <= TIGHT_TAKEOVER_MS &&
    isLikelyUnfinished(previous) &&
    current.wordCount >= 2
  ) {
    const confidence = clamp(
      0.72 - gapMs / TIGHT_TAKEOVER_MS * 0.16 + (current.wordCount >= 5 ? 0.04 : 0),
      0.52,
      0.76,
    );

    return {
      reason: 'tight_takeover',
      overlapMs,
      gapMs,
      confidence: roundConfidence(confidence),
    };
  }

  return null;
}

function toTurn(event: TranscriptFinalEvent): Turn | null {
  const text = event.text.trim();
  if (!text) {
    return null;
  }

  const startMs = event.startMs ?? minWordTime(event, 'startMs');
  const endMs = event.endMs ?? maxWordTime(event, 'endMs');
  if (!isFiniteNumber(startMs) || !isFiniteNumber(endMs) || endMs <= startMs) {
    return null;
  }

  return {
    speaker: event.speaker,
    speakerLabel: event.speakerLabel,
    text,
    startMs,
    endMs,
    wordCount: countWords(text),
  };
}

function minWordTime(
  event: TranscriptFinalEvent,
  key: 'startMs' | 'endMs',
): number | undefined {
  const values = event.words
    .filter((word) => word.speaker === event.speaker)
    .map((word) => word[key])
    .filter(isFiniteNumber);
  return values.length > 0 ? Math.min(...values) : undefined;
}

function maxWordTime(
  event: TranscriptFinalEvent,
  key: 'startMs' | 'endMs',
): number | undefined {
  const values = event.words
    .filter((word) => word.speaker === event.speaker)
    .map((word) => word[key])
    .filter(isFiniteNumber);
  return values.length > 0 ? Math.max(...values) : undefined;
}

function isBackchannel(turn: Turn): boolean {
  const normalized = normalize(turn.text);
  return turn.wordCount <= 2 && backchannels.has(normalized);
}

function isLikelyUnfinished(turn: Turn): boolean {
  return turn.wordCount >= 4 && !/[.!?]["')\]]?$/.test(turn.text.trim());
}

function countWords(text: string): number {
  return text.split(/\s+/).filter(Boolean).length;
}

function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}\s-]+/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function roundConfidence(value: number): number {
  return Math.round(value * 100) / 100;
}

function bucket(value: number): number {
  return Math.round(value / DEDUPE_BUCKET_MS);
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
