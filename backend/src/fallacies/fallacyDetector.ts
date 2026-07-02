import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type {
  FallacyConfidence,
  FallacyDetectedEvent,
  FallacyKind,
  FallacySeverity,
  ServerEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

interface TranscriptLine {
  speaker: string;
  speakerLabel?: string;
  text: string;
}

export interface FallacyAnalyzer {
  analyze(lines: readonly TranscriptLine[]): Promise<GeneratedFallacy[]>;
}

export interface GeneratedFallacy {
  speaker: string;
  fallacy: FallacyKind;
  confidence: FallacyConfidence;
  severity: FallacySeverity;
  quote: string;
  explanation: string;
  suggestedRefereeResponse: string;
}

interface FallacyDetectorOptions {
  sessionId: string;
  streamId: string;
  config: AppConfig;
  emit: (event: ServerEvent) => void;
  analyzer?: FallacyAnalyzer;
}

const MAX_TRANSCRIPT_LINES = 80;
const ANALYSIS_WINDOW_LINES = 12;
const MIN_TRANSCRIPT_WORDS = 18;
const MAX_FALLACIES = 3;

const fallacyKindSchema = z.enum([
  'ad_hominem',
  'straw_man',
  'false_dichotomy',
  'slippery_slope',
  'hasty_generalization',
  'circular_reasoning',
  'red_herring',
  'whataboutism',
  'burden_of_proof_shift',
  'appeal_to_authority',
  'correlation_causation',
]);

const confidenceSchema = z.enum(['low', 'medium', 'high']);
const severitySchema = z.enum(['minor', 'moderate', 'serious']);

const generatedFallacySchema = z.object({
  speaker: z.string().min(1),
  fallacy: fallacyKindSchema,
  confidence: confidenceSchema,
  severity: severitySchema,
  quote: z.string().min(1).max(260),
  explanation: z.string().min(1).max(420),
  suggestedRefereeResponse: z.string().min(1).max(260),
});

const generatedResponseSchema = z.object({
  fallacies: z.array(generatedFallacySchema).max(MAX_FALLACIES),
});

const interactionResponseSchema = z
  .object({
    output_text: z.string().optional(),
    steps: z
      .array(
        z.object({
          type: z.string().optional(),
          content: z
            .array(
              z.object({
                type: z.string().optional(),
                text: z.string().optional(),
              }),
            )
            .optional(),
        }),
      )
      .optional(),
  })
  .passthrough();

const fallacyJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    fallacies: {
      type: 'array',
      minItems: 0,
      maxItems: MAX_FALLACIES,
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          speaker: {
            type: 'string',
            description:
              'The exact speaker ID or label from the transcript line containing the quote.',
          },
          fallacy: {
            type: 'string',
            enum: fallacyKindSchema.options,
          },
          confidence: {
            type: 'string',
            enum: confidenceSchema.options,
          },
          severity: {
            type: 'string',
            enum: severitySchema.options,
          },
          quote: {
            type: 'string',
            description: 'Exact short quote from the transcript.',
          },
          explanation: {
            type: 'string',
            description:
              'Why this may be a fallacy. Use cautious language such as may or appears.',
          },
          suggestedRefereeResponse: {
            type: 'string',
            description: 'A calm one-sentence intervention the referee can say.',
          },
        },
        required: [
          'speaker',
          'fallacy',
          'confidence',
          'severity',
          'quote',
          'explanation',
          'suggestedRefereeResponse',
        ],
      },
    },
  },
  required: ['fallacies'],
} as const;

export class FallacyDetector {
  private readonly lines: TranscriptLine[] = [];
  private readonly analyzer?: FallacyAnalyzer;
  private readonly seenFallacies = new Set<string>();
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private closed = false;
  private lastAnalyzedLineCount = 0;
  private disabledEmitted = false;

  constructor(private readonly options: FallacyDetectorOptions) {
    this.analyzer =
      options.analyzer ??
      (options.config.geminiApiKey
        ? new GeminiFallacyAnalyzer({
            apiKey: options.config.geminiApiKey,
            model: options.config.geminiModel,
          })
        : undefined);
  }

