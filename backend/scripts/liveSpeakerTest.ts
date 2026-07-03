/**
 * Live speaker-detection test harness.
 *
 * Captures your microphone with ffmpeg and runs the exact same pipeline the
 * backend uses for a WebSocket audio stream (audioIngestionServer.ts):
 *
 *   mic PCM16 ──> PcmPitchTracker.ingest()          (pitch per audio frame)
 *            └──> DeepgramTranscriber.sendAudio()   (transcript + diarization)
 *   transcript ─> SpeakerLabeler.labelTranscript()  (maps speaker ids to names)
 *
 * For every transcript segment it prints WHO the pipeline thinks is speaking
 * and WHY: the Deepgram diarization id, the measured pitch of the segment,
 * the distance (in cents) to each calibrated voice profile, and which rule
 * made the decision (pitch match / remembered mapping / first-free label).
 *
 * Usage:
 *   npm run test:speakers -- --speakers "Sean,Ollie"
 *   npm run test:speakers -- --speakers "Sean,Ollie" --no-calibration
 *   npm run test:speakers -- --list-devices
 *   npm run test:speakers -- --speakers "Sean,Ollie" --device 1
 */
import 'dotenv/config';
import { spawn, spawnSync, type ChildProcessByStdio } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { Readable } from 'node:stream';
import { loadConfig } from '../src/config.js';
import { createDeepgramTranscriber } from '../src/transcription/deepgramTranscriber.js';
import { SpeakerLabeler } from '../src/speakers/speakerLabeler.js';
import { PcmPitchTracker, type SpeakerVoiceProfile } from '../src/speakers/voicePitch.js';
import type {
  AudioFormat,
  ServerEvent,
  TranscriptFinalEvent,
  TranscriptPartialEvent,
} from '../src/protocol/messages.js';

// Same thresholds SpeakerLabeler.matchPitch uses (speakerLabeler.ts). Mirrored
// here only to explain its decisions; the actual labelling always comes from
// the real SpeakerLabeler instance.
const PITCH_MATCH_MAX_CENTS = 450;
const PITCH_MATCH_MIN_MARGIN_CENTS = 120;

const SAMPLE_RATE_HZ = 16_000;
const CHUNK_BYTES = 3200; // ~100ms of PCM16 mono @16kHz, same as the app's stream chunks
const CALIBRATION_SECONDS = 6;

const COLORS = ['\x1b[36m', '\x1b[33m', '\x1b[35m', '\x1b[32m', '\x1b[34m', '\x1b[31m'];
const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';

interface CliOptions {
  speakers: string[];
  device: string;
  calibrate: boolean;
  showPartials: boolean;
}

const options = parseArgs(process.argv.slice(2));
const config = loadConfig();

if (!config.deepgramApiKey) {
  console.error('DEEPGRAM_API_KEY is not set. Add it to backend/.env first.');
  process.exit(1);
}

const audio: AudioFormat = {
  encoding: 'pcm16',
  sampleRateHz: SAMPLE_RATE_HZ,
  channels: 1,
};

// --- Assemble the pipeline exactly like handleAudioConnection() does ---
const pitchTracker = new PcmPitchTracker(audio);
const speakerLabeler = new SpeakerLabeler({
  sessionId: 'local-speaker-test',
  streamId: 'mic',
  labels: options.speakers,
});

// Mirror state used only for printing explanations.
const profiles: SpeakerVoiceProfile[] = [];
const knownMappings = new Map<string, string>(); // deepgram speaker id -> label
let calibrating = false;

const transcriber = createDeepgramTranscriber(
  config,
  { sessionId: 'local-speaker-test', streamId: 'mic', audio },
  handleServerEvent,
);

const ffmpeg = startMicCapture(options.device);
let pcmRemainder = Buffer.alloc(0);

ffmpeg.stdout.on('data', (data: Buffer) => {
  pcmRemainder = Buffer.concat([pcmRemainder, data]);
  while (pcmRemainder.length >= CHUNK_BYTES) {
    const chunk = pcmRemainder.subarray(0, CHUNK_BYTES);
    pcmRemainder = pcmRemainder.subarray(CHUNK_BYTES);
    // Same two calls handleMessage() makes for every binary WebSocket frame.
    pitchTracker.ingest(chunk);
    transcriber.sendAudio(chunk);
  }
});

ffmpeg.on('exit', (code) => {
  if (code !== 0 && code !== null) {
    console.error(
      `\nffmpeg exited with code ${code}. If this is a permissions problem, grant your terminal microphone access in System Settings > Privacy & Security > Microphone. Run with --list-devices to check the device index.`,
    );
    process.exit(1);
  }
});

process.on('SIGINT', shutdown);

await main();

