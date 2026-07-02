import { WebSocket } from 'ws';
import type { AppConfig } from '../config.js';
import type {
  AudioFormat,
  ServerEvent,
  SpeakerDiarizationStatus,
  TranscriptWord,
} from '../protocol/messages.js';

const DEEPGRAM_DIARIZE_MODEL = 'latest';

export interface TranscriptionContext {
  sessionId: string;
  streamId: string;
  audio: AudioFormat;
}

export interface Transcriber {
  sendAudio(chunk: Buffer): void;
  close(): void;
}

export type EmitTranscriptionEvent = (event: ServerEvent) => void;

export function createDeepgramTranscriber(
  config: AppConfig,
  context: TranscriptionContext,
  emit: EmitTranscriptionEvent,
): Transcriber {
  if (!config.deepgramApiKey) {
    emit({
      type: 'transcription.disabled',
      reason: 'DEEPGRAM_API_KEY is not configured on the backend.',
    });
    return new NoopTranscriber();
  }

  return new DeepgramTranscriber(config, context, emit);
}

class NoopTranscriber implements Transcriber {
  sendAudio(): void {
    return;
  }

  close(): void {
    return;
  }
}

class DeepgramTranscriber implements Transcriber {
  private readonly websocket: WebSocket;
  private readonly pendingAudio: Buffer[] = [];
  private readonly keepAlive: NodeJS.Timeout;
  private isOpen = false;
  private isClosed = false;
  private lastDiarizationStatusKey?: string;

  constructor(
    private readonly config: AppConfig,
    private readonly context: TranscriptionContext,
    private readonly emit: EmitTranscriptionEvent,
  ) {
    this.websocket = new WebSocket(buildDeepgramUrl(config, context.audio), {
      headers: {
        Authorization: `Token ${config.deepgramApiKey}`,
      },
    });

    this.websocket.on('open', () => {
      this.isOpen = true;
      this.emit({
        type: 'transcription.connected',
        provider: 'deepgram',
        sessionId: this.context.sessionId,
        streamId: this.context.streamId,
        model: this.config.deepgramModel,
        language: this.config.deepgramLanguage,
        diarization: {
          requested: true,
          model: DEEPGRAM_DIARIZE_MODEL,
        },
      });
      this.flushPendingAudio();
    });

    this.websocket.on('message', (data) => {
      this.handleDeepgramMessage(data.toString());
    });

    this.websocket.on('error', (error) => {
      this.emit({
        type: 'transcription.error',
        provider: 'deepgram',
        message: error.message,
      });
    });

    this.websocket.on('close', (code, reason) => {
      this.isClosed = true;

      if (code !== 1000 && code !== 1005) {
        this.emit({
          type: 'transcription.error',
          provider: 'deepgram',
          message: `Deepgram connection closed with code ${code}: ${reason.toString()}`,
        });
      }
    });

    this.keepAlive = setInterval(() => {
      if (this.websocket.readyState === WebSocket.OPEN) {
        this.websocket.send(JSON.stringify({ type: 'KeepAlive' }));
      }
    }, 8000);
  }

  sendAudio(chunk: Buffer): void {
    if (this.isClosed) {
      return;
    }

    if (this.websocket.readyState === WebSocket.OPEN) {
      this.websocket.send(chunk);
      return;
    }

    if (!this.isOpen && this.pendingAudio.length < 256) {
      this.pendingAudio.push(chunk);
    }
  }

  close(): void {
    clearInterval(this.keepAlive);

    if (
      this.websocket.readyState === WebSocket.OPEN ||
      this.websocket.readyState === WebSocket.CONNECTING
    ) {
      this.websocket.close(1000, 'session ended');
    }
  }

  private flushPendingAudio(): void {
    while (this.pendingAudio.length > 0) {
      const chunk = this.pendingAudio.shift();
      if (chunk) {
        this.websocket.send(chunk);
      }
    }
  }

  private handleDeepgramMessage(payload: string): void {
    const message = parseDeepgramMessage(payload);
    if (!message || message.type !== 'Results') {
      return;
    }

    const alternative = message.channel?.alternatives?.[0];
    if (!alternative) {
      return;
    }

    this.emitDiarizationStatus(alternative.words ?? []);

    const transcript = alternative.transcript?.trim();
    if (!transcript) {
      return;
    }

    const words = (alternative.words ?? []).map(toTranscriptWord);
    const segments = segmentWordsBySpeaker(words, transcript);
    const eventType = message.is_final ? 'transcript.final' : 'transcript.partial';

    for (const segment of segments) {
      this.emit({
        type: eventType,
        provider: 'deepgram',
        sessionId: this.context.sessionId,
        streamId: this.context.streamId,
        speaker: segment.speaker,
        text: segment.text,
        startMs: segment.startMs,
        endMs: segment.endMs,
        confidence: alternative.confidence,
        words: segment.words,
      });
    }
  }

  private emitDiarizationStatus(words: DeepgramWord[]): void {
    const summary = summarizeDeepgramDiarization(words);
    const statusKey = `${summary.status}:${summary.speakers.join(',')}`;

    if (statusKey === this.lastDiarizationStatusKey) {
      return;
    }

    this.lastDiarizationStatusKey = statusKey;

    this.emit({
      type: 'speaker.diarization_status',
      provider: 'deepgram',
      sessionId: this.context.sessionId,
      streamId: this.context.streamId,
      ...summary,
    });
  }
}

