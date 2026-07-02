import { describe, expect, it } from 'vitest';
import {
  ArgumentRater,
  type ArgumentRatingGenerator,
} from '../src/ratings/argumentRater.js';
import type { AppConfig } from '../src/config.js';
import type { ServerEvent, TranscriptFinalEvent } from '../src/protocol/messages.js';

describe('argument rater', () => {
  it('emits disabled when Gemini is not configured', () => {
    const events: ServerEvent[] = [];
    const rater = new ArgumentRater({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig(),
      emit: (event) => events.push(event),
    });

    rater.start();
    rater.close();

    expect(events).toEqual([
      {
        type: 'argument.rating.disabled',
        provider: 'gemini',
        reason: 'missing_gemini_api_key',
      },
    ]);
  });

  it('emits normalized argument ratings once there is enough transcript', async () => {
    const events: ServerEvent[] = [];
    const generator: ArgumentRatingGenerator = {
      rate: async () => ({
        overallScore: 84.6,
        dimensions: {
          clarity: 82.3,
          evidenceQuality: 66.8,
          logicalConsistency: 78.1,
          listening: 71.9,
          emotionalControl: 101,
          fairness: 74.2,
        },
        strengths: [
          ' Both speakers are naming practical constraints. ',
          'They are starting to propose workable next steps.',
        ],
        risks: ['The examples are still broad rather than specific.'],
        refereeFocus:
          'Ask each person to give one concrete example and one acceptable next step.',
      }),
    };
    const rater = new ArgumentRater({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: (event) => events.push(event),
      generator,
    });

    recordSubstantialTranscript(rater);

    await rater.analyzeNow();
    rater.close();

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: 'argument.rating.updated',
      provider: 'gemini',
      sessionId: 'session-1',
      streamId: 'stream-1',
      model: 'gemini-3.5-flash',
      transcriptLineCount: 4,
      overallScore: 85,
      dimensions: {
        clarity: 82,
        evidenceQuality: 67,
        logicalConsistency: 78,
        listening: 72,
        emotionalControl: 100,
        fairness: 74,
      },
      strengths: [
        'Both speakers are naming practical constraints.',
        'They are starting to propose workable next steps.',
      ],
      risks: ['The examples are still broad rather than specific.'],
      refereeFocus:
        'Ask each person to give one concrete example and one acceptable next step.',
    });
  });

  it('does not re-run analysis without new transcript lines', async () => {
    let calls = 0;
    const generator: ArgumentRatingGenerator = {
      rate: async () => {
        calls++;
        return {
          overallScore: 70,
          dimensions: {
            clarity: 70,
            evidenceQuality: 60,
            logicalConsistency: 70,
            listening: 65,
            emotionalControl: 72,
            fairness: 68,
          },
          strengths: ['The discussion has enough substance to evaluate.'],
          risks: ['The next step is not specific yet.'],
          refereeFocus: 'Move from positions to one concrete request each.',
        };
      },
    };
    const rater = new ArgumentRater({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: () => undefined,
      generator,
    });

    recordSubstantialTranscript(rater);

    await rater.analyzeNow();
    await rater.analyzeNow();
    rater.close();

    expect(calls).toBe(1);
  });
});

function baseConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    host: '127.0.0.1',
    port: 0,
    audioStorageDir: '/tmp/argumentref-test',
    maxAudioChunkBytes: 1024 * 1024,
    databaseSsl: false,
    deepgramModel: 'nova-3',
    deepgramLanguage: 'en-US',
    factCheckEnabled: false,
    factCheckProvider: 'google-fact-check',
    googleFactCheckLanguageCode: 'en-US',
    googleFactCheckPageSize: 3,
    factCheckMaxClaimsPerSession: 5,
    geminiModel: 'gemini-3.5-flash',
    compromiseInitialDelayMs: 60_000,
    compromiseIntervalMs: 30_000,
    fallacyDetectionEnabled: false,
    fallacyAnalysisIntervalMs: 20_000,
    fallacyMinConfidence: 'medium',
    argumentRatingEnabled: true,
    argumentRatingIntervalMs: 30_000,
    argumentRatingMinTranscriptLines: 4,
    refereeInterventionsEnabled: false,
    refereeInterventionCooldownMs: 10_000,
    ...overrides,
  };
}

function recordSubstantialTranscript(rater: ArgumentRater): void {
  rater.recordTranscript(
    transcriptFinal(
      'speaker_0',
      'I need a clearer plan because the chores keep landing on me after work and I feel like the pattern never changes.',
    ),
  );
  rater.recordTranscript(
    transcriptFinal(
      'speaker_1',
      'I can take more of them, but my shifts move around and I need some flexibility instead of a fixed promise every single night.',
    ),
  );
  rater.recordTranscript(
    transcriptFinal(
      'speaker_0',
      'That makes sense, but when there is no backup plan I end up doing everything at the last minute and then I get resentful.',
    ),
  );
  rater.recordTranscript(
    transcriptFinal(
      'speaker_1',
      'I hear that, so maybe we choose the main days together and also pick backup days when work runs late.',
    ),
  );
}

function transcriptFinal(speaker: string, text: string): TranscriptFinalEvent {
  return {
    type: 'transcript.final',
    provider: 'deepgram',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker,
    text,
    words: [],
  };
}
