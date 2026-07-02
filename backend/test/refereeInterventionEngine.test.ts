import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../src/config.js';
import { RefereeInterventionEngine } from '../src/interventions/refereeInterventionEngine.js';
import type {
  ArgumentRatingUpdatedEvent,
  ClaimDetectedEvent,
  CompromiseSuggestedEvent,
  FactCheckCompletedEvent,
  FallacyDetectedEvent,
} from '../src/protocol/messages.js';

describe('referee intervention engine', () => {
  it('does not emit interventions when disabled', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig({ refereeInterventionsEnabled: false }),
    });

    expect(engine.observe(fallacyDetected())).toBeUndefined();
  });

  it('applies gentle intervention wording', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      settings: { interventionStyle: 'gentle' },
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(fallacyDetected());

    expect(intervention?.message).toBe(
      'Gently, ask them to restate the actual request before responding to it.',
    );
  });

  it('suppresses medium fallacy prompts when sensitivity is low', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      settings: { fallacySensitivity: 'low' },
    });

    expect(
      engine.observe(
        fallacyDetected({
          confidence: 'medium',
          severity: 'moderate',
        }),
      ),
    ).toBeUndefined();
  });

  it('suppresses claim prompts when fact-check strictness is low', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      settings: { factCheckStrictness: 'low' },
    });

    expect(engine.observe(claimDetected())).toBeUndefined();
  });

  it('turns fallacy detections into logic interventions', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(fallacyDetected());

    expect(intervention).toMatchObject({
      type: 'referee.intervention.suggested',
      sessionId: 'session-1',
      streamId: 'stream-1',
      category: 'logic',
      priority: 'high',
      message:
        'Ask them to restate the actual request before responding to it.',
      reason:
        'Person A may be using straw man: This exaggerates the other person’s request.',
      sourceEvent: 'fallacy.detected',
      speaker: 'speaker_0',
      speakerLabel: 'Person A',
    });
  });

  it('turns matched fact-checks into factual interventions', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(
      factCheckCompleted({
        status: 'matched_fact_check',
        summary: 'A matching fact-check rates this claim false.',
        sources: [
          {
            title: 'Fact-check',
            url: 'https://example.com/fact-check',
            rating: 'False',
          },
        ],
      }),
    );

    expect(intervention).toMatchObject({
      type: 'referee.intervention.suggested',
      category: 'factual',
      priority: 'high',
      message:
        'Pause on this factual point and compare it with the matched fact-check.',
      reason: 'A matching fact-check rates this claim false.',
      sourceEvent: 'fact_check.completed',
      sourceId: 'claim-1:matched_fact_check',
    });
  });

  it('turns strong compromise suggestions into compromise interventions', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(compromiseSuggested());

    expect(intervention).toMatchObject({
      type: 'referee.intervention.suggested',
      category: 'compromise',
      priority: 'high',
      message:
        'Try this compromise: Try the new chore split for two weeks, then review it.',
      reason: 'It gives both people a low-risk test with a clear review point.',
      sourceEvent: 'compromise.suggested',
      sourceId: 'compromise-1-two-week-trial',
    });
  });

  it('uses compromise preference wording', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      settings: { compromisePreference: 'fair' },
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(compromiseSuggested());

    expect(intervention?.message).toBe(
      'Try the fairest compromise: Try the new chore split for two weeks, then review it.',
    );
  });

  it('only emits rating interventions when scores need attention', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      now: () => Date.UTC(2026, 0, 1),
    });

    expect(engine.observe(argumentRatingUpdated({ overallScore: 82 }))).toBeUndefined();

    const intervention = engine.observe(
      argumentRatingUpdated({
        overallScore: 61,
        dimensions: {
          clarity: 72,
          evidenceQuality: 50,
          logicalConsistency: 66,
          listening: 58,
          emotionalControl: 70,
          fairness: 64,
        },
      }),
    );

    expect(intervention).toMatchObject({
      type: 'referee.intervention.suggested',
      category: 'argument_quality',
      priority: 'medium',
      message: 'Ask each person for one specific example.',
      reason: 'Claims are broad and need concrete examples.',
      sourceEvent: 'argument.rating.updated',
    });
  });

  it('uses intervention frequency for rating sensitivity', () => {
    const engine = new RefereeInterventionEngine({
      config: baseConfig(),
      settings: { interventionFrequency: 'high' },
      now: () => Date.UTC(2026, 0, 1),
    });

    const intervention = engine.observe(argumentRatingUpdated({ overallScore: 72 }));

    expect(intervention).toMatchObject({
      type: 'referee.intervention.suggested',
      category: 'argument_quality',
    });
  });

  it('applies category cooldowns', () => {
    let now = 1_000;
    const engine = new RefereeInterventionEngine({
      config: baseConfig({ refereeInterventionCooldownMs: 1_000 }),
      now: () => now,
    });

    expect(engine.observe(claimDetected({ claimId: 'claim-1' }))).toBeDefined();

    now = 1_500;
    expect(engine.observe(claimDetected({ claimId: 'claim-2' }))).toBeUndefined();

    now = 2_100;
    expect(engine.observe(claimDetected({ claimId: 'claim-3' }))).toBeDefined();
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
    compromiseInitialDelayMs: 60_000,
    compromiseIntervalMs: 30_000,
    fallacyDetectionEnabled: false,
    fallacyAnalysisIntervalMs: 20_000,
    fallacyMinConfidence: 'medium',
    argumentRatingEnabled: false,
    argumentRatingIntervalMs: 30_000,
    argumentRatingMinTranscriptLines: 4,
    refereeInterventionsEnabled: true,
    refereeInterventionCooldownMs: 0,
    elevenLabsVoiceId: 'test-voice',
    elevenLabsModelId: 'eleven_multilingual_v2',
    elevenLabsOutputFormat: 'mp3_44100_128',
    elevenLabsMaxTextChars: 600,
    ...overrides,
  };
}