function buildDeepgramUrl(config: AppConfig, audio: AudioFormat): string {
  const url = new URL('wss://api.deepgram.com/v1/listen');
  url.searchParams.set('model', config.deepgramModel);
  url.searchParams.set('language', config.deepgramLanguage);
  url.searchParams.set('interim_results', 'true');
  url.searchParams.set('punctuate', 'true');
  url.searchParams.set('smart_format', 'true');
  url.searchParams.set('diarize_model', DEEPGRAM_DIARIZE_MODEL);
  url.searchParams.set('endpointing', '300');

  if (audio.channels) {
    url.searchParams.set('channels', String(audio.channels));
  }

  if (audio.sampleRateHz) {
    url.searchParams.set('sample_rate', String(audio.sampleRateHz));
  }

  const encoding = deepgramEncoding(audio.encoding);
  if (encoding) {
    url.searchParams.set('encoding', encoding);
  }

  return url.toString();
}

function deepgramEncoding(encoding: AudioFormat['encoding']): string | undefined {
  if (encoding === 'pcm16') {
    return 'linear16';
  }

  return undefined;
}

interface DeepgramResultsMessage {
  type?: string;
  is_final?: boolean;
  channel?: {
    alternatives?: Array<{
      transcript?: string;
      confidence?: number;
      words?: DeepgramWord[];
    }>;
  };
}

export interface DeepgramWord {
  word?: string;
  punctuated_word?: string;
  start?: number;
  end?: number;
  confidence?: number;
  speaker?: number;
}

export interface DeepgramDiarizationSummary {
  status: SpeakerDiarizationStatus;
  speakers: string[];
  totalWords: number;
  wordsWithSpeaker: number;
  message: string;
}

interface TranscriptSegment {
  speaker: string;
  text: string;
  startMs?: number;
  endMs?: number;
  words: TranscriptWord[];
}

function parseDeepgramMessage(payload: string): DeepgramResultsMessage | null {
  try {
    return JSON.parse(payload) as DeepgramResultsMessage;
  } catch {
    return null;
  }
}

function toTranscriptWord(word: DeepgramWord): TranscriptWord {
  return {
    word: word.punctuated_word ?? word.word ?? '',
    speaker:
      typeof word.speaker === 'number'
        ? `speaker_${word.speaker}`
        : 'speaker_unknown',
    startMs: secondsToMs(word.start),
    endMs: secondsToMs(word.end),
    confidence: word.confidence,
  };
}

export function summarizeDeepgramDiarization(
  words: DeepgramWord[],
): DeepgramDiarizationSummary {
  const populatedWords = words.filter((word) =>
    Boolean((word.word ?? word.punctuated_word)?.trim()),
  );
  const speakers = [
    ...new Set(
      populatedWords
        .filter((word) => typeof word.speaker === 'number')
        .map((word) => `speaker_${word.speaker}`),
    ),
  ].sort();
  const wordsWithSpeaker = populatedWords.filter(
    (word) => typeof word.speaker === 'number',
  ).length;

  if (populatedWords.length === 0) {
    return {
      status: 'no_words',
      speakers,
      totalWords: 0,
      wordsWithSpeaker,
      message: 'Deepgram has not returned word-level transcript data yet.',
    };
  }

  if (wordsWithSpeaker === 0) {
    return {
      status: 'missing_speaker_labels',
      speakers,
      totalWords: populatedWords.length,
      wordsWithSpeaker,
      message:
        'Deepgram returned words without speaker labels. Check the audio format and diarization request.',
    };
  }

  if (speakers.length < 2) {
    return {
      status: 'single_speaker',
      speakers,
      totalWords: populatedWords.length,
      wordsWithSpeaker,
      message:
        'Deepgram currently sees one speaker. Use longer, clean two-person audio to test diarization.',
    };
  }

  return {
    status: 'multiple_speakers',
    speakers,
    totalWords: populatedWords.length,
    wordsWithSpeaker,
    message: 'Deepgram is returning multiple speaker labels.',
  };
}

function segmentWordsBySpeaker(
  words: TranscriptWord[],
  fallbackText: string,
): TranscriptSegment[] {
  const populatedWords = words.filter((word) => word.word.length > 0);

  if (populatedWords.length === 0) {
    return [
      {
        speaker: 'speaker_unknown',
        text: fallbackText,
        words: [],
      },
    ];
  }

  const segments: TranscriptSegment[] = [];

  for (const word of populatedWords) {
    const previous = segments.at(-1);

    if (!previous || previous.speaker !== word.speaker) {
      segments.push({
        speaker: word.speaker,
        text: word.word,
        startMs: word.startMs,
        endMs: word.endMs,
        words: [word],
      });
      continue;
    }

    previous.text = `${previous.text} ${word.word}`;
    previous.endMs = word.endMs ?? previous.endMs;
    previous.words.push(word);
  }

  return segments;
}

function secondsToMs(value: number | undefined): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return undefined;
  }

  return Math.round(value * 1000);
}
