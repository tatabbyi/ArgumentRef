import { describe, expect, it } from 'vitest';
import {
  estimatePcm16PitchHz,
  PcmPitchTracker,
} from '../src/speakers/voicePitch.js';

const SAMPLE_RATE_HZ = 16000;

describe('PCM voice pitch tracking', () => {
  it('estimates the fundamental pitch of PCM16 speech-like audio', () => {
    const estimate = estimatePcm16PitchHz(sinePcm16(220, 0.2), {
      sampleRateHz: SAMPLE_RATE_HZ,
      channels: 1,
    });

    expect(Math.abs((estimate?.pitchHz ?? 0) - 220)).toBeLessThan(2);
    expect(estimate?.rms).toBeGreaterThan(0.1);
  });

  it('records a calibration profile and later reads segment pitch', () => {
    const tracker = new PcmPitchTracker({
      encoding: 'pcm16',
      sampleRateHz: SAMPLE_RATE_HZ,
      channels: 1,
    });

    tracker.startCalibration('Ada');
    for (let i = 0; i < 5; i++) {
      tracker.ingest(sinePcm16(180, 0.1));
    }
    const profile = tracker.stopCalibration('Ada');

    expect(profile?.label).toBe('Ada');
    expect(Math.abs((profile?.medianPitchHz ?? 0) - 180)).toBeLessThan(2);
    expect(profile?.sampleCount).toBe(5);

    tracker.ingest(sinePcm16(240, 0.1));
    tracker.ingest(sinePcm16(240, 0.1));

    expect(Math.abs((tracker.pitchForSegment(500, 700) ?? 0) - 240)).toBeLessThan(
      2,
    );
  });
});

function sinePcm16(frequencyHz: number, durationSeconds: number): Buffer {
  const sampleCount = Math.floor(SAMPLE_RATE_HZ * durationSeconds);
  const buffer = Buffer.alloc(sampleCount * 2);

  for (let i = 0; i < sampleCount; i++) {
    const value = Math.sin((2 * Math.PI * frequencyHz * i) / SAMPLE_RATE_HZ);
    buffer.writeInt16LE(Math.round(value * 12000), i * 2);
  }

  return buffer;
}
