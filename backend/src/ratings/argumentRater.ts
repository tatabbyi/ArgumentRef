import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type {
  ArgumentRatingDimensions,
  ArgumentRatingUpdatedEvent,
  ServerEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

export interface TranscriptLine {
  speaker: string;
  speakerLabel?: string;
  text: string;
}

export interface ArgumentRatingGenerator {
  rate(lines: readonly TranscriptLine[]): Promise<GeneratedArgumentRating>;
}

export interface GeneratedArgumentRating {
  overallScore: number;
  dimensions: ArgumentRatingDimensions;
  strengths: string[];
  risks: string[];
  refereeFocus: string;
}

interface ArgumentRaterOptions {
  sessionId: string;
  streamId: string;
  config: AppConfig;
  emit: (event: ServerEvent) => void;
  generator?: ArgumentRatingGenerator;
}

const MAX_TRANSCRIPT_LINES = 120;
const ANALYSIS_WINDOW_LINES = 40;
const MIN_TRANSCRIPT_WORDS = 40;
const MAX_NOTES = 4;

const scoreSchema = z.number().min(0).max(100);

const dimensionsSchema = z.object({
  clarity: scoreSchema,
  evidenceQuality: scoreSchema,
  logicalConsistency: scoreSchema,
  listening: scoreSchema,
  emotionalControl: scoreSchema,
  fairness: scoreSchema,
});

const generatedRatingSchema = z.object({
  overallScore: scoreSchema,
  dimensions: dimensionsSchema,
  strengths: z.array(z.string().min(1).max(180)).max(MAX_NOTES),
  risks: z.array(z.string().min(1).max(180)).max(MAX_NOTES),
  refereeFocus: z.string().min(1).max(220),
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

const argumentRatingJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    overallScore: {
      type: 'integer',
      minimum: 0,
      maximum: 100,
      description:
        'Overall quality of the argument process so far. Rate the conversation, not either person.',
    },
    dimensions: {
      type: 'object',
      additionalProperties: false,
      properties: {
        clarity: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description: 'How clearly the speakers express their points.',
        },
        evidenceQuality: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description:
            'How well claims are supported by examples, facts, or concrete reasons.',
        },
        logicalConsistency: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description: 'How internally consistent and relevant the reasoning is.',
        },
        listening: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description:
            'How much speakers respond to each other instead of talking past each other.',
        },
        emotionalControl: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description:
            'How regulated the exchange is without penalizing normal emotion.',
        },
        fairness: {
          type: 'integer',
          minimum: 0,
          maximum: 100,
          description:
            'How fair, balanced, and good-faith the exchange appears from the transcript.',
        },
      },
      required: [
        'clarity',
        'evidenceQuality',
        'logicalConsistency',
        'listening',
        'emotionalControl',
        'fairness',
      ],
    },
    strengths: {
      type: 'array',
      minItems: 0,
      maxItems: MAX_NOTES,
      items: {
        type: 'string',
        description: 'A short grounded strength observed in the transcript.',
      },
    },
    risks: {
      type: 'array',
      minItems: 0,
      maxItems: MAX_NOTES,
      items: {
        type: 'string',
        description: 'A short grounded risk that may reduce argument quality.',
      },
    },
    refereeFocus: {
      type: 'string',
      description:
        'One practical thing the referee should focus on next to improve the exchange.',
    },
  },
  required: [
    'overallScore',
    'dimensions',
    'strengths',
    'risks',
    'refereeFocus',
  ],
} as const;

export class ArgumentRater {
  private readonly lines: TranscriptLine[] = [];
  private readonly generator?: ArgumentRatingGenerator;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private closed = false;
  private lastAnalyzedLineCount = 0;
  private disabledEmitted = false;

  constructor(private readonly options: ArgumentRaterOptions) {
    this.generator =
      options.generator ??
      (options.config.geminiApiKey
        ? new GeminiArgumentRatingGenerator({
            apiKey: options.config.geminiApiKey,
            model: options.config.geminiModel,
          })
        : undefined);
  }

  start(): void {
    if (!this.options.config.argumentRatingEnabled) {
      this.emitDisabled('disabled');
      return;
    }

    if (!this.generator) {
      this.emitDisabled('missing_gemini_api_key');
      return;
    }

    this.schedule(this.options.config.argumentRatingIntervalMs);
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
      !this.generator ||
      !this.options.config.argumentRatingEnabled
    ) {
      return;
    }

