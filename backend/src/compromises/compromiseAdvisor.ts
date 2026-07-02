import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type {
  CompromisePushLevel,
  CompromiseQuality,
  CompromiseSuggestedEvent,
  CompromiseSuggestion,
  ServerEvent,
  TranscriptFinalEvent,
} from '../protocol/messages.js';

export interface TranscriptLine {
  speaker: string;
  speakerLabel?: string;
  text: string;
}

export interface CompromiseGenerator {
  generate(lines: readonly TranscriptLine[]): Promise<GeneratedCompromise[]>;
}

export interface GeneratedCompromise {
  title: string;
  summary: string;
  whyItCouldWork: string;
  score: number;
  quality?: CompromiseQuality;
  pushLevel?: CompromisePushLevel;
}

interface CompromiseAdvisorOptions {
  sessionId: string;
  streamId: string;
  config: AppConfig;
  emit: (event: ServerEvent) => void;
  generator?: CompromiseGenerator;
}

const MAX_TRANSCRIPT_LINES = 120;
const MIN_TRANSCRIPT_WORDS = 24;
const MAX_SUGGESTIONS = 3;

const generatedCompromiseSchema = z.object({
  title: z.string().min(1).max(80),
  summary: z.string().min(1).max(260),
  whyItCouldWork: z.string().min(1).max(260),
  score: z.number().min(0).max(100),
  quality: z
    .enum(['weak', 'promising', 'strong', 'really_good'])
    .optional(),
  pushLevel: z.enum(['normal', 'firm', 'urgent']).optional(),
});

const generatedResponseSchema = z.object({
  suggestions: z.array(generatedCompromiseSchema).max(MAX_SUGGESTIONS),
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

const compromiseJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    suggestions: {
      type: 'array',
      minItems: 0,
      maxItems: MAX_SUGGESTIONS,
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          title: {
            type: 'string',
            description: 'A short, specific name for the compromise.',
          },
          summary: {
            type: 'string',
            description:
              'The compromise phrased as an action both people could take now.',
          },
          whyItCouldWork: {
            type: 'string',
            description:
              'Why this may satisfy the interests heard in the transcript.',
          },
          score: {
            type: 'integer',
            minimum: 0,
            maximum: 100,
            description:
              'Estimated usefulness and fairness. Reserve 90+ for unusually strong compromises.',
          },
          quality: {
            type: 'string',
            enum: ['weak', 'promising', 'strong', 'really_good'],
          },
          pushLevel: {
            type: 'string',
            enum: ['normal', 'firm', 'urgent'],
            description:
              'Use urgent only when the compromise is very likely to help both sides immediately.',
          },
        },
        required: [
          'title',
          'summary',
          'whyItCouldWork',
          'score',
          'quality',
          'pushLevel',
        ],
      },
    },
  },
  required: ['suggestions'],
} as const;

export class CompromiseAdvisor {
  private readonly lines: TranscriptLine[] = [];
  private readonly generator?: CompromiseGenerator;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private closed = false;
  private lastAnalyzedLineCount = 0;
  private disabledEmitted = false;

  constructor(private readonly options: CompromiseAdvisorOptions) {
    this.generator =
      options.generator ??
      (options.config.geminiApiKey
        ? new GeminiCompromiseGenerator({
            apiKey: options.config.geminiApiKey,
            model: options.config.geminiModel,
          })
        : undefined);
  }

  start(): void {
    if (!this.generator) {
      this.emitDisabled();
      return;
    }

    this.schedule(this.options.config.compromiseInitialDelayMs);
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
    if (this.closed || !this.generator) return;

    this.timer = setTimeout(() => {
      this.timer = null;
      void this.analyze().finally(() => {
        this.schedule(this.options.config.compromiseIntervalMs);
      });
    }, delayMs);
  }

