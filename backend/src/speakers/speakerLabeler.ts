import type {
  SpeakerMappedEvent,
  TranscriptFinalEvent,
  TranscriptPartialEvent,
} from '../protocol/messages.js';
import type { SpeakerVoiceProfile } from './voicePitch.js';

type TranscriptEvent = TranscriptPartialEvent | TranscriptFinalEvent;

interface SpeakerLabelerContext {
  sessionId: string;
  streamId: string;
  labels: string[];
  voiceProfiles?: SpeakerVoiceProfile[];
}

interface LabelledTranscript<TEvent extends TranscriptEvent> {
  event: TEvent;
  mapping?: SpeakerMappedEvent;
}

interface SpeakerAssignment {
  label: string;
  isNew: boolean;
  source: SpeakerMappedEvent['source'];
}

interface LabelTranscriptOptions {
  pitchHz?: number;
}

interface PitchMatch {
  label: string;
  confidence: number;
}

export class SpeakerLabeler {
  private readonly speakerToLabel = new Map<string, string>();
  private readonly voiceProfiles = new Map<string, SpeakerVoiceProfile>();

  constructor(private readonly context: SpeakerLabelerContext) {
    for (const profile of context.voiceProfiles ?? []) {
      this.recordVoiceProfile(profile);
    }
  }

  recordVoiceProfile(profile: SpeakerVoiceProfile): void {
    const label = profile.label.trim();
    if (!label || !isUsablePitch(profile.medianPitchHz)) {
      return;
    }

    this.voiceProfiles.set(normalizeLabel(label), {
      ...profile,
      label,
    });
  }

  labelTranscript<TEvent extends TranscriptEvent>(
    event: TEvent,
    options: LabelTranscriptOptions = {},
  ): LabelledTranscript<TEvent> {
    const assignment = this.getOrCreateAssignment(event.speaker, options.pitchHz);
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
            source: assignment.source,
          }
        : undefined,
    };
  }

  private getOrCreateAssignment(
    speaker: string,
    pitchHz?: number,
  ): SpeakerAssignment | null {
    const pitchAssignment = this.getPitchAssignment(speaker, pitchHz);
    if (pitchAssignment) {
      return pitchAssignment;
    }

    if (speaker === 'speaker_unknown') {
      return null;
    }

    const existingLabel = this.speakerToLabel.get(speaker);
    if (existingLabel) {
      return {
        label: existingLabel,
        isNew: false,
        source: 'query_calibration',
      };
    }

    const nextLabel = this.nextFallbackLabel();
    if (!nextLabel) {
      return null;
    }

    this.speakerToLabel.set(speaker, nextLabel);

    return {
      label: nextLabel,
      isNew: true,
      source: 'query_calibration',
    };
  }

  private getPitchAssignment(
    speaker: string,
    pitchHz?: number,
  ): SpeakerAssignment | null {
    const match = this.matchPitch(
      pitchHz,
      this.labelsAssignedToOtherSpeakers(speaker),
    );
    if (!match) {
      return null;
    }

    if (speaker === 'speaker_unknown') {
      return {
        label: match.label,
        isNew: false,
        source: 'pitch_calibration',
      };
    }

    const existingLabel = this.speakerToLabel.get(speaker);
    if (existingLabel === match.label) {
      return {
        label: existingLabel,
        isNew: false,
        source: 'pitch_calibration',
      };
    }

    this.speakerToLabel.set(speaker, match.label);
    return {
      label: match.label,
      isNew: true,
      source: 'pitch_calibration',
    };
  }

  private matchPitch(
    pitchHz: number | undefined,
    excludedLabels: Set<string>,
  ): PitchMatch | null {
    if (!isUsablePitch(pitchHz)) return null;

    const candidates = [...this.voiceProfiles.values()].filter(
      (profile) => !excludedLabels.has(normalizeLabel(profile.label)),
    );
    if (candidates.length === 0) return null;

    const ranked = candidates
      .map((profile) => ({
        label: profile.label,
        distanceCents: pitchDistanceCents(pitchHz, profile.medianPitchHz),
      }))
      .sort((a, b) => a.distanceCents - b.distanceCents);
    const best = ranked[0];
    const second = ranked[1];
    if (best.distanceCents > 450) {
      return null;
    }
    if (second && second.distanceCents - best.distanceCents < 120) {
      return null;
    }

    const closeness = Math.max(0, 1 - best.distanceCents / 450);
    const separation = second
      ? Math.min(1, (second.distanceCents - best.distanceCents) / 600)
      : 1;

    return {
      label: best.label,
      confidence: Math.round((closeness * 0.7 + separation * 0.3) * 100) / 100,
    };
  }

  private nextFallbackLabel(): string | null {
    const assigned = this.labelsAssignedToAnySpeaker();
    return (
      this.context.labels.find((label) => !assigned.has(normalizeLabel(label))) ??
      null
    );
  }

  private labelsAssignedToAnySpeaker(): Set<string> {
    return new Set(
      [...this.speakerToLabel.values()].map((label) => normalizeLabel(label)),
    );
  }

  private labelsAssignedToOtherSpeakers(speaker: string): Set<string> {
    const labels = new Set<string>();
    for (const [assignedSpeaker, label] of this.speakerToLabel.entries()) {
      if (assignedSpeaker !== speaker) {
        labels.add(normalizeLabel(label));
      }
    }
    return labels;
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

function pitchDistanceCents(a: number, b: number): number {
  return Math.abs(1200 * Math.log2(a / b));
}

function isUsablePitch(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

function normalizeLabel(label: string): string {
  return label.trim().toLowerCase();
}
