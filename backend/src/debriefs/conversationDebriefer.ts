import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';
import type { AppConfig } from '../config.js';
import type { TranscriptFinalEvent } from '../protocol/messages.js';
import type { AudioStreamSnapshot } from '../sessions/sessionStore.js';

export type ConversationDebriefStatus =
  | 'completed'
  | 'disabled'
  | 'skipped'
  | 'failed';

export interface ConversationTranscriptLine {
  lineNumber: number;
  speaker: string;
  speakerLabel?: string;
  text: string;
  startMs?: number;
  endMs?: number;
  confidence?: number;
}

export interface ConversationDebriefGenerator {
  generate(
    lines: readonly ConversationTranscriptLine[],
  ): Promise<GeneratedConversationDebrief>;
}

export interface ConversationDebriefFinishResult {
  status: ConversationDebriefStatus;
  debriefPath: string;
  profilePath?: string;
}

interface ConversationDebrieferOptions {
  sessionId: string;
  streamId: string;
  participantId: string;
  config: AppConfig;
  debriefPath: string;
  profilePath: string;
  generator?: ConversationDebriefGenerator;
  now?: () => Date;
}

const MAX_ARRAY_ITEMS = 8;
const MAX_EVIDENCE_LINES = 12;

const confidenceSchema = z.enum(['low', 'medium', 'high']);

const textSignalSchema = z
  .object({
    label: z.string().min(1).max(90),
    description: z.string().min(1).max(320),
    evidenceLineNumbers: z
      .array(z.number().int().positive())
      .max(MAX_EVIDENCE_LINES),
    confidence: confidenceSchema,
  })
  .strict();

const generatedConversationDebriefSchema = z
  .object({
    overview: z
      .object({
        title: z.string().min(1).max(100),
        whatTheyArguedAbout: z.string().min(1).max(900),
        topics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
      })
      .strict(),
    solution: z
      .object({
        status: z.enum(['resolved', 'partly_resolved', 'unresolved', 'unclear']),
        summary: z.string().min(1).max(900),
        agreedActions: z.array(z.string().min(1).max(220)).max(MAX_ARRAY_ITEMS),
        openQuestions: z.array(z.string().min(1).max(220)).max(MAX_ARRAY_ITEMS),
        nextSteps: z.array(z.string().min(1).max(220)).max(MAX_ARRAY_ITEMS),
      })
      .strict(),
    participantBreakdown: z
      .array(
        z
          .object({
            speaker: z.string().min(1).max(120),
            displayName: z.string().min(1).max(120),
            positionSummary: z.string().min(1).max(500),
            needs: z.array(z.string().min(1).max(180)).max(MAX_ARRAY_ITEMS),
            argumentTraits: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
            notableCharacteristics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
          })
          .strict(),
      )
      .max(6),
    interactionDynamics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
    profileSignals: z
      .object({
        pair: z
          .object({
            recurringTopics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
            recurringDynamics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
          })
          .strict(),
        individuals: z
          .array(
            z
              .object({
                speaker: z.string().min(1).max(120),
                displayName: z.string().min(1).max(120),
                argumentTraits: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
                triggerTopics: z.array(textSignalSchema).max(MAX_ARRAY_ITEMS),
                repairStrategies: z
                  .array(z.string().min(1).max(220))
                  .max(MAX_ARRAY_ITEMS),
              })
              .strict(),
          )
          .max(6),
      })
      .strict(),
    cautionNotes: z.array(z.string().min(1).max(240)).max(MAX_ARRAY_ITEMS),
  })
  .strict();

export type GeneratedConversationDebrief = z.infer<
  typeof generatedConversationDebriefSchema
>;

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

const textSignalJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    label: {
      type: 'string',
      description: 'Short reusable label, for example "chores" or "raised voice".',
    },
    description: {
      type: 'string',
      description: 'A concise explanation grounded in the transcript.',
    },
    evidenceLineNumbers: {
      type: 'array',
      maxItems: MAX_EVIDENCE_LINES,
      items: {
        type: 'integer',
        minimum: 1,
      },
      description: 'Transcript line numbers that support this signal.',
    },
    confidence: {
      type: 'string',
      enum: ['low', 'medium', 'high'],
    },
  },
  required: ['label', 'description', 'evidenceLineNumbers', 'confidence'],
} as const;

const debriefJsonSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    overview: {
      type: 'object',
      additionalProperties: false,
      properties: {
        title: { type: 'string' },
        whatTheyArguedAbout: {
          type: 'string',
          description: 'Plain-language summary of the argument.',
        },
        topics: {
          type: 'array',
          maxItems: MAX_ARRAY_ITEMS,
          items: textSignalJsonSchema,
        },
      },
      required: ['title', 'whatTheyArguedAbout', 'topics'],
    },
    solution: {
      type: 'object',
      additionalProperties: false,
      properties: {
        status: {
          type: 'string',
          enum: ['resolved', 'partly_resolved', 'unresolved', 'unclear'],
        },
        summary: { type: 'string' },
        agreedActions: {
          type: 'array',
          maxItems: MAX_ARRAY_ITEMS,
          items: { type: 'string' },
        },
        openQuestions: {
          type: 'array',
          maxItems: MAX_ARRAY_ITEMS,
          items: { type: 'string' },
        },
        nextSteps: {
          type: 'array',
          maxItems: MAX_ARRAY_ITEMS,
          items: { type: 'string' },
        },
      },
      required: [
        'status',
        'summary',
        'agreedActions',
        'openQuestions',
        'nextSteps',
      ],
    },
    participantBreakdown: {
      type: 'array',
      maxItems: 6,
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          speaker: { type: 'string' },
          displayName: { type: 'string' },
          positionSummary: { type: 'string' },
          needs: {
            type: 'array',
            maxItems: MAX_ARRAY_ITEMS,
            items: { type: 'string' },
          },
          argumentTraits: {
            type: 'array',
            maxItems: MAX_ARRAY_ITEMS,
            items: textSignalJsonSchema,
          },
          notableCharacteristics: {
            type: 'array',
            maxItems: MAX_ARRAY_ITEMS,
            items: textSignalJsonSchema,
          },
        },
        required: [
          'speaker',
          'displayName',
          'positionSummary',
          'needs',
          'argumentTraits',
          'notableCharacteristics',
        ],
      },
    },
    interactionDynamics: {
      type: 'array',
      maxItems: MAX_ARRAY_ITEMS,
      items: textSignalJsonSchema,
    },
    profileSignals: {
      type: 'object',
      additionalProperties: false,
      properties: {
        pair: {
          type: 'object',
          additionalProperties: false,
          properties: {
            recurringTopics: {
              type: 'array',
              maxItems: MAX_ARRAY_ITEMS,
              items: textSignalJsonSchema,
            },
            recurringDynamics: {
              type: 'array',
              maxItems: MAX_ARRAY_ITEMS,
              items: textSignalJsonSchema,
            },
          },
          required: ['recurringTopics', 'recurringDynamics'],
        },
        individuals: {
          type: 'array',
          maxItems: 6,
          items: {
            type: 'object',
            additionalProperties: false,
            properties: {
              speaker: { type: 'string' },
              displayName: { type: 'string' },
              argumentTraits: {
                type: 'array',
                maxItems: MAX_ARRAY_ITEMS,
                items: textSignalJsonSchema,
              },
              triggerTopics: {
                type: 'array',
                maxItems: MAX_ARRAY_ITEMS,
                items: textSignalJsonSchema,
              },
              repairStrategies: {
                type: 'array',
                maxItems: MAX_ARRAY_ITEMS,
                items: { type: 'string' },
              },
            },
            required: [
              'speaker',
              'displayName',
              'argumentTraits',
              'triggerTopics',
              'repairStrategies',
            ],
          },
        },
      },
      required: ['pair', 'individuals'],
    },
    cautionNotes: {
      type: 'array',
      maxItems: MAX_ARRAY_ITEMS,
      items: { type: 'string' },
    },
  },
  required: [
    'overview',
    'solution',
    'participantBreakdown',
    'interactionDynamics',
    'profileSignals',
    'cautionNotes',
  ],
} as const;

interface StoredConversationDebrief {
  version: 1;
  type: 'conversation_debrief';
  sessionId: string;
  streamId: string;
  participantId: string;
  provider: 'gemini';
  model: string;
  generatedAt: string;
  analysisStatus: ConversationDebriefStatus;
  analysisError?: {
    code: string;
    message: string;
  };
  transcriptLineCount: number;
  participants: string[];
  audio: {
    bytesReceived: number;
    chunksReceived: number;
    storagePath: string;
  };
  transcript: ConversationTranscriptLine[];
  debrief?: GeneratedConversationDebrief;
  profileStoragePath?: string;
}

