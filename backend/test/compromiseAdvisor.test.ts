import { describe, expect, it } from 'vitest';
import {
  CompromiseAdvisor,
  type CompromiseGenerator,
} from '../src/compromises/compromiseAdvisor.js';
import type { AppConfig } from '../src/config.js';
import type { ServerEvent, TranscriptFinalEvent } from '../src/protocol/messages.js';

describe('compromise advisor', () => {
  it('emits disabled when Gemini is not configured', () => {
    const events: ServerEvent[] = [];
    const advisor = new CompromiseAdvisor({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig(),
      emit: (event) => events.push(event),
    });

    advisor.start();
    advisor.close();

    expect(events).toEqual([
      {
        type: 'compromise.disabled',
        provider: 'gemini',
        reason: 'missing_gemini_api_key',
      },
    ]);
  });

  it('emits ranked compromise suggestions once there is enough transcript', async () => {
    const events: ServerEvent[] = [];
    const generator: CompromiseGenerator = {
      generate: async () => [
        {
          title: 'Alternate quiet and planning nights',
          summary: 'Protect two quiet evenings and reserve one planning check-in.',
          whyItCouldWork: 'It gives one person calm time and the other a reliable forum.',
          score: 74,
        },
        {
          title: 'Two-week trial schedule',
          summary: 'Try the new chore split for two weeks, then revise together.',
          whyItCouldWork: 'It lowers commitment risk while answering both fairness concerns.',
          score: 93,
          quality: 'really_good',
          pushLevel: 'urgent',
        },
      ],
    };
    const advisor = new CompromiseAdvisor({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: (event) => events.push(event),
      generator,
    });

    advisor.recordTranscript(
      transcriptFinal(
        'speaker_0',
        'I need the chores to feel predictable because I am carrying too much mental load after work.',
      ),
    );
    advisor.recordTranscript(
      transcriptFinal(
        'speaker_1',
        'I can help more, but I need room to change days when my shifts move around.',
      ),
    );

    await advisor.analyzeNow();
    advisor.close();

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: 'compromise.suggested',
      provider: 'gemini',
      sessionId: 'session-1',
      streamId: 'stream-1',
      model: 'gemini-3.5-flash',
      transcriptLineCount: 2,
      suggestions: [
        {
          rank: 1,
          title: 'Two-week trial schedule',
          score: 93,
          quality: 'really_good',
          pushLevel: 'urgent',
        },
        {
          rank: 2,
          title: 'Alternate quiet and planning nights',
          score: 74,
          quality: 'promising',
          pushLevel: 'normal',
        },
      ],
    });
  });

  it('does not re-run analysis without new transcript lines', async () => {
    let calls = 0;
    const generator: CompromiseGenerator = {
      generate: async () => {
        calls++;
        return [
          {
            title: 'Trial plan',
            summary: 'Try one change for a week and review it.',
            whyItCouldWork: 'Both people get a low-risk test.',
            score: 82,
          },
        ];
      },
    };
    const advisor = new CompromiseAdvisor({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: () => undefined,
      generator,
    });

    advisor.recordTranscript(
      transcriptFinal(
        'speaker_0',
        'I want a concrete plan because otherwise this same problem returns every week and I feel ignored.',
      ),
    );
    advisor.recordTranscript(
      transcriptFinal(
        'speaker_1',
        'I want flexibility because my week changes a lot and I do not want to promise impossible things.',
      ),
    );

    await advisor.analyzeNow();
    await advisor.analyzeNow();
    advisor.close();

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
    argumentRatingEnabled: false,
    argumentRatingIntervalMs: 30_000,
    argumentRatingMinTranscriptLines: 4,
    refereeInterventionsEnabled: false,
    refereeInterventionCooldownMs: 10_000,
    elevenLabsVoiceId: 'test-voice',
    elevenLabsModelId: 'eleven_multilingual_v2',
    elevenLabsOutputFormat: 'mp3_44100_128',
    elevenLabsMaxTextChars: 600,
    ...overrides,
  };
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
