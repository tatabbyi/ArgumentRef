import { describe, expect, it } from 'vitest';
import { GoogleFactCheckProvider } from '../src/factChecks/googleFactCheckProvider.js';
import type { ClaimDetectedEvent } from '../src/protocol/messages.js';

describe('google fact check provider', () => {
  it('returns matched fact-check sources from Google responses', async () => {
    const provider = new GoogleFactCheckProvider(
      {
        googleFactCheckApiKey: 'test-key',
        googleFactCheckLanguageCode: 'en-US',
        googleFactCheckPageSize: 3,
      },
      async () =>
        new Response(
          JSON.stringify({
            claims: [
              {
                text: 'The earth is flat.',
                claimReview: [
                  {
                    title: 'No, the earth is not flat',
                    url: 'https://example.com/fact-check',
                    textualRating: 'False',
                    publisher: {
                      name: 'Example Fact Check',
                    },
                  },
                ],
              },
            ],
          }),
          { status: 200 },
        ),
    );

    const result = await provider.checkClaim(claimDetected());

    expect(result.status).toBe('matched_fact_check');
    expect(result.sources).toEqual([
      {
        title: 'No, the earth is not flat',
        url: 'https://example.com/fact-check',
        publisher: 'Example Fact Check',
        rating: 'False',
        reviewedClaim: 'The earth is flat.',
      },
    ]);
  });

  it('returns no_match when Google has no claim reviews', async () => {
    const provider = new GoogleFactCheckProvider(
      {
        googleFactCheckApiKey: 'test-key',
        googleFactCheckLanguageCode: 'en-US',
        googleFactCheckPageSize: 3,
      },
      async () => new Response(JSON.stringify({ claims: [] }), { status: 200 }),
    );

    const result = await provider.checkClaim(claimDetected());

    expect(result.status).toBe('no_match');
    expect(result.sources).toEqual([]);
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
