import path from 'node:path';

export interface AppConfig {
  host: string;
  port: number;
  audioStorageDir: string;
  maxAudioChunkBytes: number;
  deepgramApiKey?: string;
  deepgramModel: string;
  deepgramLanguage: string;
  geminiApiKey?: string;
  geminiModel: string;
  compromiseInitialDelayMs: number;
  compromiseIntervalMs: number;
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
    geminiApiKey: env.GEMINI_API_KEY,
    geminiModel: env.GEMINI_MODEL ?? 'gemini-3.5-flash',
    compromiseInitialDelayMs: readNumber(env.COMPROMISE_INITIAL_DELAY_MS, 60_000),
    compromiseIntervalMs: readNumber(env.COMPROMISE_INTERVAL_MS, 30_000),
  };
}

function readNumber(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