function claimDetected(
  overrides: Partial<ClaimDetectedEvent> = {},
): ClaimDetectedEvent {
  return {
    type: 'claim.detected',
    claimId: 'claim-1',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker: 'speaker_0',
    speakerLabel: 'Person A',
    text: 'The average rent has doubled this year.',
    reason: 'Contains a measurable factual claim.',
    status: 'queued',
    sourceEvent: 'transcript.final',
    ...overrides,
  };
}

function factCheckCompleted(
  overrides: Partial<FactCheckCompletedEvent> = {},
): FactCheckCompletedEvent {
  return {
    type: 'fact_check.completed',
    provider: 'google-fact-check',
    claimId: 'claim-1',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker: 'speaker_0',
    speakerLabel: 'Person A',
    claim: 'The average rent has doubled this year.',
    status: 'no_match',
    summary: 'No matching published fact check was found.',
    sources: [],
    ...overrides,
  };
}

function fallacyDetected(
  overrides: Partial<FallacyDetectedEvent> = {},
): FallacyDetectedEvent {
  return {
    type: 'fallacy.detected',
    provider: 'gemini',
    sessionId: 'session-1',
    streamId: 'stream-1',
    model: 'gemini-3.5-flash',
    detectedAt: new Date(Date.UTC(2026, 0, 1)).toISOString(),
    transcriptLineCount: 4,
    speaker: 'speaker_0',
    speakerLabel: 'Person A',
    fallacy: 'straw_man',
    confidence: 'high',
    severity: 'moderate',
    quote: 'So you are saying I should never rest.',
    explanation: 'This exaggerates the other person’s request.',
    suggestedRefereeResponse:
      'Ask them to restate the actual request before responding to it.',
    ...overrides,
  };
}

function compromiseSuggested(
  overrides: Partial<CompromiseSuggestedEvent> = {},
): CompromiseSuggestedEvent {
  return {
    type: 'compromise.suggested',
    provider: 'gemini',
    sessionId: 'session-1',
    streamId: 'stream-1',
    model: 'gemini-3.5-flash',
    generatedAt: new Date(Date.UTC(2026, 0, 1)).toISOString(),
    transcriptLineCount: 6,
    suggestions: [
      {
        id: 'compromise-1-two-week-trial',
        rank: 1,
        title: 'Two-week trial',
        summary: 'Try the new chore split for two weeks, then review it.',
        whyItCouldWork:
          'It gives both people a low-risk test with a clear review point.',
        score: 92,
        quality: 'really_good',
        pushLevel: 'urgent',
      },
    ],
    ...overrides,
  };
}

function argumentRatingUpdated(
  overrides: Partial<ArgumentRatingUpdatedEvent> = {},
): ArgumentRatingUpdatedEvent {
  return {
    type: 'argument.rating.updated',
    provider: 'gemini',
    sessionId: 'session-1',
    streamId: 'stream-1',
    model: 'gemini-3.5-flash',
    generatedAt: new Date(Date.UTC(2026, 0, 1)).toISOString(),
    transcriptLineCount: 6,
    overallScore: 72,
    dimensions: {
      clarity: 72,
      evidenceQuality: 68,
      logicalConsistency: 66,
      listening: 58,
      emotionalControl: 70,
      fairness: 64,
    },
    strengths: ['Both people are still engaging.'],
    risks: ['Claims are broad and need concrete examples.'],
    refereeFocus: 'Ask each person for one specific example.',
    ...overrides,
  };
}
