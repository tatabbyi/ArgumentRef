import { describe, expect, it } from 'vitest';
import {
  parseSpeakerLabels,
  SpeakerLabeler,
} from '../src/speakers/speakerLabeler.js';
import type { TranscriptFinalEvent } from '../src/protocol/messages.js';

describe('speaker labeler', () => {
  it('parses comma-separated speaker labels', () => {
    expect(parseSpeakerLabels(' Alice, Bob ,, Carol ')).toEqual([
      'Alice',
      'Bob',
      'Carol',
    ]);
  });

  it('maps first-seen speaker IDs to calibration labels', () => {
    const labeler = new SpeakerLabeler({
      sessionId: 'session-1',
      streamId: 'stream-1',
      labels: ['Alice', 'Bob'],
    });

    const first = labeler.labelTranscript(transcriptFinal('speaker_0'));
    const second = labeler.labelTranscript(transcriptFinal('speaker_1'));
    const repeated = labeler.labelTranscript(transcriptFinal('speaker_0'));

    expect(first.event.speakerLabel).toBe('Alice');
    expect(first.mapping).toMatchObject({
      type: 'speaker.mapped',
      speaker: 'speaker_0',
      speakerLabel: 'Alice',
    });
    expect(second.event.speakerLabel).toBe('Bob');
    expect(repeated.event.speakerLabel).toBe('Alice');
    expect(repeated.mapping).toBeUndefined();
  });

  it('leaves speakers unlabelled when calibration labels run out', () => {
    const labeler = new SpeakerLabeler({
      sessionId: 'session-1',
      streamId: 'stream-1',
      labels: ['Alice'],
    });

    labeler.labelTranscript(transcriptFinal('speaker_0'));
    const unlabelled = labeler.labelTranscript(transcriptFinal('speaker_1'));

    expect(unlabelled.event.speakerLabel).toBeUndefined();
    expect(unlabelled.mapping).toBeUndefined();
  });

  it('uses calibrated pitch profiles before first-heard order', () => {
    const labeler = new SpeakerLabeler({
      sessionId: 'session-1',
      streamId: 'stream-1',
      labels: ['Alice', 'Bob'],
    });
    labeler.recordVoiceProfile(voiceProfile('Alice', 125));
    labeler.recordVoiceProfile(voiceProfile('Bob', 220));

    const first = labeler.labelTranscript(transcriptFinal('speaker_0'), {
      pitchHz: 218,
    });
    const second = labeler.labelTranscript(transcriptFinal('speaker_1'), {
      pitchHz: 126,
    });

    expect(first.event.speakerLabel).toBe('Bob');
    expect(first.mapping).toMatchObject({
      speaker: 'speaker_0',
      speakerLabel: 'Bob',
      source: 'pitch_calibration',
    });
    expect(second.event.speakerLabel).toBe('Alice');
    expect(second.mapping).toMatchObject({
      speaker: 'speaker_1',
      speakerLabel: 'Alice',
      source: 'pitch_calibration',
    });
  });

  it('falls back to label order when calibrated pitches are ambiguous', () => {
    const labeler = new SpeakerLabeler({
      sessionId: 'session-1',
      streamId: 'stream-1',
      labels: ['Alice', 'Bob'],
    });
    labeler.recordVoiceProfile(voiceProfile('Alice', 180));
    labeler.recordVoiceProfile(voiceProfile('Bob', 188));

    const labelled = labeler.labelTranscript(transcriptFinal('speaker_0'), {
      pitchHz: 184,
    });

    expect(labelled.event.speakerLabel).toBe('Alice');
    expect(labelled.mapping).toMatchObject({
      source: 'query_calibration',
    });
  });
});

function transcriptFinal(speaker: string): TranscriptFinalEvent {
  return {
    type: 'transcript.final',
    provider: 'deepgram',
    sessionId: 'session-1',
    streamId: 'stream-1',
    speaker,
    text: 'This is a test sentence.',
    words: [
      {
        word: 'This',
        speaker,
      },
    ],
  };
}

function voiceProfile(label: string, medianPitchHz: number) {
  return {
    label,
    medianPitchHz,
    minPitchHz: medianPitchHz - 4,
    maxPitchHz: medianPitchHz + 4,
    sampleCount: 8,
    recordedAt: '2026-07-02T12:00:00.000Z',
  };
}
