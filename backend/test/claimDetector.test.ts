import { describe, expect, it } from 'vitest';
import { ClaimDetector, evaluateClaim } from '../src/claims/claimDetector.js';
import type { ServerEvent } from '../src/protocol/messages.js';

describe('claim detector', () => {
  it('flags statements with numeric claims', () => {
    const result = evaluateClaim('Revenue increased by 18 percent after launch.');

    expect(result.checkable).toBe(true);
    expect(result.reason).toBe('contains_number');
  });

  it('does not flag short conversational filler', () => {
    const result = evaluateClaim('I agree with that.');

    expect(result.checkable).toBe(false);
  });

  it('emits one claim event per unique final transcript', () => {
    const detector = new ClaimDetector();
    const transcript = transcriptFinal({
      text: 'The rollout caused support tickets to increase.',
    });

    const first = detector.detect(transcript);
    const second = detector.detect(transcript);

    expect(first).toMatchObject({
      type: 'claim.detected',
      speaker: 'speaker_0',
      text: 'The rollout caused support tickets to increase.',
      status: 'queued',
      sourceEvent: 'transcript.final',
    });
    expect(second).toBeNull();
  });
});

function transcriptFinal(
  overrides: Partial<Extract<ServerEvent, { type: 'transcript.final' }>>,
): Extract<ServerEvent, { type: 'transcript.final' }> {
  return {
    type: 'transcript.final',
    provider: 'deepgram',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker: 'speaker_0',
    text: 'Default text',
    words: [],
    ...overrides,
  };
}