  start(): void {
    if (!this.options.config.fallacyDetectionEnabled) {
      this.emitDisabled('disabled');
      return;
    }

    if (!this.analyzer) {
      this.emitDisabled('missing_gemini_api_key');
      return;
    }

    this.schedule(this.options.config.fallacyAnalysisIntervalMs);
  }

  recordTranscript(event: TranscriptFinalEvent): void {
    const text = event.text.trim();
    if (!text) return;

    this.lines.push({
      speaker: event.speaker,
      speakerLabel: event.speakerLabel,
      text,
    });

    if (this.lines.length > MAX_TRANSCRIPT_LINES) {
      this.lines.splice(0, this.lines.length - MAX_TRANSCRIPT_LINES);
    }
  }

  async analyzeNow(): Promise<void> {
    await this.analyze();
  }

  close(): void {
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(delayMs: number): void {
    if (
      this.closed ||
      !this.analyzer ||
      !this.options.config.fallacyDetectionEnabled
    ) {
      return;
    }

    this.timer = setTimeout(() => {
      this.timer = null;
      void this.analyze().finally(() => {
        this.schedule(this.options.config.fallacyAnalysisIntervalMs);
      });
    }, delayMs);
  }

  private async analyze(): Promise<void> {
    if (!this.options.config.fallacyDetectionEnabled) {
      this.emitDisabled('disabled');
      return;
    }

    if (!this.analyzer) {
      this.emitDisabled('missing_gemini_api_key');
      return;
    }

    if (this.running || this.closed) return;
    if (this.lines.length === this.lastAnalyzedLineCount) return;

    const window = this.lines.slice(-ANALYSIS_WINDOW_LINES);
    if (countWords(window) < MIN_TRANSCRIPT_WORDS) return;

    this.running = true;
    try {
      const generated = await this.analyzer.analyze(window);
      this.lastAnalyzedLineCount = this.lines.length;

      for (const fallacy of normalizeFallacies(
        generated,
        this.options.config.fallacyMinConfidence,
      )) {
        const speaker = matchSpeaker(window, fallacy.speaker);
        const dedupeKey = normalizeFallacyKey(
          speaker.speaker,
          fallacy.fallacy,
          fallacy.quote,
        );
        if (this.seenFallacies.has(dedupeKey)) continue;
        this.seenFallacies.add(dedupeKey);

        this.options.emit({
          type: 'fallacy.detected',
          provider: 'gemini',
          sessionId: this.options.sessionId,
          streamId: this.options.streamId,
          model: this.options.config.geminiModel,
          detectedAt: new Date().toISOString(),
          transcriptLineCount: this.lines.length,
          speaker: speaker.speaker,
          speakerLabel: speaker.speakerLabel,
          fallacy: fallacy.fallacy,
          confidence: fallacy.confidence,
          severity: fallacy.severity,
          quote: fallacy.quote,
          explanation: fallacy.explanation,
          suggestedRefereeResponse: fallacy.suggestedRefereeResponse,
        });
      }
    } catch (error) {
      this.options.emit({
        type: 'fallacy.error',
        provider: 'gemini',
        message:
          error instanceof Error
            ? error.message
            : 'Unknown fallacy analysis error',
      });
    } finally {
      this.running = false;
    }
  }

  private emitDisabled(reason: 'disabled' | 'missing_gemini_api_key'): void {
    if (this.disabledEmitted) return;
    this.disabledEmitted = true;
    this.options.emit({
      type: 'fallacy.disabled',
      provider: 'gemini',
      reason,
    });
  }
}

class GeminiFallacyAnalyzer implements FallacyAnalyzer {
  constructor(
    private readonly options: {
      apiKey: string;
      model: string;
      timeoutMs?: number;
    },
  ) {}

