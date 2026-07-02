import { describe, expect, it } from 'vitest';
import { summarizeDeepgramDiarization } from '../src/transcription/deepgramTranscriber.js';

describe('deepgram diarization summary', () => {
  it('reports missing speaker labels when words have no speaker values', () => {
    const summary = summarizeDeepgramDiarization([
      {
        word: 'hello',
      },
      {
        word: 'there',
      },
    ]);

    expect(summary.status).toBe('missing_speaker_labels');
    expect(summary.totalWords).toBe(2);
    expect(summary.wordsWithSpeaker).toBe(0);
  });

  it('reports multiple speakers when Deepgram returns multiple speaker IDs', () => {
    const summary = summarizeDeepgramDiarization([
      {
        word: 'hello',
        speaker: 0,
      },
      {
        word: 'hi',
        speaker: 1,
      },
    ]);

    expect(summary.status).toBe('multiple_speakers');
    expect(summary.speakers).toEqual(['speaker_0', 'speaker_1']);
    expect(summary.wordsWithSpeaker).toBe(2);
  });
});
