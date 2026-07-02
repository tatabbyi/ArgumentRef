import { describe, expect, it } from 'vitest';
import { FactCheckService } from '../src/factChecks/factCheckService.js';
import type { FactCheckProvider } from '../src/factChecks/googleFactCheckProvider.js';
import type { ClaimDetectedEvent, ServerEvent } from '../src/protocol/messages.js';

describe('fact check service', () => {
  it('emits started and completed events for a claim', async () => {
    const events: ServerEvent[] = [];
    const provider: FactCheckProvider = {
      checkClaim: async () => ({
        status: 'matched_fact_check',
        summary: 'Found a published fact check result.',
        sources: [
          {
            title: 'Fact check',
            url: 'https://example.com/fact-check',
          },
        ],
      }),
    };
    const service = new FactCheckService(
      {
        factCheckEnabled: true,
        googleFactCheckApiKey: 'test-key',
        factCheckMaxClaimsPerSession: 5,
      },
      provider,
    );

    service.checkClaim(claimDetected(), (event) => events.push(event));
    await waitForMicrotasks();

    expect(events).toEqual([
      expect.objectContaining({
        type: 'fact_check.started',
        claimId: 'claim-1',
      }),
      expect.objectContaining({
        type: 'fact_check.completed',
        claimId: 'claim-1',
        status: 'matched_fact_check',
      }),
    ]);
  });

  it('skips claims after the session limit', () => {
    const events: ServerEvent[] = [];
    const provider: FactCheckProvider = {
      checkClaim: async () => ({
        status: 'no_match',
        summary: 'No matching published fact check was found.',
        sources: [],
      }),
    };
    const service = new FactCheckService(
      {
        factCheckEnabled: true,
        googleFactCheckApiKey: 'test-key',
        factCheckMaxClaimsPerSession: 0,
      },
      provider,
    );

    service.checkClaim(claimDetected(), (event) => events.push(event));

    expect(events).toEqual([
      expect.objectContaining({
        type: 'fact_check.skipped',
        reason: 'session_limit_reached',
      }),
    ]);
  });
});

function claimDetected(): ClaimDetectedEvent {
  return {
    type: 'claim.detected',
    claimId: 'claim-1',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker: 'speaker_0',
    speakerLabel: 'PersonA',
    text: 'The earth is flat.',
    reason: 'contains_assertive_signal:all',
    status: 'queued',
    sourceEvent: 'transcript.final',
  };
}

function waitForMicrotasks(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}