async function main(): Promise<void> {
  console.log(`${BOLD}Live speaker-detection test${RESET}`);
  console.log(`Speakers: ${options.speakers.map(colorize).join(', ') || '(none — pass --speakers "A,B")'}`);
  console.log(`Deepgram model: ${config.deepgramModel}, mic device :${options.device}, pcm16 mono @${SAMPLE_RATE_HZ}Hz\n`);

  if (options.calibrate && options.speakers.length > 0) {
    await runCalibration();
  } else {
    console.log(
      `${DIM}Skipping pitch calibration — names will be assigned in first-heard order (query_calibration fallback).${RESET}\n`,
    );
  }

  console.log(`${BOLD}Listening. Talk, swap speakers, and watch the labels. Ctrl+C to stop.${RESET}\n`);
}

async function runCalibration(): Promise<void> {
  console.log(`${BOLD}Calibration${RESET} — each person reads a few sentences so we can learn their pitch.\n`);

  for (const label of options.speakers) {
    await promptEnter(`Press Enter, then ${colorize(label)} speaks for ~${CALIBRATION_SECONDS}s...`);
    // Same calls the server makes for speaker.calibration.start/stop messages.
    pitchTracker.startCalibration(label);
    calibrating = true;
    await promptEnter(`${DIM}Recording ${label}... press Enter when done.${RESET}`);
    calibrating = false;
    const profile = pitchTracker.stopCalibration(label);

    if (!profile) {
      console.log(
        `  ⚠ Not enough voiced audio to build a profile for ${label} (need ≥3 pitched frames). They will fall back to first-heard-order labelling.\n`,
      );
      continue;
    }

    speakerLabeler.recordVoiceProfile(profile);
    profiles.push(profile);
    console.log(
      `  ✓ ${colorize(label)}: median ${profile.medianPitchHz}Hz (range ${profile.minPitchHz}–${profile.maxPitchHz}Hz, ${profile.sampleCount} frames)\n`,
    );
  }
}

function handleServerEvent(event: ServerEvent): void {
  switch (event.type) {
    case 'transcription.connected':
      console.log(`${DIM}[deepgram] connected (diarization on)${RESET}`);
      return;
    case 'transcription.error':
      console.error(`[deepgram] error: ${event.message}`);
      return;
    case 'transcription.disabled':
      console.error(`[deepgram] disabled: ${event.reason}`);
      return;
    case 'speaker.diarization_status':
      console.log(`${DIM}[diarization] ${event.status}: ${event.message}${RESET}`);
      return;
    case 'transcript.partial':
    case 'transcript.final':
      handleTranscript(event);
      return;
    default:
      return;
  }
}

function handleTranscript(event: TranscriptPartialEvent | TranscriptFinalEvent): void {
  if (calibrating) return; // keep calibration prompts readable

  // Exact same call emitEvent() makes in audioIngestionServer.ts.
  const segmentPitchHz = pitchTracker.pitchForSegment(event.startMs, event.endMs);
  const previousLabel = knownMappings.get(event.speaker);
  const { event: labelled, mapping } = speakerLabeler.labelTranscript(event, {
    pitchHz: segmentPitchHz,
  });

  const label = labelled.speakerLabel;
  if (label && event.speaker !== 'speaker_unknown') {
    knownMappings.set(event.speaker, label);
  }

  const who = label ? `${colorize(label)}` : `${DIM}<unlabelled>${RESET}`;
  const marker = event.type === 'transcript.final' ? '●' : `${DIM}○${RESET}`;
  console.log(`${marker} ${who} ${DIM}(${event.speaker})${RESET}: ${labelled.text}`);

  if (event.type === 'transcript.final' || options.showPartials) {
    for (const line of explainDecision(event.speaker, segmentPitchHz, label, previousLabel, mapping?.source)) {
      console.log(`${DIM}    ${line}${RESET}`);
    }
  }
}

