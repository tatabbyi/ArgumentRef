import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../src/config.js';
import {
  ConversationDebriefer,
  type ConversationDebriefGenerator,
  type GeneratedConversationDebrief,
} from '../src/debriefs/conversationDebriefer.js';
import type { TranscriptFinalEvent } from '../src/protocol/messages.js';
import type { AudioStreamSnapshot } from '../src/sessions/sessionStore.js';

let storageDir: string;

describe('conversation debriefer', () => {
  beforeEach(async () => {
    storageDir = await mkdtemp(path.join(os.tmpdir(), 'argumentref-debrief-'));
  });

  afterEach(async () => {
    await rm(storageDir, { recursive: true, force: true });
  });

  it('stores a Gemini debrief and updates local argument profiles', async () => {
    const debriefPath = path.join(storageDir, 'session-1', 'phone-1-debrief.json');
    const profilePath = path.join(storageDir, 'argument-profiles.json');
    const generator: ConversationDebriefGenerator = {
      generate: async (lines) => {
        expect(lines).toHaveLength(2);
        expect(lines[0]).toMatchObject({
          lineNumber: 1,
          speaker: 'speaker_0',
          speakerLabel: 'Alice',
        });
        return generatedDebrief;
      },
    };
    const debriefer = new ConversationDebriefer({
      sessionId: 'session-1',
      streamId: 'stream-1',
      participantId: 'phone-1',
      config: baseConfig({ geminiApiKey: 'test-key' }),
      debriefPath,
      profilePath,
      generator,
      now: () => new Date('2026-07-02T12:00:00.000Z'),
    });

    debriefer.recordTranscript(
      transcriptFinal('speaker_0', 'Alice', 'I need the chores to stop falling on me every week.'),
    );
    debriefer.recordTranscript(
      transcriptFinal('speaker_1', 'Ben', 'I can help, but my shifts change and I need flexibility.'),
    );

    const result = await debriefer.finish(snapshot(debriefPath, profilePath));

    expect(result).toEqual({
      status: 'completed',
      debriefPath,
      profilePath,
    });

    const stored = JSON.parse(await readFile(debriefPath, 'utf8')) as {
      analysisStatus: string;
      transcriptLineCount: number;
      participants: string[];
      debrief: GeneratedConversationDebrief;
    };
    expect(stored.analysisStatus).toBe('completed');
    expect(stored.transcriptLineCount).toBe(2);
    expect(stored.participants).toEqual(['Alice', 'Ben']);
    expect(stored.debrief.overview.title).toBe('Chores and flexible schedules');

    const profiles = JSON.parse(await readFile(profilePath, 'utf8')) as {
      pairs: Record<string, { conversationCount: number; recurringTopics: { label: string; count: number }[] }>;
      individuals: Record<string, { conversationCount: number; argumentTraits: { label: string; count: number }[] }>;
    };
    expect(profiles.pairs.alice__ben.conversationCount).toBe(1);
    expect(profiles.pairs.alice__ben.recurringTopics[0]).toMatchObject({
      label: 'chores',
      count: 1,
    });
    expect(profiles.individuals.alice.argumentTraits[0]).toMatchObject({
      label: 'states the burden directly',
      count: 1,
    });
  });

  it('stores the raw transcript even when Gemini is not configured', async () => {
    const debriefPath = path.join(storageDir, 'session-2', 'phone-1-debrief.json');
    const profilePath = path.join(storageDir, 'argument-profiles.json');
    const debriefer = new ConversationDebriefer({
      sessionId: 'session-2',
      streamId: 'stream-2',
      participantId: 'phone-1',
      config: baseConfig(),
      debriefPath,
      profilePath,
    });

    debriefer.recordTranscript(
      transcriptFinal('speaker_0', 'Alice', 'We keep arguing about the same thing.'),
    );

    const result = await debriefer.finish(snapshot(debriefPath, profilePath));

    expect(result).toEqual({
      status: 'disabled',
      debriefPath,
    });

    const stored = JSON.parse(await readFile(debriefPath, 'utf8')) as {
      analysisStatus: string;
      analysisError: { code: string };
      transcript: unknown[];
    };
    expect(stored.analysisStatus).toBe('disabled');
    expect(stored.analysisError.code).toBe('missing_gemini_api_key');
    expect(stored.transcript).toHaveLength(1);
    await expect(readFile(profilePath, 'utf8')).rejects.toThrow();
  });
});

