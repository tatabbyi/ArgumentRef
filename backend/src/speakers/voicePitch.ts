import type { AudioFormat } from '../protocol/messages.js';

export interface SpeakerVoiceProfile {
  label: string;
  medianPitchHz: number;
  minPitchHz: number;
  maxPitchHz: number;
  sampleCount: number;
  recordedAt: string;
}

export interface PitchEstimate {
  pitchHz: number;
  rms: number;
  clarity: number;
}

interface PitchFrame {
  startMs: number;
  endMs: number;
  pitchHz: number;
}

interface ActiveCalibration {
  label: string;
  samples: number[];
}

const MIN_RMS = 0.012;
const MIN_PITCH_HZ = 70;
const MAX_PITCH_HZ = 450;
const MAX_TRACKED_FRAMES = 2400;

export class PcmPitchTracker {
  private readonly profiles = new Map<string, SpeakerVoiceProfile>();
  private readonly frames: PitchFrame[] = [];
  private totalSamples = 0;
  private activeCalibration?: ActiveCalibration;

  constructor(private readonly audio: AudioFormat) {}

  get voiceProfiles(): SpeakerVoiceProfile[] {
    return [...this.profiles.values()];
  }

  startCalibration(label: string): void {
    const cleaned = label.trim();
    if (!cleaned) return;

    this.activeCalibration = {
      label: cleaned,
      samples: [],
    };
  }

  stopCalibration(label?: string): SpeakerVoiceProfile | null {
    const active = this.activeCalibration;
    if (!active) return null;

    this.activeCalibration = undefined;
    if (label && normalizeLabel(label) !== normalizeLabel(active.label)) {
      return null;
    }
    if (active.samples.length < 3) {
      return null;
    }

    const ordered = [...active.samples].sort((a, b) => a - b);
    const profile: SpeakerVoiceProfile = {
      label: active.label,
      medianPitchHz: roundHz(median(ordered)),
      minPitchHz: roundHz(ordered[0]),
      maxPitchHz: roundHz(ordered[ordered.length - 1]),
      sampleCount: ordered.length,
      recordedAt: new Date().toISOString(),
    };

    this.profiles.set(normalizeLabel(profile.label), profile);
    return profile;
  }

  ingest(chunk: Buffer): void {
    const sampleRateHz = this.audio.sampleRateHz;
    const channels = this.audio.channels ?? 1;
    const sampleCount =
      this.audio.encoding === 'pcm16' && sampleRateHz
        ? Math.floor(chunk.length / 2 / channels)
        : 0;
    const startMs = sampleRateHz ? samplesToMs(this.totalSamples, sampleRateHz) : 0;

    if (sampleCount > 0) {
      this.totalSamples += sampleCount;
    }

    if (this.audio.encoding !== 'pcm16' || !sampleRateHz || sampleCount === 0) {
      return;
    }

    const estimate = estimatePcm16PitchHz(chunk, {
      sampleRateHz,
      channels,
    });
    if (!estimate) {
      return;
    }

    const frame: PitchFrame = {
      startMs,
      endMs: samplesToMs(this.totalSamples, sampleRateHz),
      pitchHz: estimate.pitchHz,
    };
    this.frames.push(frame);
    if (this.frames.length > MAX_TRACKED_FRAMES) {
      this.frames.splice(0, this.frames.length - MAX_TRACKED_FRAMES);
    }

    if (this.activeCalibration) {
      this.activeCalibration.samples.push(frame.pitchHz);
    }
  }

  pitchForSegment(startMs?: number, endMs?: number): number | undefined {
    if (this.frames.length === 0) return undefined;

    const selected =
      typeof startMs === 'number' && typeof endMs === 'number' && endMs > startMs
        ? this.frames.filter(
            (frame) => frame.endMs >= startMs && frame.startMs <= endMs,
          )
        : this.recentFrames();
    const usable = selected.length > 0 ? selected : this.recentFrames();
    if (usable.length === 0) return undefined;

    return roundHz(median(usable.map((frame) => frame.pitchHz)));
  }

  private recentFrames(): PitchFrame[] {
    const latest = this.frames.at(-1);
    if (!latest) return [];

    const sinceMs = latest.endMs - 2500;
    return this.frames.filter((frame) => frame.endMs >= sinceMs);
  }
}

