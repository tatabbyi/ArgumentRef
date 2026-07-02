import { z } from 'zod';
import type { AppConfig } from '../config.js';
import {
  roomToneSignals,
  type RoomToneAnalyzedEvent,
  type RoomTonePhrase,
  type RoomToneSignal,
  type RoomToneTrend,
  type ServerEvent,
  type TranscriptFinalEvent,
} from '../protocol/messages.js';

export interface RoomToneSentence {
  lineNumber: number;
  sentenceIndex: number;
  speaker: string;
  speakerLabel?: string;
  text: string;
}

export interface RoomToneGeneratorInput {
  sentence: RoomToneSentence;
  context: readonly RoomToneSentence[];
}

export interface GeneratedRoomToneAnalysis {
  dominantTone: RoomToneSignal;
  trend: RoomToneTrend;
  intensity: number;
  confidence: number;
  summary: string;
  signals?: RoomToneSignal[];
  phrases?: RoomTonePhrase[];
}

export interface RoomToneGenerator {
  analyze(input: RoomToneGeneratorInput): Promise<GeneratedRoomToneAnalysis>;
}

interface RoomToneAnalyzerOptions {
  sessionId: string;
  streamId: string;
  config: AppConfig;
  emit: (event: ServerEvent) => void;
  generator?: RoomToneGenerator;
}

interface QueuedSentence {
  sentence: RoomToneSentence;
  context: RoomToneSentence[];
}

const CONTEXT_SENTENCES = 4;
const MAX_HISTORY_SENTENCES = 80;
const MAX_PENDING_SENTENCES = 24;

const generatedRoomToneSchema = z.object({
  dominantTone: z.enum(roomToneSignals),
  trend: z.enum(['escalating', 'de_escalating', 'neutral']),
  intensity: z.number(),
  confidence: z.number(),
  summary: z.string().default(''),
  signals: z.array(z.enum(roomToneSignals)).optional(),
  phrases: z
    .array(
      z.object({
        text: z.string(),
        signal: z.enum(roomToneSignals),
      }),
    )
    .optional(),
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

const roomToneJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dominantTone: {
      type: 'string',
      enum: roomToneSignals,
      description: 'The strongest observable tone in the target sentence.',
    },
    trend: {
      type: 'string',
      enum: ['escalating', 'de_escalating', 'neutral'],
      description:
        'Whether the target sentence heats up, cools down, or holds the conflict steady.',
    },
    intensity: {
      type: 'integer',
      minimum: 0,
      maximum: 100,
      description:
        'How strongly the target sentence carries the detected tone. Neutral/calm should be low.',
    },
    confidence: {
      type: 'number',
      minimum: 0,
      maximum: 1,
      description: 'Classifier confidence based only on the words provided.',
    },
    summary: {
      type: 'string',
      description: 'Short neutral phrase describing what changed in the room.',
    },
    signals: {
      type: 'array',
      minItems: 1,
      maxItems: 5,
      items: {
        type: 'string',
        enum: roomToneSignals,
      },
    },
    phrases: {
      type: 'array',
      minItems: 0,
      maxItems: 3,
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          text: {
            type: 'string',
            description:
              'A short exact phrase from the target sentence, not the context.',
          },
          signal: {
            type: 'string',
            enum: roomToneSignals,
          },
        },
        required: ['text', 'signal'],
      },
    },
  },
  required: [
    'dominantTone',
    'trend',
    'intensity',
    'confidence',
    'summary',
    'signals',
    'phrases',
  ],
} as const;

export class RoomToneAnalyzer {
  private readonly generator?: RoomToneGenerator;
  private readonly history: RoomToneSentence[] = [];
  private readonly queue: QueuedSentence[] = [];
  private readonly idleResolvers: Array<() => void> = [];
  private lineNumber = 0;
  private processing = false;
  private closed = false;
  private disabledEmitted = false;

