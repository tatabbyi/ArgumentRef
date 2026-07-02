import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import WebSocket from 'ws';
import type { ServerEvent } from '../src/protocol/messages.js';

interface CliOptions {
  url: string;
  filePath: string;
  sessionId: string;
  participantId: string;
  encoding: string;
  sampleRateHz?: number;
  channels?: number;
  chunkBytes: number;
  delayMs: number;
  finalWaitMs: number;
}

const options = parseArgs(process.argv.slice(2));
const audio = await readFile(options.filePath);
const websocketUrl = buildWebSocketUrl(options);

console.log(`Connecting to ${websocketUrl}`);
console.log(`Streaming ${audio.length} bytes from ${options.filePath}`);

const socket = new WebSocket(websocketUrl);
let sawTranscript = false;

socket.on('open', () => {
  void streamAudio(socket, audio, options);
});

socket.on('message', (data) => {
  const event = JSON.parse(data.toString()) as ServerEvent;
  printEvent(event);

  if (event.type === 'transcript.partial' || event.type === 'transcript.final') {
    sawTranscript = true;
  }

  if (event.type === 'session.ended') {
    socket.close(1000, 'remote audio test complete');
  }
});

socket.on('error', (error) => {
  console.error(`WebSocket error: ${error.message}`);
  process.exitCode = 1;
});

socket.on('close', () => {
  if (!sawTranscript) {
    console.warn(
      'No transcript events were received. Check that the file contains clear speech and matches the encoding query parameters.',
    );
  }
});

async function streamAudio(
  socket: WebSocket,
  audio: Buffer,
  options: CliOptions,
): Promise<void> {
  for (let offset = 0; offset < audio.length; offset += options.chunkBytes) {
    const chunk = audio.subarray(offset, offset + options.chunkBytes);
    socket.send(chunk);
    await sleep(options.delayMs);
  }

  await sleep(options.finalWaitMs);
  socket.send(JSON.stringify({ type: 'session.stop' }));
}

function printEvent(event: ServerEvent): void {
  switch (event.type) {
    case 'session.started':
    case 'transcription.connected':
    case 'transcription.disabled':
    case 'transcription.error':
    case 'session.ended':
      console.log(JSON.stringify(event));
      return;
    case 'audio.ack':
      if (event.chunksReceived % 20 === 0 || event.chunksReceived === 1) {
        console.log(JSON.stringify(event));
      }
      return;
    case 'transcript.partial':
    case 'transcript.final':
    case 'claim.detected':
      console.log(
        JSON.stringify({
          type: event.type,
          speaker: event.speaker,
          text: event.text,
          ...('reason' in event ? { reason: event.reason } : {}),
          ...('startMs' in event ? { startMs: event.startMs } : {}),
          ...('endMs' in event ? { endMs: event.endMs } : {}),
        }),
      );
      return;
    case 'audio.committed':
    case 'error':
      console.log(JSON.stringify(event));
      return;
    default:
      assertNever(event);
  }
}

function buildWebSocketUrl(options: CliOptions): string {
  const url = new URL(options.url);
  url.searchParams.set('sessionId', options.sessionId);
  url.searchParams.set('participantId', options.participantId);
  url.searchParams.set('encoding', options.encoding);

  if (options.sampleRateHz) {
    url.searchParams.set('sampleRateHz', String(options.sampleRateHz));
  }

  if (options.channels) {
    url.searchParams.set('channels', String(options.channels));
  }

  return url.toString();
}

function parseArgs(args: string[]): CliOptions {
  const values = new Map<string, string>();

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith('--')) {
      continue;
    }

    const key = arg.slice(2);
    const value = args[index + 1];
    if (!value || value.startsWith('--')) {
      values.set(key, 'true');
      continue;
    }

    values.set(key, value);
    index += 1;
  }

  const filePath = values.get('file');
  if (!filePath) {
    printUsageAndExit();
  }

  return {
    url:
      values.get('url') ??
      'wss://argumentref-backend.onrender.com/v1/audio',
    filePath,
    sessionId: values.get('sessionId') ?? `file-test-${Date.now()}`,
    participantId:
      values.get('participantId') ?? basename(filePath).replace(/\W+/g, '-'),
    encoding: values.get('encoding') ?? 'unknown',
    sampleRateHz: readOptionalNumber(values.get('sampleRateHz')),
    channels: readOptionalNumber(values.get('channels')),
    chunkBytes: readOptionalNumber(values.get('chunkBytes')) ?? 3200,
    delayMs: readOptionalNumber(values.get('delayMs')) ?? 100,
    finalWaitMs: readOptionalNumber(values.get('finalWaitMs')) ?? 3000,
  };
}

function readOptionalNumber(value: string | undefined): number | undefined {
  if (!value) {
    return undefined;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function printUsageAndExit(): never {
  console.error(`Usage:
  npm run test:remote-audio -- --file ./sample.wav

PCM16 example:
  npm run test:remote-audio -- --file ./sample.pcm --encoding pcm16 --sampleRateHz 16000 --channels 1

Options:
  --url <wss-url>              Defaults to Render backend
  --file <path>                Required audio file path
  --encoding <encoding>        unknown | pcm16 | webm-opus | aac
  --sampleRateHz <number>      Required for raw pcm16
  --channels <number>          Required for raw pcm16
  --chunkBytes <number>        Defaults to 3200
  --delayMs <number>           Defaults to 100
`);
  process.exit(1);
}

function assertNever(value: never): never {
  throw new Error(`Unhandled server event: ${JSON.stringify(value)}`);
}