interface LocalArgumentProfiles {
  version: 1;
  updatedAt: string;
  pairs: Record<string, PairArgumentProfile>;
  individuals: Record<string, IndividualArgumentProfile>;
}

interface PairArgumentProfile {
  key: string;
  participants: string[];
  conversationCount: number;
  lastDebriefPath: string;
  updatedAt: string;
  recurringTopics: SignalCounter[];
  recurringDynamics: SignalCounter[];
}

interface IndividualArgumentProfile {
  key: string;
  displayName: string;
  conversationCount: number;
  lastDebriefPath: string;
  updatedAt: string;
  argumentTraits: SignalCounter[];
  triggerTopics: SignalCounter[];
  repairStrategies: SignalCounter[];
}

interface SignalCounter {
  label: string;
  count: number;
  lastSeenAt: string;
  debriefPaths: string[];
  evidenceLineNumbers: number[];
}

export class ConversationDebriefer {
  private readonly lines: ConversationTranscriptLine[] = [];
  private readonly generator?: ConversationDebriefGenerator;
  private finishPromise: Promise<ConversationDebriefFinishResult> | null = null;

  constructor(private readonly options: ConversationDebrieferOptions) {
    this.generator =
      options.generator ??
      (options.config.geminiApiKey
        ? new GeminiConversationDebriefGenerator({
            apiKey: options.config.geminiApiKey,
            model: options.config.geminiModel,
          })
        : undefined);
  }

  recordTranscript(event: TranscriptFinalEvent): void {
    const text = event.text.trim();
    if (!text) return;

    this.lines.push({
      lineNumber: this.lines.length + 1,
      speaker: event.speaker,
      speakerLabel: event.speakerLabel,
      text,
      startMs: event.startMs,
      endMs: event.endMs,
      confidence: event.confidence,
    });
  }

  finish(
    snapshot: AudioStreamSnapshot,
  ): Promise<ConversationDebriefFinishResult> {
    this.finishPromise ??= this.finishOnce(snapshot);
    return this.finishPromise;
  }

  private async finishOnce(
    snapshot: AudioStreamSnapshot,
  ): Promise<ConversationDebriefFinishResult> {
    const generatedAt = (this.options.now?.() ?? new Date()).toISOString();
    const participants = participantNames(this.lines);
    let status: ConversationDebriefStatus = 'completed';
    let analysisError: StoredConversationDebrief['analysisError'];
    let generated: GeneratedConversationDebrief | undefined;

    if (this.lines.length === 0) {
      status = 'skipped';
      analysisError = {
        code: 'no_transcript',
        message: 'No final transcript lines were available to debrief.',
      };
    } else if (!this.generator) {
      status = 'disabled';
      analysisError = {
        code: 'missing_gemini_api_key',
        message: 'Set GEMINI_API_KEY on the backend to generate debriefs.',
      };
    } else {
      try {
        generated = await this.generator.generate(this.lines);
      } catch (error) {
        status = 'failed';
        analysisError = {
          code: 'gemini_debrief_failed',
          message:
            error instanceof Error
              ? error.message
              : 'Unknown Gemini debrief error',
        };
      }
    }

    const record: StoredConversationDebrief = {
      version: 1,
      type: 'conversation_debrief',
      sessionId: this.options.sessionId,
      streamId: this.options.streamId,
      participantId: this.options.participantId,
      provider: 'gemini',
      model: this.options.config.geminiModel,
      generatedAt,
      analysisStatus: status,
      ...(analysisError ? { analysisError } : {}),
      transcriptLineCount: this.lines.length,
      participants,
      audio: {
        bytesReceived: snapshot.bytesReceived,
        chunksReceived: snapshot.chunksReceived,
        storagePath: snapshot.filePath,
      },
      transcript: this.lines,
      ...(generated ? { debrief: generated } : {}),
      ...(generated ? { profileStoragePath: this.options.profilePath } : {}),
    };

    await writeJsonFile(this.options.debriefPath, record);

    if (generated) {
      await updateLocalProfiles({
        filePath: this.options.profilePath,
        debriefPath: this.options.debriefPath,
        generatedAt,
        participants,
        debrief: generated,
      });
    }

    return {
      status,
      debriefPath: this.options.debriefPath,
      ...(generated ? { profilePath: this.options.profilePath } : {}),
    };
  }
}

