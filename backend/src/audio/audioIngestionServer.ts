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
  type RefereeSettings,
  type ServerEvent,
} from '../protocol/messages.js';
import { parseRefereeSettingsFromUrl } from '../referee/refereeSettings.js';
import { SessionStore, type AudioStreamRecorder } from '../sessions/sessionStore.js';
import {
  createDeepgramTranscriber,
  type Transcriber,
} from '../transcription/deepgramTranscriber.js';
import {
  SpeechServiceError,
  synthesizeSpeech,
} from '../speech/elevenLabsSpeechService.js';
import { ClaimDetector } from '../claims/claimDetector.js';
import { createFactCheckService } from '../factChecks/factCheckService.js';
import { CompromiseAdvisor } from '../compromises/compromiseAdvisor.js';
import { ConversationDebriefer } from '../debriefs/conversationDebriefer.js';
import { RoomToneAnalyzer } from '../roomTone/roomToneAnalyzer.js';
import { FallacyDetector } from '../fallacies/fallacyDetector.js';
import {
  createHistoryStore,
  type HistoryStore,
} from '../history/historyStore.js';
import { RefereeInterventionEngine } from '../interventions/refereeInterventionEngine.js';
import { ArgumentRater } from '../ratings/argumentRater.js';
import { parseSpeakerLabels, SpeakerLabeler } from '../speakers/speakerLabeler.js';
import { PcmPitchTracker } from '../speakers/voicePitch.js';
import { InterruptionDetector } from '../interruptions/interruptionDetector.js';

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
  const historyStore = createHistoryStore(config);
  const httpServer = createServer((request, response) => {
    void handleHttpRequest(request, response, historyStore, config);
  });
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
    void handleAudioConnection(webSocket, request, sessionStore, historyStore, config);
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
      await historyStore.close();
    },
    address: () => httpServer.address(),
  };
}

async function handleHttpRequest(
  request: IncomingMessage,
  response: ServerResponse,
  historyStore: HistoryStore,
  config: AppConfig,
): Promise<void> {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);

  if (url.pathname === '/health') {
    sendJson(response, 200, {
      status: 'ok',
      service: 'argumentref-backend',
    });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/v1/sessions') {
    await sendSessionList(response, historyStore, url);
    return;
  }

  if (request.method === 'GET' && url.pathname.startsWith('/v1/sessions/')) {
    await sendSessionDetail(response, historyStore, url);
    return;
  }

  if (request.method === 'POST' && url.pathname === '/v1/speech') {
    await sendSpeech(response, request, config);
    return;
  }

  sendJson(response, 404, {
    error: 'not_found',
    message:
      'Use /health, GET /v1/sessions, GET /v1/sessions/:sessionId, POST /v1/speech, or connect WebSocket clients to /v1/audio.',
  });
}

async function sendSpeech(
  response: ServerResponse,
  request: IncomingMessage,
  config: AppConfig,
): Promise<void> {
  try {
    const payload = await readJsonBody(request, 32_768);
    const speech = await synthesizeSpeech(config, payload);
    response.writeHead(200, {
      'content-type': speech.contentType,
      'cache-control': 'no-store',
      'x-voice-id': speech.voiceId,
      'x-model-id': speech.modelId,
      'x-output-format': speech.outputFormat,
    });
    response.end(speech.audio);
  } catch (error) {
    if (error instanceof SpeechServiceError) {
      sendJson(response, error.statusCode, {
        error: error.code,
        message: error.message,
      });
      return;
    }

    if (error instanceof ZodError) {
      sendJson(response, 400, {
        error: 'invalid_speech_request',
        message: error.issues.map((issue) => issue.message).join('; '),
      });
      return;
    }

    sendJson(response, 400, {
      error: 'invalid_speech_request',
      message:
        error instanceof Error ? error.message : 'Failed to read speech request.',
    });
  }
}

async function sendSessionList(
  response: ServerResponse,
  historyStore: HistoryStore,
  url: URL,
): Promise<void> {
  if (!historyStore.isEnabled()) {
    sendJson(response, 503, {
      error: 'history_disabled',
      message: 'Set DATABASE_URL on the backend to enable session history.',
    });
    return;
  }

  try {
    const limit = parseLimit(url.searchParams.get('limit'));
    const sessions = await historyStore.listSessions(limit);
    sendJson(response, 200, {
      sessions,
      limit,
    });
  } catch (error) {
    sendJson(response, 500, {
      error: 'history_query_failed',
      message: error instanceof Error ? error.message : 'Failed to query session history.',
    });
  }
}