export function estimatePcm16PitchHz(
  chunk: Buffer,
  options: {
    sampleRateHz: number;
    channels?: number;
    minPitchHz?: number;
    maxPitchHz?: number;
  },
): PitchEstimate | null {
  const channels = options.channels ?? 1;
  if (options.sampleRateHz <= 0 || channels <= 0) return null;

  const samples = pcm16ToMono(chunk, channels);
  if (samples.length < Math.floor(options.sampleRateHz * 0.03)) {
    return null;
  }

  let mean = 0;
  let sumSquares = 0;
  for (const sample of samples) {
    mean += sample;
    sumSquares += sample * sample;
  }
  mean /= samples.length;

  const rms = Math.sqrt(sumSquares / samples.length);
  if (rms < MIN_RMS) {
    return null;
  }

  const centered = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    centered[i] = samples[i] - mean;
  }

  const minPitchHz = options.minPitchHz ?? MIN_PITCH_HZ;
  const maxPitchHz = options.maxPitchHz ?? MAX_PITCH_HZ;
  const minLag = Math.max(2, Math.floor(options.sampleRateHz / maxPitchHz));
  const maxLag = Math.min(
    centered.length - 2,
    Math.ceil(options.sampleRateHz / minPitchHz),
  );
  if (maxLag <= minLag) return null;

  let bestLag = 0;
  let bestCorrelation = -Infinity;
  const correlations = new Map<number, number>();

  for (let lag = minLag; lag <= maxLag; lag++) {
    let product = 0;
    let energyA = 0;
    let energyB = 0;
    const limit = centered.length - lag;

    for (let i = 0; i < limit; i++) {
      const a = centered[i];
      const b = centered[i + lag];
      product += a * b;
      energyA += a * a;
      energyB += b * b;
    }

    if (energyA === 0 || energyB === 0) continue;
    const correlation = product / Math.sqrt(energyA * energyB);
    correlations.set(lag, correlation);
    if (correlation > bestCorrelation) {
      bestCorrelation = correlation;
      bestLag = lag;
    }
  }

  if (bestLag === 0 || bestCorrelation < 0.35) {
    return null;
  }

  const firstStrongPeak = findFirstStrongPeak(
    correlations,
    minLag,
    maxLag,
    bestCorrelation,
  );
  if (firstStrongPeak) {
    bestLag = firstStrongPeak;
  }

  return {
    pitchHz: roundHz(options.sampleRateHz / bestLag),
    rms,
    clarity: bestCorrelation,
  };
}

function findFirstStrongPeak(
  correlations: Map<number, number>,
  minLag: number,
  maxLag: number,
  bestCorrelation: number,
): number | null {
  const threshold = bestCorrelation * 0.85;
  for (let lag = minLag + 1; lag < maxLag; lag++) {
    const previous = correlations.get(lag - 1) ?? -Infinity;
    const current = correlations.get(lag) ?? -Infinity;
    const next = correlations.get(lag + 1) ?? -Infinity;
    if (current >= threshold && current >= previous && current >= next) {
      return lag;
    }
  }

  return null;
}

function pcm16ToMono(chunk: Buffer, channels: number): Float32Array {
  const frameCount = Math.floor(chunk.length / 2 / channels);
  const samples = new Float32Array(frameCount);

  for (let frame = 0; frame < frameCount; frame++) {
    let total = 0;
    for (let channel = 0; channel < channels; channel++) {
      const offset = (frame * channels + channel) * 2;
      total += chunk.readInt16LE(offset) / 32768;
    }
    samples[frame] = total / channels;
  }

  return samples;
}

function samplesToMs(samples: number, sampleRateHz: number): number {
  return Math.round((samples / sampleRateHz) * 1000);
}

function median(values: number[]): number {
  if (values.length === 0) return 0;

  const ordered = [...values].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  if (ordered.length % 2 === 1) {
    return ordered[middle];
  }

  return (ordered[middle - 1] + ordered[middle]) / 2;
}

function roundHz(value: number): number {
  return Math.round(value * 100) / 100;
}

function normalizeLabel(label: string): string {
  return label.trim().toLowerCase();
}
