import { describe, expect, it } from 'vitest';
import {
  FallacyDetector,
  type FallacyAnalyzer,
} from '../src/fallacies/fallacyDetector.js';
import type { AppConfig } from '../src/config.js';
import type { ServerEvent, TranscriptFinalEvent } from '../src/protocol/messages.js';

describe('fallacy detector', () => {
  it('emits disabled when Gemini is not configured', () => {
    const events: ServerEvent[] = [];
    const detector = new FallacyDetector({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig(),
      emit: (event) => events.push(event),
    });

    detector.start();
    detector.close();

    expect(events).toEqual([
      {
        type: 'fallacy.disabled',
        provider: 'gemini',
        reason: 'missing_gemini_api_key',
      },
    ]);
  });

  it('emits medium-confidence fallacies with a referee response', async () => {
    const events: ServerEvent[] = [];
    const analyzer: FallacyAnalyzer = {
      analyze: async () => [
        {
          speaker: 'speaker_0',
          fallacy: 'straw_man',
          confidence: 'medium',
          severity: 'moderate',
          quote: 'So you are saying I should never have any free time.',
          explanation:
            'This may exaggerate the other person’s position rather than responding to their actual request.',
          suggestedRefereeResponse:
            'Pause there and restate the other person’s actual point before responding.',
        },
      ],
    };
    const detector = new FallacyDetector({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: (event) => events.push(event),
      analyzer,
    });

    detector.recordTranscript(
      transcriptFinal(
        'speaker_1',
        'I am asking for one evening each week where we plan the chores before they become urgent.',
      ),
    );
    detector.recordTranscript(
      transcriptFinal(
        'speaker_0',
        'So you are saying I should never have any free time and only clean the house forever.',
      ),
    );

    await detector.analyzeNow();
    detector.close();

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: 'fallacy.detected',
      provider: 'gemini',
      sessionId: 'session-1',
      streamId: 'stream-1',
      model: 'gemini-3.5-flash',
      speaker: 'speaker_0',
      fallacy: 'straw_man',
      confidence: 'medium',
      severity: 'moderate',
      suggestedRefereeResponse:
        'Pause there and restate the other person’s actual point before responding.',
    });
  });

  it('filters low-confidence fallacies by default', async () => {
    const events: ServerEvent[] = [];
    const analyzer: FallacyAnalyzer = {
      analyze: async () => [
        {
          speaker: 'speaker_0',
          fallacy: 'hasty_generalization',
          confidence: 'low',
          severity: 'minor',
          quote: 'You always do this.',
          explanation: 'This may overgeneralize from a single moment.',
          suggestedRefereeResponse:
            'Can we name the specific example rather than using always?',
        },
      ],
    };
    const detector = new FallacyDetector({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: (event) => events.push(event),
      analyzer,
    });

    detector.recordTranscript(
      transcriptFinal(
        'speaker_0',
        'You always do this, and every single conversation proves that you never listen to me.',
      ),
    );
    detector.recordTranscript(
      transcriptFinal(
        'speaker_1',
        'I am trying to listen right now, and I want to talk about this specific issue.',
      ),
    );

    await detector.analyzeNow();
    detector.close();

    expect(events).toEqual([]);
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
    fallacyDetectionEnabled: true,
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
