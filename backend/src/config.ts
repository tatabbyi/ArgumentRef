import path from 'node:path';

export interface AppConfig {
  host: string;
  port: number;
  audioStorageDir: string;
  maxAudioChunkBytes: number;
  databaseUrl?: string;
  databaseSsl: boolean;
  deepgramApiKey?: string;
  deepgramModel: string;
  deepgramLanguage: string;
  factCheckEnabled: boolean;
  factCheckProvider: 'google-fact-check';
  googleFactCheckApiKey?: string;
  googleFactCheckLanguageCode: string;
  googleFactCheckPageSize: number;
  factCheckMaxClaimsPerSession: number;
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
    databaseUrl: env.DATABASE_URL,
    databaseSsl: readBoolean(
      env.DATABASE_SSL,
      databaseUrlRequestsSsl(env.DATABASE_URL),
    ),
    deepgramApiKey: env.DEEPGRAM_API_KEY,
    deepgramModel: env.DEEPGRAM_MODEL ?? 'nova-3',
    deepgramLanguage: env.DEEPGRAM_LANGUAGE ?? 'en-US',
    factCheckEnabled: readBoolean(
      env.FACT_CHECK_ENABLED,
      Boolean(env.GOOGLE_FACT_CHECK_API_KEY),
    ),
    factCheckProvider: 'google-fact-check',
    googleFactCheckApiKey: env.GOOGLE_FACT_CHECK_API_KEY,
    googleFactCheckLanguageCode: env.GOOGLE_FACT_CHECK_LANGUAGE_CODE ?? 'en-US',
    googleFactCheckPageSize: readNumber(env.GOOGLE_FACT_CHECK_PAGE_SIZE, 3),
    factCheckMaxClaimsPerSession: readNumber(
      env.FACT_CHECK_MAX_CLAIMS_PER_SESSION,
      5,
    ),
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

function readBoolean(value: string | undefined, fallback: boolean): boolean {
  if (!value) {
    return fallback;
  }

  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

function databaseUrlRequestsSsl(value: string | undefined): boolean {
  if (!value) {
    return false;
  }

  try {
    const url = new URL(value);
    return url.searchParams.get('sslmode') === 'require';
  } catch {
    return false;
  }
}
