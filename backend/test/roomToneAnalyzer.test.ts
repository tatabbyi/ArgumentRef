import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../src/config.js';
import type {
  RoomToneAnalyzedEvent,
  ServerEvent,
  TranscriptFinalEvent,
} from '../src/protocol/messages.js';
import {
  RoomToneAnalyzer,
  splitIntoSentences,
  type RoomToneGenerator,
  type RoomToneGeneratorInput,
} from '../src/roomTone/roomToneAnalyzer.js';

describe('room tone analyzer', () => {
  it('emits disabled when Gemini is not configured', () => {
    const events: ServerEvent[] = [];
    const analyzer = new RoomToneAnalyzer({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig(),
      emit: (event) => events.push(event),
    });

    analyzer.start();
    analyzer.close();

    expect(events).toEqual([
      {
        type: 'room_tone.disabled',
        provider: 'gemini',
        reason: 'missing_gemini_api_key',
      },
    ]);
  });

  it('analyzes each sentence with the previous sentences as context', async () => {
    const events: ServerEvent[] = [];
    const calls: RoomToneGeneratorInput[] = [];
    const generator: RoomToneGenerator = {
      analyze: async (input) => {
        calls.push(input);
        const isRepair = input.sentence.text.includes('sorry');
        return {
          dominantTone: isRepair ? 'apologetic' : 'angry',
          trend: isRepair ? 'de_escalating' : 'escalating',
          intensity: isRepair ? 42 : 88,
          confidence: 0.9,
          summary: isRepair ? 'Repair attempt' : 'Sharp accusation',
          signals: isRepair ? ['apologetic', 'repair_attempt'] : ['angry'],
          phrases: [
            {
              text: isRepair ? 'sorry for shouting' : 'never listen',
              signal: isRepair ? 'apologetic' : 'angry',
            },
          ],
        };
      },
    };
    const analyzer = new RoomToneAnalyzer({
      sessionId: 'session-1',
      streamId: 'stream-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      emit: (event) => events.push(event),
      generator,
    });

    analyzer.start();
    analyzer.recordTranscript(
      transcriptFinal('speaker_0', 'You never listen. I am sorry for shouting.'),
    );
    await analyzer.flushForTest();
    analyzer.close();

    expect(calls).toHaveLength(2);
    expect(calls[0].context).toHaveLength(0);
    expect(calls[1].context.map((sentence) => sentence.text)).toEqual([
      'You never listen.',
    ]);

    const analyzed = events as RoomToneAnalyzedEvent[];
    expect(analyzed.map((event) => event.type)).toEqual([
      'room_tone.analyzed',
      'room_tone.analyzed',
    ]);
    expect(analyzed[0]).toMatchObject({
      model: 'gemini-3.1-flash-lite',
      lineNumber: 1,
      sentenceIndex: 1,
      dominantTone: 'angry',
      trend: 'escalating',
      intensity: 88,
    });
    expect(analyzed[1]).toMatchObject({
      sentenceIndex: 2,
      dominantTone: 'apologetic',
      trend: 'de_escalating',
      signals: ['apologetic', 'repair_attempt'],
    });
  });

  it('splits final transcript text into sentence-sized chunks', () => {
    expect(splitIntoSentences('Fine. I can do Tuesday? Thanks')).toEqual([
      'Fine.',
      'I can do Tuesday?',
      'Thanks',
    ]);
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
    roomToneGeminiModel: 'gemini-3.1-flash-lite',
    compromiseInitialDelayMs: 30_000,
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
