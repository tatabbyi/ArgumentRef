import path from 'node:path';

export interface AppConfig {
  host: string;
  port: number;
  audioStorageDir: string;
  maxAudioChunkBytes: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  return {
    host: env.HOST ?? '0.0.0.0',
    port: readNumber(env.PORT, 8081),
    audioStorageDir: path.resolve(env.AUDIO_STORAGE_DIR ?? 'data/sessions'),
    maxAudioChunkBytes: readNumber(env.MAX_AUDIO_CHUNK_BYTES, 1024 * 1024),
  };
}

function readNumber(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
