import path from 'node:path';

export interface AppConfig {
  host: string;
  port: number;
  audioStorageDir: string;
  maxAudioChunkBytes: number;
  deepgramApiKey?: string;
  deepgramModel: string;
  deepgramLanguage: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  return {
    host: env.HOST ?? '0.0.0.0',
    port: readNumber(env.PORT, 8081),
    audioStorageDir: path.resolve(env.AUDIO_STORAGE_DIR ?? 'data/sessions'),
    maxAudioChunkBytes: readNumber(env.MAX_AUDIO_CHUNK_BYTES, 1024 * 1024),
    deepgramApiKey: env.DEEPGRAM_API_KEY,
    deepgramModel: env.DEEPGRAM_MODEL ?? 'nova-3',
    deepgramLanguage: env.DEEPGRAM_LANGUAGE ?? 'en-US',
  };
}

function readNumber(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
