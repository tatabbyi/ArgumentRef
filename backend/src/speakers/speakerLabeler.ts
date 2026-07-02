import type {
  SpeakerMappedEvent,
  TranscriptFinalEvent,
  TranscriptPartialEvent,
} from '../protocol/messages.js';

type TranscriptEvent = TranscriptPartialEvent | TranscriptFinalEvent;

interface SpeakerLabelerContext {
  sessionId: string;
  streamId: string;
  labels: string[];
}

interface LabelledTranscript<TEvent extends TranscriptEvent> {
  event: TEvent;
  mapping?: SpeakerMappedEvent;
}

interface SpeakerAssignment {
  label: string;
  isNew: boolean;
}

export class SpeakerLabeler {
  private readonly speakerToLabel = new Map<string, string>();
  private nextLabelIndex = 0;

  constructor(private readonly context: SpeakerLabelerContext) {}

  labelTranscript<TEvent extends TranscriptEvent>(
    event: TEvent,
  ): LabelledTranscript<TEvent> {
    const assignment = this.getOrCreateAssignment(event.speaker);
    if (!assignment) {
      return { event };
    }

    const labelledEvent = {
      ...event,
      speakerLabel: assignment.label,
      words: event.words.map((word) =>
        word.speaker === event.speaker
          ? { ...word, speakerLabel: assignment.label }
          : word,
      ),
    };

    return {
      event: labelledEvent,
      mapping: assignment.isNew
        ? {
            type: 'speaker.mapped',
            sessionId: this.context.sessionId,
            streamId: this.context.streamId,
            speaker: event.speaker,
            speakerLabel: assignment.label,
            source: 'query_calibration',
          }
        : undefined,
    };
  }

  private getOrCreateAssignment(speaker: string): SpeakerAssignment | null {
    if (speaker === 'speaker_unknown' || this.context.labels.length === 0) {
      return null;
    }

    const existingLabel = this.speakerToLabel.get(speaker);
    if (existingLabel) {
      return {
        label: existingLabel,
        isNew: false,
      };
    }

    const nextLabel = this.context.labels[this.nextLabelIndex];
    if (!nextLabel) {
      return null;
    }

    this.speakerToLabel.set(speaker, nextLabel);
    this.nextLabelIndex += 1;

    return {
      label: nextLabel,
      isNew: true,
    };
  }
}

export function parseSpeakerLabels(value: string | undefined): string[] {
  if (!value) {
    return [];
  }

  return value
    .split(',')
    .map((label) => label.trim())
    .filter(Boolean)
    .slice(0, 8);
}