async function sendSessionDetail(
  response: ServerResponse,
  historyStore: HistoryStore,
  url: URL,
): Promise<void> {
  if (!historyStore.isEnabled()) {
    sendJson(response, 503, {
      error: 'history_disabled',
      message: 'Set DATABASE_URL on the backend to enable session history.',
    });
    return;
  }

  const sessionId = decodeURIComponent(url.pathname.slice('/v1/sessions/'.length));
  if (!sessionId) {
    sendJson(response, 400, {
      error: 'invalid_session_id',
      message: 'Session ID is required.',
    });
    return;
  }

  try {
    const session = await historyStore.getSession(sessionId);
    if (!session) {
      sendJson(response, 404, {
        error: 'session_not_found',
        message: `No session history found for ${sessionId}.`,
      });
      return;
    }

    sendJson(response, 200, {
      session,
    });
  } catch (error) {
    sendJson(response, 500, {
      error: 'history_query_failed',
      message: error instanceof Error ? error.message : 'Failed to query session history.',
    });
  }
}

async function handleAudioConnection(
  webSocket: WebSocket,
  request: IncomingMessage,
  sessionStore: SessionStore,
  historyStore: HistoryStore,
  config: AppConfig,
): Promise<void> {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  const audio = audioFormatFromUrl(url);
  const pitchTracker = new PcmPitchTracker(audio);
  const refereeSettings = parseRefereeSettingsFromUrl(url);
  const recorder = await sessionStore.createAudioStream({
    sessionId: optionalQuery(url, 'sessionId'),
    participantId: optionalQuery(url, 'participantId'),
    audio,
  });
  const claimDetector = new ClaimDetector();
  const factCheckService = createFactCheckService(config);
  const interventionEngine = new RefereeInterventionEngine({
    config,
    settings: refereeSettings,
  });
  const sendAndRecordClientEvent = (event: ServerEvent) => {
    sendEvent(webSocket, event);
    recordHistoryEvent(historyStore, event);
  };
  const emitClientEvent = (event: ServerEvent) => {
    sendAndRecordClientEvent(event);

    const intervention = interventionEngine.observe(event);
    if (intervention) {
      sendAndRecordClientEvent(intervention);
    }
  };
  const fallacyDetector = new FallacyDetector({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    config,
    emit: emitClientEvent,
  });
  const argumentRater = new ArgumentRater({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    config,
    emit: emitClientEvent,
  });
  const compromiseAdvisor = new CompromiseAdvisor({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    config,
    emit: emitClientEvent,
  });
  const roomToneAnalyzer = new RoomToneAnalyzer({
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    config,
    emit: (event) => sendEvent(webSocket, event),
  });
  const interruptionDetector = new InterruptionDetector();
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
      const labelled = speakerLabeler.labelTranscript(event, {
        pitchHz: pitchTracker.pitchForSegment(event.startMs, event.endMs),
      });
      if (labelled.mapping) {
        emitClientEvent(labelled.mapping);
      }

      logTranscript(labelled.event);
      emitClientEvent(labelled.event);

      if (labelled.event.type === 'transcript.final') {
        const interruption = interruptionDetector.recordTranscript(labelled.event);
        if (interruption) {
          sendEvent(webSocket, interruption);
        }

        roomToneAnalyzer.recordTranscript(labelled.event);
        fallacyDetector.recordTranscript(labelled.event);
        argumentRater.recordTranscript(labelled.event);
        compromiseAdvisor.recordTranscript(labelled.event);
        debriefer.recordTranscript(labelled.event);
        const claim = claimDetector.detect(labelled.event);
        if (claim) {
          emitClientEvent(claim);
          factCheckService.checkClaim(claim, emitClientEvent);
        }
      }

      return;
    }

    emitClientEvent(event);
  };

  emitEvent({
    type: 'session.started',
    sessionId: recorder.sessionId,
    streamId: recorder.streamId,
    participantId: recorder.participantId,
    audio,
    acceptedBinaryAudio: true,
    refereeSettings,
  });
  compromiseAdvisor.start();
  roomToneAnalyzer.start();
  fallacyDetector.start();
  argumentRater.start();

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
      fallacyDetector,
      argumentRater,
      compromiseAdvisor,
      roomToneAnalyzer,
      debriefer,
      historyStore,
      sendEnded,
    });
    return ending;
  };

  webSocket.on('message', (data, isBinary) => {
    void handleMessage(
      webSocket,
      recorder,
      transcriber,
      refereeSettings,
      pitchTracker,
      speakerLabeler,
      emitEvent,
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
  refereeSettings: RefereeSettings,
  pitchTracker: PcmPitchTracker,
  speakerLabeler: SpeakerLabeler,
  emitEvent: (event: ServerEvent) => void,
  endSession: () => Promise<void>,
  data: WebSocket.RawData,
  isBinary: boolean,
): Promise<void> {
  try {
    if (isBinary) {
      const audioChunk = rawDataToBuffer(data);
      pitchTracker.ingest(audioChunk);
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
      refereeSettings,
      pitchTracker,
      speakerLabeler,
      emitEvent,
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
  refereeSettings: RefereeSettings,
  pitchTracker: PcmPitchTracker,
  speakerLabeler: SpeakerLabeler,
  emitEvent: (event: ServerEvent) => void,
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
        refereeSettings,
      });
      return;
    case 'audio.commit':
      await recorder.writeMetadata('open');
      sendAudioCommitted(webSocket, recorder);
      return;
    case 'speaker.calibration.start':
      pitchTracker.startCalibration(message.speakerLabel);
      return;
    case 'speaker.calibration.stop': {
      const profile = pitchTracker.stopCalibration(message.speakerLabel);
      if (profile) {
        speakerLabeler.recordVoiceProfile(profile);
        emitEvent({
          type: 'speaker.mapped',
          sessionId: recorder.sessionId,
          streamId: recorder.streamId,
          speaker: 'speaker_unknown',
          speakerLabel: profile.label,
          source: 'pitch_calibration',
        });
      }
      return;
    }
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
  fallacyDetector: FallacyDetector;
  argumentRater: ArgumentRater;
  compromiseAdvisor: CompromiseAdvisor;
  roomToneAnalyzer: RoomToneAnalyzer;
  debriefer: ConversationDebriefer;
  historyStore: HistoryStore;
  sendEnded: boolean;
}): Promise<void> {
  options.fallacyDetector.close();
  options.argumentRater.close();
  options.compromiseAdvisor.close();
  options.roomToneAnalyzer.close();
  options.transcriber.close();
  const snapshot = await options.recorder.close();
  const debrief = await options.debriefer.finish(snapshot);
  const endedEvent: ServerEvent = {
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
  };

  await recordHistoryEvent(options.historyStore, endedEvent);

  if (options.sendEnded) {
    sendEvent(options.webSocket, endedEvent);
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

function recordHistoryEvent(
  historyStore: HistoryStore,
  event: ServerEvent,
): Promise<void> {
  return historyStore.recordEvent(event).catch((error: unknown) => {
    console.warn(
      `History write failed for ${event.type}: ${
        error instanceof Error ? error.message : 'unknown error'
      }`,
    );
  });
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

function readJsonBody(
  request: IncomingMessage,
  maxBytes: number,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;

    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      callback();
    };

    request.on('data', (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > maxBytes) {
        finish(() => {
          reject(new Error(`Request body must be ${maxBytes} bytes or fewer.`));
        });
        request.destroy();
        return;
      }

      chunks.push(chunk);
    });

    request.on('end', () => {
      finish(() => {
        try {
          const raw = Buffer.concat(chunks).toString('utf8');
          resolve(raw ? JSON.parse(raw) : {});
        } catch {
          reject(new Error('Request body must be valid JSON.'));
        }
      });
    });

    request.on('error', (error) => {
      finish(() => reject(error));
    });
  });
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

function logTranscript(
  event: Extract<ServerEvent, { type: 'transcript.partial' | 'transcript.final' }>,
): void {
  const user = event.speakerLabel
    ? `${event.speakerLabel} (${event.speaker})`
    : event.speaker;

  console.log(`[${event.type}] ${user}: ${event.text}`);
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

function parseLimit(value: string | null): number {
  if (!value) {
    return 20;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    return 20;
  }

  return Math.min(parsed, 100);
}

function optionalQuery(url: URL, key: string): string | undefined {
  return url.searchParams.get(key) ?? undefined;
}

function assertNever(value: never): never {
  throw new Error(`Unhandled control message: ${JSON.stringify(value)}`);
}
