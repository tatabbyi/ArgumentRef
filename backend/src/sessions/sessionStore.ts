import { createWriteStream } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { WriteStream } from 'node:fs';
import type { AudioFormat } from '../protocol/messages.js';

export interface CreateAudioStreamInput {
  sessionId?: string;
  participantId?: string;
  audio: AudioFormat;
}

export interface AudioStreamSnapshot {
  sessionId: string;
  streamId: string;
  participantId: string;
  bytesReceived: number;
  chunksReceived: number;
  filePath: string;
}

export class SessionStore {
  constructor(private readonly baseDir: string) {}

  async createAudioStream(
    input: CreateAudioStreamInput,
  ): Promise<AudioStreamRecorder> {
    const sessionId = sanitizeId(input.sessionId ?? randomUUID());
    const participantId = sanitizeId(input.participantId ?? 'participant-1');
    const streamId = randomUUID();
    const sessionDir = path.join(this.baseDir, sessionId);
    const fileName = `${participantId}-${streamId}.audio`;
    const filePath = path.join(sessionDir, fileName);
    const metadataPath = path.join(sessionDir, `${participantId}-${streamId}.json`);

    await mkdir(sessionDir, { recursive: true });

    const recorder = new AudioStreamRecorder({
      sessionId,
      streamId,
      participantId,
      filePath,
      metadataPath,
      audio: input.audio,
    });

    await recorder.writeMetadata('open');
    return recorder;
  }
}

interface AudioStreamRecorderInput {
  sessionId: string;
  streamId: string;
  participantId: string;
  filePath: string;
  metadataPath: string;
  audio: AudioFormat;
}

export class AudioStreamRecorder {
  private readonly writeStream: WriteStream;
  private bytesReceived = 0;
  private chunksReceived = 0;
  private closed = false;
  private readonly startedAt = new Date();

  constructor(private readonly input: AudioStreamRecorderInput) {
    this.writeStream = createWriteStream(input.filePath, { flags: 'a' });
  }

  get sessionId(): string {
    return this.input.sessionId;
  }

  get streamId(): string {
    return this.input.streamId;
  }

  get participantId(): string {
    return this.input.participantId;
  }

  get filePath(): string {
    return this.input.filePath;
  }

  snapshot(): AudioStreamSnapshot {
    return {
      sessionId: this.sessionId,
      streamId: this.streamId,
      participantId: this.participantId,
      bytesReceived: this.bytesReceived,
      chunksReceived: this.chunksReceived,
      filePath: this.filePath,
    };
  }

  async writeChunk(chunk: Buffer): Promise<AudioStreamSnapshot> {
    if (this.closed) {
      throw new Error('Cannot write audio chunk after stream is closed');
    }

    if (chunk.length === 0) {
      return this.snapshot();
    }

    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        this.writeStream.off('drain', onDrain);
        reject(error);
      };
      const onDrain = () => {
        this.writeStream.off('error', onError);
        resolve();
      };

      this.writeStream.once('error', onError);

      if (this.writeStream.write(chunk)) {
        this.writeStream.off('error', onError);
        resolve();
      } else {
        this.writeStream.once('drain', onDrain);
      }
    });

    this.bytesReceived += chunk.length;
    this.chunksReceived += 1;
    return this.snapshot();
  }

  async writeMetadata(status: 'open' | 'closed'): Promise<void> {
    const metadata = {
      sessionId: this.sessionId,
      streamId: this.streamId,
      participantId: this.participantId,
      status,
      audio: this.input.audio,
      startedAt: this.startedAt.toISOString(),
      updatedAt: new Date().toISOString(),
      bytesReceived: this.bytesReceived,
      chunksReceived: this.chunksReceived,
      filePath: this.filePath,
    };

    await writeFile(
      this.input.metadataPath,
      `${JSON.stringify(metadata, null, 2)}\n`,
      'utf8',
    );
  }

  async close(): Promise<AudioStreamSnapshot> {
    if (this.closed) {
      return this.snapshot();
    }

    this.closed = true;

    await new Promise<void>((resolve, reject) => {
      this.writeStream.end((error?: Error | null) => {
        if (error) {
          reject(error);
          return;
        }

        resolve();
      });
    });

    await this.writeMetadata('closed');
    return this.snapshot();
  }
}

function sanitizeId(value: string): string {
  const normalized = value.replace(/[^a-zA-Z0-9_-]/g, '-').slice(0, 120);
  return normalized.length > 0 ? normalized : randomUUID();
}