  private async analyze(): Promise<void> {
    if (!this.generator) {
      this.emitDisabled();
      return;
    }

    if (this.running || this.closed) return;
    if (this.lines.length === this.lastAnalyzedLineCount) return;
    if (countWords(this.lines) < MIN_TRANSCRIPT_WORDS) return;

    this.running = true;
    try {
      const generated = await this.generator.generate(this.lines);
      const suggestions = normalizeSuggestions(generated);
      this.lastAnalyzedLineCount = this.lines.length;

      if (suggestions.length === 0 || this.closed) return;

      const event: CompromiseSuggestedEvent = {
        type: 'compromise.suggested',
        provider: 'gemini',
        sessionId: this.options.sessionId,
        streamId: this.options.streamId,
        model: this.options.config.geminiModel,
        generatedAt: new Date().toISOString(),
        transcriptLineCount: this.lines.length,
        suggestions,
      };
      this.options.emit(event);
    } catch (error) {
      this.options.emit({
        type: 'compromise.error',
        provider: 'gemini',
        message:
          error instanceof Error
            ? error.message
            : 'Unknown compromise analysis error',
      });
    } finally {
      this.running = false;
    }
  }

  private emitDisabled(): void {
    if (this.disabledEmitted) return;
    this.disabledEmitted = true;
    this.options.emit({
      type: 'compromise.disabled',
      provider: 'gemini',
      reason: 'missing_gemini_api_key',
    });
  }
}

class GeminiCompromiseGenerator implements CompromiseGenerator {
  constructor(
    private readonly options: {
      apiKey: string;
      model: string;
      timeoutMs?: number;
    },
  ) {}

  async generate(lines: readonly TranscriptLine[]): Promise<GeneratedCompromise[]> {
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
          'You are a calm conflict mediator. Suggest only fair, specific compromises grounded in the transcript. Do not diagnose, moralize, or take sides.',
        store: false,
        response_format: {
          type: 'text',
          mime_type: 'application/json',
          schema: compromiseJsonSchema,
        },
        generation_config: {
          temperature: 0.35,
          max_output_tokens: 1200,
          thinking_level: 'low',
        },
      }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 15_000),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini compromise request failed with ${response.status}: ${truncate(
          await response.text(),
          240,
        )}`,
      );
    }

    const rawPayload = await response.json();
    const direct = generatedResponseSchema.safeParse(rawPayload);
    if (direct.success) {
      return direct.data.suggestions;
    }

    const payload = interactionResponseSchema.parse(rawPayload);
    const outputText = extractInteractionText(payload);
    if (!outputText) {
      throw new Error('Gemini returned no compromise text.');
    }

    const parsed = generatedResponseSchema.parse(JSON.parse(outputText));
    return parsed.suggestions;
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
    'Read this live argument transcript and propose up to three practical compromises.',
    'Rank them by likely effectiveness, fairness to both speakers, and how easy they are to try immediately.',
    'Only mark quality as really_good and pushLevel as urgent when the transcript clearly reveals a mutually acceptable trade.',
    'If there is not enough substance yet, return an empty suggestions array.',
    '',
    'Transcript:',
    transcript,
  ].join('\n');
}

function normalizeSuggestions(
  generated: readonly GeneratedCompromise[],
): CompromiseSuggestion[] {
  return [...generated]
    .map((suggestion) => {
      const score = Math.round(Math.max(0, Math.min(100, suggestion.score)));
      return {
        ...suggestion,
        score,
        quality: suggestion.quality ?? qualityForScore(score),
        pushLevel: suggestion.pushLevel ?? pushLevelForScore(score),
      };
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, MAX_SUGGESTIONS)
    .map((suggestion, index) => ({
      id: `compromise-${index + 1}-${slugify(suggestion.title)}`,
      rank: index + 1,
      title: suggestion.title.trim(),
      summary: suggestion.summary.trim(),
      whyItCouldWork: suggestion.whyItCouldWork.trim(),
      score: suggestion.score,
      quality: suggestion.quality,
      pushLevel: suggestion.pushLevel,
    }));
}

function qualityForScore(score: number): CompromiseQuality {
  if (score >= 90) return 'really_good';
  if (score >= 78) return 'strong';
  if (score >= 55) return 'promising';
  return 'weak';
}

function pushLevelForScore(score: number): CompromisePushLevel {
  if (score >= 90) return 'urgent';
  if (score >= 78) return 'firm';
  return 'normal';
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

function slugify(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 32);

  return slug || 'idea';
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