export class GeminiConversationDebriefGenerator
  implements ConversationDebriefGenerator
{
  constructor(
    private readonly options: {
      apiKey: string;
      model: string;
      timeoutMs?: number;
    },
  ) {}

  async generate(
    lines: readonly ConversationTranscriptLine[],
  ): Promise<GeneratedConversationDebrief> {
    const response = await fetch('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': this.options.apiKey,
      },
      body: JSON.stringify({
        model: this.options.model,
        input: buildDebriefPrompt(lines),
        system_instruction:
          'You are a careful conflict debrief analyst. Extract observable argument patterns from the transcript, stay neutral, do not diagnose either person, and return only evidence-grounded JSON.',
        store: false,
        response_format: {
          type: 'text',
          mime_type: 'application/json',
          schema: debriefJsonSchema,
        },
        generation_config: {
          temperature: 0.2,
          max_output_tokens: 5000,
          thinking_level: 'low',
        },
      }),
      signal: AbortSignal.timeout(this.options.timeoutMs ?? 20_000),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini debrief request failed with ${response.status}: ${truncate(
          await response.text(),
          240,
        )}`,
      );
    }

    const rawPayload = await response.json();
    const direct = generatedConversationDebriefSchema.safeParse(rawPayload);
    if (direct.success) {
      return direct.data;
    }

    const payload = interactionResponseSchema.parse(rawPayload);
    const outputText = extractInteractionText(payload);
    if (!outputText) {
      throw new Error('Gemini returned no debrief text.');
    }

    return generatedConversationDebriefSchema.parse(JSON.parse(outputText));
  }
}

function buildDebriefPrompt(lines: readonly ConversationTranscriptLine[]): string {
  const transcript = lines
    .map((line) => {
      const speaker = line.speakerLabel ?? line.speaker;
      return `${line.lineNumber}. ${speaker}: ${line.text}`;
    })
    .join('\n');

  return [
    'Create a full post-conversation debrief for this argument.',
    'Break down what the users argued about, the solution or lack of solution, and any observable characteristics such as raised voice, interrupting, repeating the same point, dismissing, apologizing, or trying to repair.',
    'Only include characteristics that are supported by the transcript text or speaker labels. If the transcript does not show yelling, do not claim yelling.',
    'Use the transcript line numbers as evidence for every topic, trait, and dynamic.',
    'Build profile signals for the pair and each individual so future local code can count what they tend to argue about and how each person tends to argue.',
    'Stay neutral and practical. Do not diagnose, moralize, or infer private motives.',
    '',
    'Transcript:',
    transcript,
  ].join('\n');
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

async function updateLocalProfiles(options: {
  filePath: string;
  debriefPath: string;
  generatedAt: string;
  participants: readonly string[];
  debrief: GeneratedConversationDebrief;
}): Promise<void> {
  const profiles = await readProfiles(options.filePath);
  profiles.updatedAt = options.generatedAt;

  const pairKey = pairProfileKey(options.participants);
  const pair =
    profiles.pairs[pairKey] ??
    (profiles.pairs[pairKey] = {
      key: pairKey,
      participants: [...options.participants],
      conversationCount: 0,
      lastDebriefPath: options.debriefPath,
      updatedAt: options.generatedAt,
      recurringTopics: [],
      recurringDynamics: [],
    });

  pair.participants = mergeUnique(pair.participants, options.participants);
  pair.conversationCount += 1;
  pair.lastDebriefPath = options.debriefPath;
  pair.updatedAt = options.generatedAt;
  for (const topic of options.debrief.profileSignals.pair.recurringTopics) {
    upsertSignal(pair.recurringTopics, topic, options);
  }
  for (const dynamic of options.debrief.profileSignals.pair.recurringDynamics) {
    upsertSignal(pair.recurringDynamics, dynamic, options);
  }

  for (const person of options.debrief.profileSignals.individuals) {
    const displayName = cleanName(person.displayName) || cleanName(person.speaker);
    if (!displayName) continue;

    const key = profileKey(displayName);
    const individual =
      profiles.individuals[key] ??
      (profiles.individuals[key] = {
        key,
        displayName,
        conversationCount: 0,
        lastDebriefPath: options.debriefPath,
        updatedAt: options.generatedAt,
        argumentTraits: [],
        triggerTopics: [],
        repairStrategies: [],
      });

    individual.displayName = displayName;
    individual.conversationCount += 1;
    individual.lastDebriefPath = options.debriefPath;
    individual.updatedAt = options.generatedAt;
    for (const trait of person.argumentTraits) {
      upsertSignal(individual.argumentTraits, trait, options);
    }
    for (const topic of person.triggerTopics) {
      upsertSignal(individual.triggerTopics, topic, options);
    }
    for (const strategy of person.repairStrategies) {
      upsertLabel(individual.repairStrategies, strategy, options);
    }
  }

  await writeJsonFile(options.filePath, profiles);
}

async function readProfiles(filePath: string): Promise<LocalArgumentProfiles> {
  try {
    const parsed = JSON.parse(await readFile(filePath, 'utf8')) as Partial<LocalArgumentProfiles>;
    return {
      version: 1,
      updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : '',
      pairs: isRecord(parsed.pairs) ? (parsed.pairs as Record<string, PairArgumentProfile>) : {},
      individuals: isRecord(parsed.individuals)
        ? (parsed.individuals as Record<string, IndividualArgumentProfile>)
        : {},
    };
  } catch {
    return {
      version: 1,
      updatedAt: '',
      pairs: {},
      individuals: {},
    };
  }
}

function upsertSignal(
  counters: SignalCounter[],
  signal: z.infer<typeof textSignalSchema>,
  options: {
    debriefPath: string;
    generatedAt: string;
  },
): void {
  upsertCounter(counters, signal.label, signal.evidenceLineNumbers, options);
}

function upsertLabel(
  counters: SignalCounter[],
  label: string,
  options: {
    debriefPath: string;
    generatedAt: string;
  },
): void {
  upsertCounter(counters, label, [], options);
}

function upsertCounter(
  counters: SignalCounter[],
  rawLabel: string,
  evidenceLineNumbers: readonly number[],
  options: {
    debriefPath: string;
    generatedAt: string;
  },
): void {
  const label = rawLabel.trim();
  if (!label) return;

  const key = profileKey(label);
  let counter = counters.find((item) => profileKey(item.label) === key);
  if (!counter) {
    counter = {
      label,
      count: 0,
      lastSeenAt: options.generatedAt,
      debriefPaths: [],
      evidenceLineNumbers: [],
    };
    counters.push(counter);
  }

  counter.count += 1;
  counter.lastSeenAt = options.generatedAt;
  counter.debriefPaths = mergeUnique([options.debriefPath], counter.debriefPaths).slice(0, 8);
  counter.evidenceLineNumbers = mergeUniqueNumbers(
    evidenceLineNumbers,
    counter.evidenceLineNumbers,
  ).slice(0, MAX_EVIDENCE_LINES);
}

async function writeJsonFile(filePath: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function participantNames(lines: readonly ConversationTranscriptLine[]): string[] {
  const names = lines.map((line) => line.speakerLabel ?? line.speaker);
  return mergeUnique(names).length > 0 ? mergeUnique(names) : ['unknown'];
}

function pairProfileKey(participants: readonly string[]): string {
  const keys = mergeUnique(participants)
    .map(profileKey)
    .filter(Boolean)
    .sort();
  return keys.join('__') || 'unknown';
}

function cleanName(value: string): string {
  return value.trim();
}

function profileKey(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80);
}

function mergeUnique(
  first: readonly string[],
  second: readonly string[] = [],
): string[] {
  const seen = new Set<string>();
  const merged: string[] = [];

  for (const value of [...first, ...second]) {
    const cleaned = value.trim();
    if (!cleaned) continue;
    const key = cleaned.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(cleaned);
  }

  return merged;
}

function mergeUniqueNumbers(
  first: readonly number[],
  second: readonly number[] = [],
): number[] {
  const seen = new Set<number>();
  const merged: number[] = [];

  for (const value of [...first, ...second]) {
    if (!Number.isInteger(value) || value <= 0 || seen.has(value)) continue;
    seen.add(value);
    merged.push(value);
  }

  return merged;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