  constructor(private readonly options: RoomToneAnalyzerOptions) {
    this.generator =
      options.generator ??
      (options.config.geminiApiKey
        ? new GeminiRoomToneGenerator({
            apiKey: options.config.geminiApiKey,
            model: options.config.roomToneGeminiModel,
          })
        : undefined);
  }

  start(): void {
    if (!this.generator) {
      this.emitDisabled();
    }
  }

  recordTranscript(event: TranscriptFinalEvent): void {
    if (this.closed) return;
    if (!this.generator) {
      this.emitDisabled();
      return;
    }

    const lineNumber = ++this.lineNumber;
    const sentences = splitIntoSentences(event.text);
    sentences.forEach((text, index) => {
      const sentence: RoomToneSentence = {
        lineNumber,
        sentenceIndex: index + 1,
        speaker: event.speaker,
        ...(event.speakerLabel ? { speakerLabel: event.speakerLabel } : {}),
        text,
      };
      const context = this.history.slice(-CONTEXT_SENTENCES);
      this.history.push(sentence);
      if (this.history.length > MAX_HISTORY_SENTENCES) {
        this.history.splice(0, this.history.length - MAX_HISTORY_SENTENCES);
      }
      this.enqueue({ sentence, context });
    });
  }

  close(): void {
    this.closed = true;
    this.queue.length = 0;
    this.resolveIdleIfNeeded();
  }

  async flushForTest(): Promise<void> {
    while (this.processing || this.queue.length > 0) {
      await new Promise<void>((resolve) => this.idleResolvers.push(resolve));
    }
  }

  private enqueue(item: QueuedSentence): void {
    this.queue.push(item);
    if (this.queue.length > MAX_PENDING_SENTENCES) {
      this.queue.splice(0, this.queue.length - MAX_PENDING_SENTENCES);
    }
    void this.processQueue();
  }

  private async processQueue(): Promise<void> {
    if (this.processing || this.closed || !this.generator) return;

    const item = this.queue.shift();
    if (!item) {
      this.resolveIdleIfNeeded();
      return;
    }

    this.processing = true;
    try {
      const generated = await this.generator.analyze({
        sentence: item.sentence,
        context: item.context,
      });
      if (this.closed) return;

      const normalized = normalizeGenerated(generated);
      const event: RoomToneAnalyzedEvent = {
        type: 'room_tone.analyzed',
        provider: 'gemini',
        sessionId: this.options.sessionId,
        streamId: this.options.streamId,
        model: this.options.config.roomToneGeminiModel,
        generatedAt: new Date().toISOString(),
        lineNumber: item.sentence.lineNumber,
        sentenceIndex: item.sentence.sentenceIndex,
        speaker: item.sentence.speaker,
        ...(item.sentence.speakerLabel
          ? { speakerLabel: item.sentence.speakerLabel }
          : {}),
        text: item.sentence.text,
        ...normalized,
      };
      this.options.emit(event);
    } catch (error) {
      if (!this.closed) {
        this.options.emit({
          type: 'room_tone.error',
          provider: 'gemini',
          message:
            error instanceof Error
              ? error.message
              : 'Unknown room tone analysis error',
        });
      }
    } finally {
      this.processing = false;
      if (this.queue.length > 0 && !this.closed) {
        setImmediate(() => void this.processQueue());
      } else {
        this.resolveIdleIfNeeded();
      }
    }
  }

  private emitDisabled(): void {
    if (this.disabledEmitted) return;
    this.disabledEmitted = true;
    this.options.emit({
      type: 'room_tone.disabled',
      provider: 'gemini',
      reason: 'missing_gemini_api_key',
    });
  }

  private resolveIdleIfNeeded(): void {
    if (this.processing || this.queue.length > 0) return;
    const resolvers = this.idleResolvers.splice(0);
    for (const resolve of resolvers) resolve();
  }
}

class GeminiRoomToneGenerator implements RoomToneGenerator {
  constructor(
    private readonly options: {
      apiKey: string;
      model: string;
      timeoutMs?: number;
    },
  ) {}

