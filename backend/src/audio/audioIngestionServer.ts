import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { URL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';
import { ZodError } from 'zod';
import type { AddressInfo } from 'node:net';
import type { AppConfig } from '../config.js';
import {
  parseClientControlMessage,
  serializeServerEvent,
  type AudioFormat,
  type ServerEvent,
} from '../protocol/messages.js';
import { SessionStore, type AudioStreamRecorder } from '../sessions/sessionStore.js';
import {
  createDeepgramTranscriber,
  type Transcriber,
} from '../transcription/deepgramTranscriber.js';
import { ClaimDetector } from '../claims/claimDetector.js';
import { CompromiseAdvisor } from '../compromises/compromiseAdvisor.js';
import { ConversationDebriefer } from '../debriefs/conversationDebriefer.js';
import { parseSpeakerLabels, SpeakerLabeler } from '../speakers/speakerLabeler.js';

const DEFAULT_AUDIO: AudioFormat = {
  encoding: 'unknown',
};

export interface AudioIngestionServer {
  listen(): Promise<number>;
  close(): Promise<void>;
  address(): AddressInfo | string | null;
  httpServer: Server;
}

export function createAudioIngestionServer(config: AppConfig): AudioIngestionServer {
  const sessionStore = new SessionStore(config.audioStorageDir);
  const httpServer = createServer(handleHttpRequest);
  const webSocketServer = new WebSocketServer({
    noServer: true,
    maxPayload: config.maxAudioChunkBytes,
  });

  httpServer.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);

    if (url.pathname !== '/v1/audio') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }

    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      webSocketServer.emit('connection', webSocket, request);
    });
  });

  webSocketServer.on('connection', (webSocket, request) => {
    void handleAudioConnection(webSocket, request, sessionStore, config);
  });

  return {
    httpServer,
    listen: () =>
      new Promise((resolve, reject) => {
        httpServer.once('error', reject);
        httpServer.listen(config.port, config.host, () => {
          httpServer.off('error', reject);
          const address = httpServer.address();
          resolve(typeof address === 'object' && address ? address.port : config.port);
        });
      }),
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        webSocketServer.close((wsError) => {
          if (wsError) {
            reject(wsError);
            return;
          }

          httpServer.close((httpError) => {
            if (httpError) {
              reject(httpError);
              return;
            }

            resolve();
          });
        });
      });
    },
    address: () => httpServer.address(),
  };
}

function handleHttpRequest(request: IncomingMessage, response: ServerResponse): void {
  if (request.url === '/health') {
    sendJson(response, 200, {
      status: 'ok',
      service: 'argumentref-backend',
    });
    return;
  }

  sendJson(response, 404, {
    error: 'not_found',
    message: 'Use /health or connect WebSocket clients to /v1/audio.',
  });
}

async function handleAudioConnection(
  webSocket: WebSocket,
  request: IncomingMessage,
  sessionStore: SessionStore,
  config: AppConfig,
): Promise<void> {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  const audio = audioFormatFromUrl(url);
  const recorder = await sessionStore.createAudioStream({
    sessionId: optionalQuery(url, 'sessionId'),
    participantId: optionalQuery(url, 'participantId'),
    audio,
  });
  const claimDetector = new ClaimDetector();
  const compromiseAdvisor = new CompromiseAdvisor({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    config,
    emit: (event) => sendEvent(webSocket, event),
  });
  const debriefer = new ConversationDebriefer({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    participantId: recorder.participantId,
    config,
    debriefPath: recorder.debriefPath,
    profilePath: recorder.profilePath,
  });
  const speakerLabeler = new SpeakerLabeler({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    labels: parseSpeakerLabels(optionalQuery(url, 'speakerLabels')),
  });
  const emitEvent = (event: ServerEvent) => {
    if (event.type === 'transcript.partial' || event.type === 'transcript.final') {
      const labelled = speakerLabeler.labelTranscript(event);
      if (labelled.mapping) {
        sendEvent(webSocket, labelled.mapping);
      }

      sendEvent(webSocket, labelled.event);

      if (labelled.event.type === 'transcript.final') {
        compromiseAdvisor.recordTranscript(labelled.event);
        debriefer.recordTranscript(labelled.event);
        const claim = claimDetector.detect(labelled.event);
        if (claim) {
          sendEvent(webSocket, claim);
        }
      }

      return;
    }

    sendEvent(webSocket, event);
  };

  emitEvent({
    type: 'session.started',
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    participantId: recorder.participantId,
    audio,
    acceptedBinaryAudio: true,
  });
  compromiseAdvisor.start();

  const transcriber = createDeepgramTranscriber(
    config,
    {
      sessionId: recorder.sessionId,
      streamId: recorder.streamId,
      audio,
    },
    emitEvent,
  );
  let ending: Promise<void> | null = null;
  const finishConnection = (sendEnded: boolean) => {
    ending ??= endSession({
      webSocket,
      recorder,
      transcriber,
      compromiseAdvisor,
      debriefer,
      sendEnded,
    });
    return ending;
  };

  webSocket.on('message', (data, isBinary) => {
    void handleMessage(
      webSocket,
      recorder,
      transcriber,
      () => finishConnection(true),
      data,
      isBinary,
    );
  });

  webSocket.on('close', () => {
    void finishConnection(false).catch(() => undefined);
  });

  webSocket.on('error', () => {
    void finishConnection(false).catch(() => undefined);
  });
}

