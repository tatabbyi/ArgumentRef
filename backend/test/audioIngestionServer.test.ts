import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createAudioIngestionServer, type AudioIngestionServer } from '../src/audio/audioIngestionServer.js';
import type { ServerEvent } from '../src/protocol/messages.js';

describe('audio ingestion websocket', () => {
  let storageDir: string;
  let server: AudioIngestionServer;
  let port: number;

  beforeEach(async () => {
    storageDir = await mkdtemp(path.join(os.tmpdir(), 'argumentref-audio-'));
    server = createAudioIngestionServer({
      host: '127.0.0.1',
      port: 0,
      audioStorageDir: storageDir,
      maxAudioChunkBytes: 1024 * 1024,
      databaseSsl: false,
      deepgramModel: 'nova-3',
      deepgramLanguage: 'en-US',
      factCheckEnabled: false,
      factCheckProvider: 'google-fact-check',
      googleFactCheckLanguageCode: 'en-US',
      googleFactCheckPageSize: 3,
      factCheckMaxClaimsPerSession: 5,
      geminiModel: 'gemini-3.5-flash',
      compromiseInitialDelayMs: 60_000,
      compromiseIntervalMs: 30_000,
      fallacyDetectionEnabled: false,
      fallacyAnalysisIntervalMs: 20_000,
      fallacyMinConfidence: 'medium',
    });
    port = await server.listen();
  });

  afterEach(async () => {
    await server.close();
    await rm(storageDir, { recursive: true, force: true });
  });

  it('accepts binary audio chunks and stores them for the session', async () => {
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/v1/audio?sessionId=test-session&participantId=phone-1&encoding=pcm16&sampleRateHz=16000&channels=1`,
    );

    const started = await waitForEvent(socket, 'session.started');
    expect(started.sessionId).toBe('test-session');
    expect(started.participantId).toBe('phone-1');

    socket.send(Buffer.from([1, 2, 3, 4]));

    const ack = await waitForEvent(socket, 'audio.ack');
    expect(ack.bytesReceived).toBe(4);
    expect(ack.chunksReceived).toBe(1);

    socket.send(JSON.stringify({ type: 'session.stop' }));

    const ended = await waitForEvent(socket, 'session.ended');
    expect(ended.bytesReceived).toBe(4);
    expect(ended.chunksReceived).toBe(1);
    expect(ended.debriefStatus).toBe('skipped');
    expect(ended.debriefStoragePath).toBeTruthy();

    const stored = await readFile(ended.storagePath);
    expect([...stored]).toEqual([1, 2, 3, 4]);

    if (!ended.debriefStoragePath) {
      throw new Error('Expected session.ended to include debriefStoragePath');
    }
    const debrief = JSON.parse(await readFile(ended.debriefStoragePath, 'utf8')) as {
      analysisStatus: string;
      analysisError: { code: string };
      transcriptLineCount: number;
    };
    expect(debrief.analysisStatus).toBe('skipped');
    expect(debrief.analysisError.code).toBe('no_transcript');
    expect(debrief.transcriptLineCount).toBe(0);
  });

  it('responds to the health endpoint', async () => {
    const response = await fetch(`http://127.0.0.1:${port}/health`);
    const body = (await response.json()) as { status: string };

    expect(response.status).toBe(200);
    expect(body.status).toBe('ok');
  });

  it('reports when history endpoints are disabled without DATABASE_URL', async () => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/sessions`);
    const body = (await response.json()) as { error: string };

    expect(response.status).toBe(503);
    expect(body.error).toBe('history_disabled');
  });
});

function waitForEvent<TType extends ServerEvent['type']>(
  socket: WebSocket,
  type: TType,
): Promise<Extract<ServerEvent, { type: TType }>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for ${type}`));
    }, 2000);

    const onMessage = (data: WebSocket.RawData) => {
      const event = JSON.parse(data.toString()) as ServerEvent;

      if (event.type === type) {
        cleanup();
        resolve(event as Extract<ServerEvent, { type: TType }>);
      }
    };

    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };

    const cleanup = () => {
      clearTimeout(timeout);
      socket.off('message', onMessage);
      socket.off('error', onError);
    };

    socket.on('message', onMessage);
    socket.on('error', onError);
  });
}
