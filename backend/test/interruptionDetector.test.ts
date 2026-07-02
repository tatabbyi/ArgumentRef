import { describe, expect, it } from 'vitest';
import { InterruptionDetector } from '../src/interruptions/interruptionDetector.js';
import type { TranscriptFinalEvent } from '../src/protocol/messages.js';

describe('interruption detector', () => {
  it('emits who cut off whom when speaker timings overlap', () => {
    const detector = new InterruptionDetector();
    detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_0',
        speakerLabel: 'Ada',
        text: 'I was trying to explain this because',
        startMs: 0,
        endMs: 2200,
      }),
    );

    const event = detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_1',
        speakerLabel: 'Ben',
        text: "No that's not fair",
        startMs: 1750,
        endMs: 2800,
      }),
    );

    expect(event).toMatchObject({
      type: 'interruption.detected',
      interrupter: 'speaker_1',
      interrupterLabel: 'Ben',
      interrupted: 'speaker_0',
      interruptedLabel: 'Ada',
      overlapMs: 450,
      gapMs: 0,
      reason: 'speaker_overlap',
      sourceEvent: 'transcript.final',
    });
    expect(event?.confidence).toBeGreaterThanOrEqual(0.75);
  });

  it('emits lower-confidence cutoffs for very tight unfinished takeovers', () => {
    const detector = new InterruptionDetector();
    detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_0',
        text: 'The thing I need you to hear is',
        startMs: 0,
        endMs: 1800,
      }),
    );

    const event = detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_1',
        text: 'I do hear you',
        startMs: 1920,
        endMs: 2600,
      }),
    );

    expect(event).toMatchObject({
      interrupter: 'speaker_1',
      interrupted: 'speaker_0',
      overlapMs: 0,
      gapMs: 120,
      reason: 'tight_takeover',
    });
    expect(event?.confidence).toBeGreaterThanOrEqual(0.6);
    expect(event?.confidence).toBeLessThan(0.8);
  });

  it('does not treat short acknowledgements as floor-taking interruptions', () => {
    const detector = new InterruptionDetector();
    detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_0',
        text: 'I want to finish the thought before we switch topics',
        startMs: 0,
        endMs: 3000,
      }),
    );

    const event = detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_1',
        text: 'yeah',
        startMs: 1700,
        endMs: 1950,
      }),
    );

    expect(event).toBeNull();
  });

  it('dedupes the same detected interruption', () => {
    const detector = new InterruptionDetector();
    detector.recordTranscript(
      transcriptFinal({
        speaker: 'speaker_0',
        text: 'I need a minute to finish what I am saying',
        startMs: 0,
        endMs: 2400,
      }),
    );

    const secondTurn = transcriptFinal({
      speaker: 'speaker_1',
      text: 'Wait that is not what happened',
      startMs: 2000,
      endMs: 2900,
    });

    expect(detector.recordTranscript(secondTurn)).not.toBeNull();
    expect(detector.recordTranscript(secondTurn)).toBeNull();
  });
});

function transcriptFinal(
  overrides: Partial<TranscriptFinalEvent>,
): TranscriptFinalEvent {
  const speaker = overrides.speaker ?? 'speaker_0';
  const text = overrides.text ?? 'hello';
  const startMs = overrides.startMs ?? 0;
  const endMs = overrides.endMs ?? startMs + 500;

  return {
    type: 'transcript.final',
    provider: 'deepgram',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker,
    speakerLabel: overrides.speakerLabel,
    text,
    startMs,
    endMs,
    confidence: 0.92,
    words:
      overrides.words ??
      text.split(/\s+/).map((word, index, words) => {
        const step = Math.max(1, Math.floor((endMs - startMs) / words.length));
        return {
          word,
          speaker,
          startMs: startMs + index * step,
          endMs: index === words.length - 1 ? endMs : startMs + (index + 1) * step,
          confidence: 0.9,
        };
      }),
    ...overrides,
  };
}