async function handleMessage(
  webSocket: WebSocket,
  recorder: AudioStreamRecorder,
  transcriber: Transcriber,
  endSession: () => Promise<void>,
  data: WebSocket.RawData,
  isBinary: boolean,
): Promise<void> {
  try {
    if (isBinary) {
      const audioChunk = rawDataToBuffer(data);
      transcriber.sendAudio(audioChunk);
      const snapshot = await recorder.writeChunk(audioChunk);
      sendEvent(webSocket, {
        type: 'audio.ack',
        sessionId: snapshot.sessionId,
        streamId: snapshot.streamId,
        bytesReceived: snapshot.bytesReceived,
        chunksReceived: snapshot.chunksReceived,
      });
      return;
    }

    await handleControlMessage(
      webSocket,
      recorder,
      endSession,
      data.toString('utf8'),
    );
  } catch (error) {
    sendError(webSocket, error);
  }
}

async function handleControlMessage(
  webSocket: WebSocket,
  recorder: AudioStreamRecorder,
  endSession: () => Promise<void>,
  payload: string,
): Promise<void> {
  const message = parseClientControlMessage(payload);

  switch (message.type) {
    case 'session.start':
      sendEvent(webSocket, {
        type: 'session.started',
        sessionId: recorder.sessionId,
        streamId: recorder.streamId,
        participantId: recorder.participantId,
        audio: message.audio ?? DEFAULT_AUDIO,
        acceptedBinaryAudio: true,
      });
      return;
    case 'audio.commit':
      await recorder.writeMetadata('open');
      sendAudioCommitted(webSocket, recorder);
      return;
    case 'session.stop':
      await endSession();
      return;
    default:
      assertNever(message);
  }
}

async function endSession(options: {
  webSocket: WebSocket;
  recorder: AudioStreamRecorder;
  transcriber: Transcriber;
  compromiseAdvisor: CompromiseAdvisor;
  debriefer: ConversationDebriefer;
  sendEnded: boolean;
}): Promise<void> {
  options.compromiseAdvisor.close();
  options.transcriber.close();
  const snapshot = await options.recorder.close();
  const debrief = await options.debriefer.finish(snapshot);

  if (options.sendEnded) {
    sendEvent(options.webSocket, {
      type: 'session.ended',
      sessionId: snapshot.sessionId,
      streamId: snapshot.streamId,
      participantId: snapshot.participantId,
      bytesReceived: snapshot.bytesReceived,
      chunksReceived: snapshot.chunksReceived,
      storagePath: snapshot.filePath,
      debriefStoragePath: debrief.debriefPath,
      profileStoragePath: debrief.profilePath,
      debriefStatus: debrief.status,
    });
    options.webSocket.close(1000, 'session stopped');
  }
}

function sendAudioCommitted(
  webSocket: WebSocket,
  recorder: AudioStreamRecorder,
): void {
  const snapshot = recorder.snapshot();
  sendEvent(webSocket, {
    type: 'audio.committed',
    sessionId: snapshot.sessionId,
    streamId: snapshot.streamId,
    bytesReceived: snapshot.bytesReceived,
    chunksReceived: snapshot.chunksReceived,
  });
}

function sendEvent(webSocket: WebSocket, event: ServerEvent): void {
  if (webSocket.readyState === WebSocket.OPEN) {
    webSocket.send(serializeServerEvent(event));
  }
}

function sendError(webSocket: WebSocket, error: unknown): void {
  const event: ServerEvent =
    error instanceof ZodError
      ? {
          type: 'error',
          code: 'invalid_control_message',
          message: error.issues.map((issue) => issue.message).join('; '),
        }
      : {
          type: 'error',
          code: 'audio_ingestion_error',
          message: error instanceof Error ? error.message : 'Unknown audio ingestion error',
        };

  sendEvent(webSocket, event);
}

function sendJson(
  response: ServerResponse,
  statusCode: number,
  payload: Record<string, unknown>,
): void {
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
  });
  response.end(`${JSON.stringify(payload)}\n`);
}

function rawDataToBuffer(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) {
    return data;
  }

  if (data instanceof ArrayBuffer) {
    return Buffer.from(data);
  }

  return Buffer.concat(data);
}

function audioFormatFromUrl(url: URL): AudioFormat {
  return {
    encoding: parseEncoding(url.searchParams.get('encoding')),
    sampleRateHz: parseOptionalNumber(url.searchParams.get('sampleRateHz')),
    channels: parseOptionalNumber(url.searchParams.get('channels')),
  };
}

function parseEncoding(value: string | null): AudioFormat['encoding'] {
  if (value === 'pcm16' || value === 'webm-opus' || value === 'aac') {
    return value;
  }

  return 'unknown';
}

function parseOptionalNumber(value: string | null): number | undefined {
  if (!value) {
    return undefined;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function optionalQuery(url: URL, key: string): string | undefined {
  return url.searchParams.get(key) ?? undefined;
}

function assertNever(value: never): never {
  throw new Error(`Unhandled control message: ${JSON.stringify(value)}`);
}