const generatedDebrief = {
  overview: {
    title: 'Chores and flexible schedules',
    whatTheyArguedAbout:
      'Alice wants chores to feel predictable, while Ben wants flexibility around changing shifts.',
    topics: [
      {
        label: 'chores',
        description: 'The main dispute is how household work is shared.',
        evidenceLineNumbers: [1, 2],
        confidence: 'high',
      },
    ],
  },
  solution: {
    status: 'partly_resolved',
    summary: 'They have the outline of a flexible chore plan but no final agreement.',
    agreedActions: ['Try a weekly chore check-in.'],
    openQuestions: ['Which chores can move when shifts change?'],
    nextSteps: ['Pick fixed chores and flexible chores separately.'],
  },
  participantBreakdown: [
    {
      speaker: 'speaker_0',
      displayName: 'Alice',
      positionSummary: 'Alice wants a predictable split of chores.',
      needs: ['Predictability', 'Less mental load'],
      argumentTraits: [
        {
          label: 'states the burden directly',
          description: 'Alice names the repeated burden clearly.',
          evidenceLineNumbers: [1],
          confidence: 'high',
        },
      ],
      notableCharacteristics: [],
    },
    {
      speaker: 'speaker_1',
      displayName: 'Ben',
      positionSummary: 'Ben wants to help without overpromising around shift changes.',
      needs: ['Flexibility', 'Realistic commitments'],
      argumentTraits: [
        {
          label: 'qualifies commitments',
          description: 'Ben offers help but frames it around schedule limits.',
          evidenceLineNumbers: [2],
          confidence: 'high',
        },
      ],
      notableCharacteristics: [],
    },
  ],
  interactionDynamics: [
    {
      label: 'competing needs',
      description: 'The conversation pits predictability against flexibility.',
      evidenceLineNumbers: [1, 2],
      confidence: 'high',
    },
  ],
  profileSignals: {
    pair: {
      recurringTopics: [
        {
          label: 'chores',
          description: 'Chore division is a useful future topic to track.',
          evidenceLineNumbers: [1, 2],
          confidence: 'high',
        },
      ],
      recurringDynamics: [
        {
          label: 'predictability versus flexibility',
          description: 'Their positions differ around fixed plans versus movable plans.',
          evidenceLineNumbers: [1, 2],
          confidence: 'high',
        },
      ],
    },
    individuals: [
      {
        speaker: 'speaker_0',
        displayName: 'Alice',
        argumentTraits: [
          {
            label: 'states the burden directly',
            description: 'Alice clearly names what feels unfair.',
            evidenceLineNumbers: [1],
            confidence: 'high',
          },
        ],
        triggerTopics: [
          {
            label: 'mental load',
            description: 'Alice reacts to carrying too much planning work.',
            evidenceLineNumbers: [1],
            confidence: 'medium',
          },
        ],
        repairStrategies: ['Name one concrete request.'],
      },
      {
        speaker: 'speaker_1',
        displayName: 'Ben',
        argumentTraits: [
          {
            label: 'qualifies commitments',
            description: 'Ben avoids fixed promises when schedules may change.',
            evidenceLineNumbers: [2],
            confidence: 'high',
          },
        ],
        triggerTopics: [
          {
            label: 'rigid plans',
            description: 'Ben pushes back when a plan may not fit changing shifts.',
            evidenceLineNumbers: [2],
            confidence: 'medium',
          },
        ],
        repairStrategies: ['Offer a backup day when schedules change.'],
      },
    ],
  },
  cautionNotes: [],
} satisfies GeneratedConversationDebrief;

function baseConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    host: '127.0.0.1',
    port: 0,
    audioStorageDir: storageDir,
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

function transcriptFinal(
  speaker: string,
  speakerLabel: string,
  text: string,
): TranscriptFinalEvent {
  return {
    type: 'transcript.final',
    provider: 'deepgram',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker,
    speakerLabel,
    text,
    words: [],
  };
}

function snapshot(debriefPath: string, profilePath: string): AudioStreamSnapshot {
  return {
    sessionId: 'session-1',
    streamId: 'stream-1',
    participantId: 'phone-1',
    bytesReceived: 128,
    chunksReceived: 2,
    filePath: path.join(storageDir, 'session-1', 'phone-1.audio'),
    debriefPath,
    profilePath,
  };
}