  async analyze(
    input: RoomToneGeneratorInput,
  ): Promise<GeneratedRoomToneAnalysis> {
    const response = await fetch('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': this.options.apiKey,
      },
      body: JSON.stringify({
        model: this.options.model,
        input: buildPrompt(input),
        system_instruction:
          'You are a fast, conservative conflict tone classifier. Use only observable language. Do not diagnose, infer private motives, or take sides. Return compact JSON only.',
        store: false,
        response_format: {
          type: 'text',
          mime_type: 'application/json',
          schema: roomToneJsonSchema,
        },
        generation_config: {
          temperature: 0,
          max_output_tokens: 500,
          thinking_level: 'minimal',
        },
      }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 4_500),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini room tone request failed with ${response.status}: ${truncate(
          await response.text(),
          240,
        )}`,
      );
    }

    const rawPayload = await response.json();
    const direct = generatedRoomToneSchema.safeParse(rawPayload);
    if (direct.success) {
      return normalizeGenerated(direct.data);
    }

    const payload = interactionResponseSchema.parse(rawPayload);
    const outputText = extractInteractionText(payload);
    if (!outputText) {
      throw new Error('Gemini returned no room tone text.');
    }

    return normalizeGenerated(
      generatedRoomToneSchema.parse(JSON.parse(outputText)),
    );
  }
}

function buildPrompt(input: RoomToneGeneratorInput): string {
  const context =
    input.context.length === 0
      ? 'None.'
      : input.context
          .map((sentence) => {
            const speaker = sentence.speakerLabel ?? sentence.speaker;
            return `${sentence.lineNumber}.${sentence.sentenceIndex} ${speaker}: ${sentence.text}`;
          })
          .join('\n');
  const speaker = input.sentence.speakerLabel ?? input.sentence.speaker;

  return [
    'Analyze the TARGET sentence for live room tone.',
    'Use CONTEXT only to understand whether the target escalates, de-escalates, repairs, forgives, compromises, validates, attacks, dismisses, or stays neutral.',
    'Evidence phrases must come from TARGET only.',
    'Prefer neutral/calm when the text is ambiguous.',
    '',
    'Available signals:',
    roomToneSignals.join(', '),
    '',
    'CONTEXT:',
    context,
    '',
    'TARGET:',
    `${input.sentence.lineNumber}.${input.sentence.sentenceIndex} ${speaker}: ${input.sentence.text}`,
  ].join('\n');
}

function normalizeGenerated(
  generated: GeneratedRoomToneAnalysis,
): Required<GeneratedRoomToneAnalysis> {
  const dominantTone = generated.dominantTone;
  const signals = uniqueSignals([
    dominantTone,
    ...(generated.signals ?? []),
  ]).slice(0, 5);
  const phrases = (generated.phrases ?? [])
    .map((phrase) => ({
      text: phrase.text.trim().slice(0, 80),
      signal: phrase.signal,
    }))
    .filter((phrase) => phrase.text.length > 0)
    .slice(0, 3);

  return {
    dominantTone,
    trend: generated.trend,
    intensity: clamp(Math.round(generated.intensity), 0, 100),
    confidence: clamp(generated.confidence, 0, 1),
    summary: generated.summary.trim().slice(0, 140) || labelFor(dominantTone),
    signals,
    phrases,
  };
}

export function splitIntoSentences(text: string): string[] {
  const normalized = text.replace(/\s+/g, ' ').trim();
  if (!normalized) return [];

  return (
    normalized.match(/[^.!?]+(?:[.!?]+|$)/g) ?? [normalized]
  )
    .map((sentence) => sentence.trim())
    .filter((sentence) => sentence.length > 0);
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

function uniqueSignals(signals: readonly RoomToneSignal[]): RoomToneSignal[] {
  return [...new Set(signals)];
}

function labelFor(signal: RoomToneSignal): string {
  return signal.replace(/_/g, ' ');
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
