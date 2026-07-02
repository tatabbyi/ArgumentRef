import { z } from 'zod';
import type { AppConfig } from '../config.js';

export interface SpeechAudioResponse {
  audio: Buffer;
  contentType: string;
  voiceId: string;
  modelId: string;
  outputFormat: string;
}

export class SpeechServiceError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly code: string,
  ) {
    super(message);
  }
}

const speechRequestSchema = z.object({
  text: z.string().trim().min(1),
  voiceId: z.string().trim().min(1).max(120).optional(),
  modelId: z.string().trim().min(1).max(120).optional(),
  outputFormat: z.string().trim().min(1).max(80).optional(),
});

export type SpeechRequest = z.infer<typeof speechRequestSchema>;

export async function synthesizeSpeech(
  config: AppConfig,
  payload: unknown,
): Promise<SpeechAudioResponse> {
  if (!config.elevenLabsApiKey) {
    throw new SpeechServiceError(
      'Set ELEVENLABS_API_KEY on the backend to enable AI voice.',
      503,
      'speech_disabled',
    );
  }

  const request = speechRequestSchema.parse(payload);
  if (request.text.length > config.elevenLabsMaxTextChars) {
    throw new SpeechServiceError(
      `Text must be ${config.elevenLabsMaxTextChars} characters or fewer.`,
      400,
      'text_too_long',
    );
  }

  const voiceId = request.voiceId ?? config.elevenLabsVoiceId;
  const modelId = request.modelId ?? config.elevenLabsModelId;
  const outputFormat = request.outputFormat ?? config.elevenLabsOutputFormat;
  const url = new URL(
    `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}`,
  );
  url.searchParams.set('output_format', outputFormat);

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      accept: outputFormatContentType(outputFormat),
      'content-type': 'application/json',
      'xi-api-key': config.elevenLabsApiKey,
    },
    body: JSON.stringify({
      text: request.text,
      model_id: modelId,
    }),
    signal: AbortSignal.timeout(20_000),
  });

  if (!response.ok) {
    throw new SpeechServiceError(
      `ElevenLabs speech request failed with ${response.status}: ${truncate(
        await response.text(),
        240,
      )}`,
      response.status >= 400 && response.status < 500 ? 400 : 502,
      'speech_provider_failed',
    );
  }

  return {
    audio: Buffer.from(await response.arrayBuffer()),
    contentType:
      response.headers.get('content-type') ?? outputFormatContentType(outputFormat),
    voiceId,
    modelId,
    outputFormat,
  };
}

function outputFormatContentType(outputFormat: string): string {
  if (outputFormat.startsWith('pcm_')) return 'audio/wav';
  if (outputFormat.startsWith('ulaw_')) return 'audio/basic';
  if (outputFormat.startsWith('opus_')) return 'audio/ogg';
  return 'audio/mpeg';
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