  async analyze(lines: readonly TranscriptLine[]): Promise<GeneratedFallacy[]> {
    const response = await fetch('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': this.options.apiKey,
      },
      body: JSON.stringify({
        model: this.options.model,
        input: buildPrompt(lines),
        system_instruction:
          'You are a cautious logic coach for a live argument referee. Detect only clear possible logical fallacies. Use neutral, non-accusatory language. Do not take sides.',
        store: false,
        response_format: {
          type: 'text',
          mime_type: 'application/json',
          schema: fallacyJsonSchema,
        },
        generation_config: {
          temperature: 0.2,
          max_output_tokens: 1400,
          thinking_level: 'low',
        },
      }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 15_000),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini fallacy request failed with ${response.status}: ${truncate(
          await response.text(),
          240,
        )}`,
      );
    }

    const rawPayload = await response.json();
    const direct = generatedResponseSchema.safeParse(rawPayload);
    if (direct.success) {
      return direct.data.fallacies;
    }

    const payload = interactionResponseSchema.parse(rawPayload);
    const outputText = extractInteractionText(payload);
    if (!outputText) {
      throw new Error('Gemini returned no fallacy text.');
    }

    const parsed = generatedResponseSchema.parse(JSON.parse(outputText));
    return parsed.fallacies;
  }
}

function buildPrompt(lines: readonly TranscriptLine[]): string {
  const transcript = lines
    .map((line, index) => {
      const speaker = line.speakerLabel ?? line.speaker;
      return `${index + 1}. ${speaker}: ${line.text}`;
    })
    .join('\n');

  return [
    'Read this recent live argument transcript and identify possible logical fallacies.',
    'Only include a fallacy when the exact quote clearly supports it.',
    'Prefer an empty fallacies array when unsure.',
    'Do not flag tone, emotion, disagreement, or being wrong as a fallacy by itself.',
    'Use confidence low only when weak, medium when plausible, high when clear.',
    'Return at most three fallacies.',
    '',
    'Allowed fallacies:',
    fallacyKindSchema.options.join(', '),
    '',
    'Transcript:',
    transcript,
  ].join('\n');
}

function normalizeFallacies(
  generated: readonly GeneratedFallacy[],
  minConfidence: FallacyConfidence,
): GeneratedFallacy[] {
  return generated
    .filter((fallacy) => confidenceRank(fallacy.confidence) >= confidenceRank(minConfidence))
    .slice(0, MAX_FALLACIES)
    .map((fallacy) => ({
      ...fallacy,
      quote: fallacy.quote.trim(),
      explanation: fallacy.explanation.trim(),
      suggestedRefereeResponse: fallacy.suggestedRefereeResponse.trim(),
    }));
}

function matchSpeaker(
  lines: readonly TranscriptLine[],
  generatedSpeaker: string,
): { speaker: string; speakerLabel?: string } {
  const normalized = generatedSpeaker.toLowerCase().trim();
  const match =
    lines.find((line) => line.speaker.toLowerCase() === normalized) ??
    lines.find((line) => line.speakerLabel?.toLowerCase() === normalized) ??
    lines.at(-1);

  return {
    speaker: match?.speaker ?? generatedSpeaker,
    speakerLabel: match?.speakerLabel,
  };
}

function confidenceRank(confidence: FallacyConfidence): number {
  switch (confidence) {
    case 'low':
      return 1;
    case 'medium':
      return 2;
    case 'high':
      return 3;
    default:
      assertNever(confidence);
  }
}

function extractInteractionText(
  payload: z.infer<typeof interactionResponseSchema>,
): string {
  if (payload.output_text) return payload.output_text;

  return (
    payload.steps
      ?.flatMap((step) => step.content ?? [])
      .filter((content) => content.type === 'text' && content.text)
      .map((content) => content.text)
      .join('\n') ?? ''
  );
}

function countWords(lines: readonly TranscriptLine[]): number {
  return lines.reduce(
    (total, line) =>
      total + line.text.split(/\s+/).filter((word) => word.length > 0).length,
    0,
  );
}

function normalizeFallacyKey(
  speaker: string,
  fallacy: FallacyKind,
  quote: string,
): string {
  return `${speaker}:${fallacy}:${quote.toLowerCase().replace(/\W+/g, ' ').trim()}`;
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}

function assertNever(value: never): never {
  throw new Error(`Unhandled fallacy confidence: ${JSON.stringify(value)}`);
}