    this.timer = setTimeout(() => {
      this.timer = null;
      void this.analyze().finally(() => {
        this.schedule(this.options.config.argumentRatingIntervalMs);
      });
    }, delayMs);
  }

  private async analyze(): Promise<void> {
    if (!this.options.config.argumentRatingEnabled) {
      this.emitDisabled('disabled');
      return;
    }

    if (!this.generator) {
      this.emitDisabled('missing_gemini_api_key');
      return;
    }

    if (this.running || this.closed) return;
    if (this.lines.length === this.lastAnalyzedLineCount) return;
    if (this.lines.length < this.options.config.argumentRatingMinTranscriptLines) {
      return;
    }

    const window = this.lines.slice(-ANALYSIS_WINDOW_LINES);
    if (countWords(window) < MIN_TRANSCRIPT_WORDS) return;

    this.running = true;
    try {
      const generated = normalizeRating(await this.generator.rate(window));
      this.lastAnalyzedLineCount = this.lines.length;

      if (this.closed) return;

      const event: ArgumentRatingUpdatedEvent = {
        type: 'argument.rating.updated',
        provider: 'gemini',
        sessionId: this.options.sessionId,
        streamId: this.options.streamId,
        model: this.options.config.geminiModel,
        generatedAt: new Date().toISOString(),
        transcriptLineCount: this.lines.length,
        ...generated,
      };

      this.options.emit(event);
    } catch (error) {
      this.options.emit({
        type: 'argument.rating.error',
        provider: 'gemini',
        message:
          error instanceof Error
            ? error.message
            : 'Unknown argument rating error',
      });
    } finally {
      this.running = false;
    }
  }

  private emitDisabled(reason: 'disabled' | 'missing_gemini_api_key'): void {
    if (this.disabledEmitted) return;
    this.disabledEmitted = true;
    this.options.emit({
      type: 'argument.rating.disabled',
      provider: 'gemini',
      reason,
    });
  }
}

class GeminiArgumentRatingGenerator implements ArgumentRatingGenerator {
  constructor(
    private readonly options: {
      apiKey: string;
      model: string;
      timeoutMs?: number;
    },
  ) {}

  async rate(lines: readonly TranscriptLine[]): Promise<GeneratedArgumentRating> {
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
          'You are a neutral live argument referee. Rate the argument process from observable transcript evidence only. Do not diagnose, moralize, or decide who is right.',
        store: false,
        response_format: {
          type: 'text',
          mime_type: 'application/json',
          schema: argumentRatingJsonSchema,
        },
        generation_config: {
          temperature: 0.25,
          max_output_tokens: 1200,
          thinking_level: 'low',
        },
      }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 15_000),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini argument rating request failed with ${response.status}: ${truncate(
          await response.text(),
          240,
        )}`,
      );
    }

    const rawPayload = await response.json();
    const direct = generatedRatingSchema.safeParse(rawPayload);
    if (direct.success) {
      return direct.data;
    }

    const payload = interactionResponseSchema.parse(rawPayload);
    const outputText = extractInteractionText(payload);
    if (!outputText) {
      throw new Error('Gemini returned no argument rating text.');
    }

    return generatedRatingSchema.parse(JSON.parse(outputText));
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
    'Rate this live argument transcript as a process, not as a verdict on who is correct.',
    'Use the full 0 to 100 range, but avoid extreme scores unless the transcript clearly supports them.',
    'Reward clear claims, concrete support, direct engagement with the other speaker, consistency, emotional regulation, and fairness.',
    'Do not penalize normal emotion by itself. Do not infer private motives, mental health, or character.',
    'Make strengths, risks, and refereeFocus specific enough for a live referee UI.',
    '',
    'Transcript:',
    transcript,
  ].join('\n');
}

function normalizeRating(generated: GeneratedArgumentRating): GeneratedArgumentRating {
  return {
    overallScore: clampScore(generated.overallScore),
    dimensions: {
      clarity: clampScore(generated.dimensions.clarity),
      evidenceQuality: clampScore(generated.dimensions.evidenceQuality),
      logicalConsistency: clampScore(generated.dimensions.logicalConsistency),
      listening: clampScore(generated.dimensions.listening),
      emotionalControl: clampScore(generated.dimensions.emotionalControl),
      fairness: clampScore(generated.dimensions.fairness),
    },
    strengths: generated.strengths.map((item) => item.trim()).filter(Boolean).slice(0, MAX_NOTES),
    risks: generated.risks.map((item) => item.trim()).filter(Boolean).slice(0, MAX_NOTES),
    refereeFocus: generated.refereeFocus.trim(),
  };
}

function clampScore(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.round(Math.max(0, Math.min(100, value)));
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

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