function explainDecision(
  speaker: string,
  pitchHz: number | undefined,
  label: string | undefined,
  previousLabel: string | undefined,
  newMappingSource: string | undefined,
): string[] {
  const lines: string[] = [];

  // 1. What the pitch evidence says (mirrors SpeakerLabeler.matchPitch).
  if (pitchHz === undefined) {
    lines.push('pitch: no usable pitch measured for this segment (too quiet or unvoiced)');
  } else if (profiles.length === 0) {
    lines.push(`pitch: measured ${pitchHz}Hz, but no calibrated profiles to compare against`);
  } else {
    const ranked = profiles
      .map((profile) => ({
        label: profile.label,
        medianPitchHz: profile.medianPitchHz,
        cents: Math.round(Math.abs(1200 * Math.log2(pitchHz / profile.medianPitchHz))),
      }))
      .sort((a, b) => a.cents - b.cents);

    lines.push(
      `pitch: segment ≈ ${pitchHz}Hz — ${ranked
        .map((r) => `${r.label} ${r.cents}¢ away (calibrated ${r.medianPitchHz}Hz)`)
        .join(', ')}`,
    );

    const best = ranked[0];
    const margin = ranked[1] ? ranked[1].cents - best.cents : Infinity;
    if (best.cents > PITCH_MATCH_MAX_CENTS) {
      lines.push(
        `pitch verdict: no match — closest profile (${best.label}) is ${best.cents}¢ away, over the ${PITCH_MATCH_MAX_CENTS}¢ limit`,
      );
    } else if (margin < PITCH_MATCH_MIN_MARGIN_CENTS) {
      lines.push(
        `pitch verdict: ambiguous — ${best.label} and ${ranked[1].label} are only ${margin}¢ apart (needs ≥${PITCH_MATCH_MIN_MARGIN_CENTS}¢ separation)`,
      );
    } else {
      lines.push(`pitch verdict: matches ${best.label} (${best.cents}¢ ≤ ${PITCH_MATCH_MAX_CENTS}¢, margin ${margin === Infinity ? 'n/a' : `${margin}¢`})`);
    }
  }

  // 2. What the labeler actually decided.
  if (!label) {
    lines.push(
      speaker === 'speaker_unknown'
        ? 'decision: UNLABELLED — Deepgram has not assigned a speaker id yet and pitch could not identify anyone'
        : 'decision: UNLABELLED — no free names left to assign',
    );
  } else if (newMappingSource === 'pitch_calibration') {
    lines.push(
      `decision: ${label} — NEW mapping from pitch calibration (${speaker} now remembered as ${label})`,
    );
  } else if (newMappingSource === 'query_calibration') {
    lines.push(
      `decision: ${label} — NEW mapping, first-heard order: ${speaker} is a new diarization id, took the next unused name`,
    );
  } else if (previousLabel === label) {
    lines.push(
      `decision: ${label} — remembered: ${speaker} was already mapped to ${label} earlier in the session`,
    );
  } else {
    lines.push(`decision: ${label} — matched by pitch against calibrated profile`);
  }

  return lines;
}

// --- mic capture -----------------------------------------------------------

function startMicCapture(device: string): ChildProcessByStdio<null, Readable, null> {
  const child = spawn(
    'ffmpeg',
    [
      '-hide_banner',
      '-loglevel', 'error',
      '-f', 'avfoundation',
      '-i', `:${device}`,
      '-ac', '1',
      '-ar', String(SAMPLE_RATE_HZ),
      '-f', 's16le',
      'pipe:1',
    ],
    { stdio: ['ignore', 'pipe', 'inherit'] },
  );
  return child;
}

function listDevicesAndExit(): never {
  const result = spawnSync('ffmpeg', ['-f', 'avfoundation', '-list_devices', 'true', '-i', ''], {
    encoding: 'utf8',
  });
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  const audioSection = output
    .slice(output.indexOf('audio devices'))
    .split('\n')
    .filter((line) => !line.includes('Error opening input'))
    .join('\n');
  console.log(audioSection || output);
  console.log('\nPass the audio device index with --device <n> (default 0).');
  process.exit(0);
}

// --- plumbing ---------------------------------------------------------------

function shutdown(): void {
  console.log('\nStopping...');
  transcriber.close();
  // SIGKILL so ffmpeg doesn't spray broken-pipe errors into the terminal after we exit.
  ffmpeg.kill('SIGKILL');
  process.exit(0);
}

function promptEnter(message: string): Promise<void> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${message} `, () => {
      rl.close();
      resolve();
    });
  });
}

function colorize(label: string): string {
  const index = options.speakers.indexOf(label);
  const color = COLORS[(index >= 0 ? index : options.speakers.length) % COLORS.length];
  return `${color}${BOLD}${label}${RESET}`;
}

function parseArgs(args: string[]): CliOptions {
  const values = new Map<string, string>();

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith('--')) continue;

    const key = arg.slice(2);
    const value = args[index + 1];
    if (!value || value.startsWith('--')) {
      values.set(key, 'true');
      continue;
    }
    values.set(key, value);
    index += 1;
  }

  if (values.has('list-devices')) {
    listDevicesAndExit();
  }

  if (values.has('help')) {
    console.log(`Usage:
  npm run test:speakers -- --speakers "Sean,Ollie"

Options:
  --speakers <a,b>    Names to assign (max 8), in calibration order
  --no-calibration    Skip pitch calibration; names assigned in first-heard order
  --device <n>        avfoundation audio device index (default 0, see --list-devices)
  --partials          Print decision reasoning for partial transcripts too
  --list-devices      List available microphones and exit`);
    process.exit(0);
  }

  return {
    speakers: (values.get('speakers') ?? '')
      .split(',')
      .map((label) => label.trim())
      .filter(Boolean)
      .slice(0, 8),
    device: values.get('device') ?? '0',
    calibrate: !values.has('no-calibration'),
    showPartials: values.has('partials'),
  };
}
