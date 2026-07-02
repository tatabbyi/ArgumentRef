import type { AppConfig } from '../config.js';
import type {
  ArgumentRatingUpdatedEvent,
  ClaimDetectedEvent,
  CompromiseSuggestedEvent,
  FactCheckCompletedEvent,
  FallacyDetectedEvent,
  FallacyKind,
  RefereeInterventionFrequency,
  RefereeInterventionCategory,
  RefereeInterventionPriority,
  RefereeInterventionSuggestedEvent,
  RefereeInterventionStyle,
  RefereeSettings,
  ServerEvent,
} from '../protocol/messages.js';
import { withDefaultRefereeSettings } from '../referee/refereeSettings.js';

type InterventionSourceEvent =
  | ClaimDetectedEvent
  | FactCheckCompletedEvent
  | FallacyDetectedEvent
  | CompromiseSuggestedEvent
  | ArgumentRatingUpdatedEvent;

interface RefereeInterventionEngineOptions {
  config: AppConfig;
  settings?: Partial<RefereeSettings>;
  now?: () => number;
}

interface InterventionDraft {
  sessionId: string;
  streamId: string;
  category: RefereeInterventionCategory;
  priority: RefereeInterventionPriority;
  message: string;
  reason: string;
  sourceEvent: RefereeInterventionSuggestedEvent['sourceEvent'];
  sourceId?: string;
  speaker?: string;
  speakerLabel?: string;
}

const LOW_RATING_THRESHOLD = 65;
const LOW_DIMENSION_THRESHOLD = 55;

export class RefereeInterventionEngine {
  private readonly seenSources = new Set<string>();
  private readonly lastEmittedAtByCategory = new Map<
    RefereeInterventionCategory,
    number
  >();
  private readonly now: () => number;
  private readonly settings: RefereeSettings;

  constructor(private readonly options: RefereeInterventionEngineOptions) {
    this.now = options.now ?? Date.now;
    this.settings = withDefaultRefereeSettings(options.settings);
  }

  observe(event: ServerEvent): RefereeInterventionSuggestedEvent | undefined {
    if (!this.options.config.refereeInterventionsEnabled) {
      return undefined;
    }

    if (!isInterventionSource(event)) {
      return undefined;
    }

    const draft = toInterventionDraft(event, this.settings);
    if (!draft) {
      return undefined;
    }

    const sourceKey = `${draft.sourceEvent}:${draft.sourceId ?? draft.message}`;
    if (this.seenSources.has(sourceKey)) {
      return undefined;
    }

    if (this.isCoolingDown(draft.category)) {
      return undefined;
    }

    this.seenSources.add(sourceKey);
    this.lastEmittedAtByCategory.set(draft.category, this.now());

    return {
      type: 'referee.intervention.suggested',
      interventionId: buildInterventionId(draft),
      generatedAt: new Date(this.now()).toISOString(),
      ...applyInterventionStyle(draft, this.settings.interventionStyle),
    };
  }

  private isCoolingDown(category: RefereeInterventionCategory): boolean {
    const cooldownMs = adjustedCooldownMs(
      this.options.config.refereeInterventionCooldownMs,
      this.settings.interventionFrequency,
    );
    if (cooldownMs <= 0) {
      return false;
    }

    const lastEmittedAt = this.lastEmittedAtByCategory.get(category);
    return lastEmittedAt !== undefined && this.now() - lastEmittedAt < cooldownMs;
  }
}

function isInterventionSource(event: ServerEvent): event is InterventionSourceEvent {
  return (
    event.type === 'claim.detected' ||
    event.type === 'fact_check.completed' ||
    event.type === 'fallacy.detected' ||
    event.type === 'compromise.suggested' ||
    event.type === 'argument.rating.updated'
  );
}

function toInterventionDraft(
  event: InterventionSourceEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  switch (event.type) {
    case 'claim.detected':
      return interventionFromClaim(event, settings);
    case 'fact_check.completed':
      return interventionFromFactCheck(event, settings);
    case 'fallacy.detected':
      return interventionFromFallacy(event, settings);
    case 'compromise.suggested':
      return interventionFromCompromise(event, settings);
    case 'argument.rating.updated':
      return interventionFromRating(event, settings);
    default:
      return assertNever(event);
  }
}

function interventionFromClaim(
  event: ClaimDetectedEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  if (settings.factCheckStrictness === 'low') {
    return undefined;
  }

  return {
    sessionId: event.sessionId,
    streamId: event.streamId,
    category: 'factual',
    priority: settings.factCheckStrictness === 'high' ? 'medium' : 'low',
    message: 'Mark this as a factual claim and ask for the source.',
    reason: `Checkable claim detected: "${truncate(event.text, 140)}"`,
    sourceEvent: 'claim.detected',
    sourceId: event.claimId,
    speaker: event.speaker,
    speakerLabel: event.speakerLabel,
  };
}

function interventionFromFactCheck(
  event: FactCheckCompletedEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  if (event.status === 'no_match') {
    if (settings.factCheckStrictness === 'low') {
      return undefined;
    }

    return {
      sessionId: event.sessionId,
      streamId: event.streamId,
      category: 'factual',
      priority: settings.factCheckStrictness === 'high' ? 'medium' : 'low',
      message:
        'No published fact-check matched this claim; ask for evidence before treating it as settled.',
      reason: event.summary,
      sourceEvent: 'fact_check.completed',
      sourceId: `${event.claimId}:no_match`,
      speaker: event.speaker,
      speakerLabel: event.speakerLabel,
    };
  }

  const priority = factCheckPriority(event);
  if (settings.factCheckStrictness === 'low' && priority !== 'high') {
    return undefined;
  }

  return {
    sessionId: event.sessionId,
    streamId: event.streamId,
    category: 'factual',
    priority: settings.factCheckStrictness === 'high' ? bumpPriority(priority) : priority,
    message:
      'Pause on this factual point and compare it with the matched fact-check.',
    reason: event.summary,
    sourceEvent: 'fact_check.completed',
    sourceId: `${event.claimId}:matched_fact_check`,
    speaker: event.speaker,
    speakerLabel: event.speakerLabel,
  };
}

function interventionFromFallacy(
  event: FallacyDetectedEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  const priority = fallacyPriority(event);
  if (
    (settings.fallacySensitivity === 'low' && priority !== 'high') ||
    (settings.fallacySensitivity === 'medium' && priority === 'low')
  ) {
    return undefined;
  }

  const speakerName = event.speakerLabel ?? event.speaker;
  return {
    sessionId: event.sessionId,
    streamId: event.streamId,
    category: 'logic',
    priority,
    message: event.suggestedRefereeResponse,
    reason: `${speakerName} may be using ${formatFallacyKind(
      event.fallacy,
    )}: ${event.explanation}`,
    sourceEvent: 'fallacy.detected',
    sourceId: `${event.speaker}:${event.fallacy}:${event.quote}`,
    speaker: event.speaker,
    speakerLabel: event.speakerLabel,
  };
}

function interventionFromCompromise(
  event: CompromiseSuggestedEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  const suggestion = [...event.suggestions].sort((a, b) => {
    if (settings.compromisePreference === 'practical') {
      return b.score - a.score;
    }

    return a.rank - b.rank;
  })[0];
  if (!suggestion) {
    return undefined;
  }

  return {
    sessionId: event.sessionId,
    streamId: event.streamId,
    category: 'compromise',
    priority: compromisePriority(suggestion.score, suggestion.pushLevel),
    message: `${compromiseMessagePrefix(settings)} ${suggestion.summary}`,
    reason: suggestion.whyItCouldWork,
    sourceEvent: 'compromise.suggested',
    sourceId: suggestion.id,
  };
}

function interventionFromRating(
  event: ArgumentRatingUpdatedEvent,
  settings: RefereeSettings,
): InterventionDraft | undefined {
  const lowestDimension = lowestScoredDimension(event);
  const thresholds = ratingThresholds(settings.interventionFrequency);
  const shouldIntervene =
    event.overallScore <= thresholds.overall ||
    lowestDimension.score <= thresholds.dimension;

  if (!shouldIntervene) {
    return undefined;
  }

  const reason =
    event.risks[0] ??
    `Argument quality is ${event.overallScore}/100; ${lowestDimension.label} is lowest at ${lowestDimension.score}/100.`;

  return {
    sessionId: event.sessionId,
    streamId: event.streamId,
    category: 'argument_quality',
    priority: ratingPriority(event.overallScore, lowestDimension.score),
    message: event.refereeFocus,
    reason,
    sourceEvent: 'argument.rating.updated',
    sourceId: `rating-${event.transcriptLineCount}`,
  };
}

function factCheckPriority(
  event: FactCheckCompletedEvent,
): RefereeInterventionPriority {
  const rating = event.sources.find((source) => source.rating)?.rating ?? '';
  return /(false|misleading|incorrect|wrong|pants|bogus)/i.test(rating)
    ? 'high'
    : 'medium';
}

function bumpPriority(
  priority: RefereeInterventionPriority,
): RefereeInterventionPriority {
  if (priority === 'low') return 'medium';
  if (priority === 'medium') return 'high';
  return 'high';
}

function fallacyPriority(
  event: FallacyDetectedEvent,
): RefereeInterventionPriority {
  if (event.severity === 'serious' || event.confidence === 'high') {
    return 'high';
  }

  if (event.severity === 'moderate' || event.confidence === 'medium') {
    return 'medium';
  }

  return 'low';
}

function compromisePriority(
  score: number,
  pushLevel: CompromiseSuggestedEvent['suggestions'][number]['pushLevel'],
): RefereeInterventionPriority {
  if (pushLevel === 'urgent' || score >= 90) {
    return 'high';
  }

  if (pushLevel === 'firm' || score >= 75) {
    return 'medium';
  }

  return 'low';
}

function ratingPriority(
  overallScore: number,
  lowestDimensionScore: number,
): RefereeInterventionPriority {
  if (overallScore < 50 || lowestDimensionScore < 45) {
    return 'high';
  }

  if (overallScore <= LOW_RATING_THRESHOLD || lowestDimensionScore <= LOW_DIMENSION_THRESHOLD) {
    return 'medium';
  }

  return 'low';
}

function ratingThresholds(frequency: RefereeInterventionFrequency): {
  overall: number;
  dimension: number;
} {
  switch (frequency) {
    case 'low':
      return { overall: 55, dimension: 45 };
    case 'high':
      return { overall: 75, dimension: 65 };
    case 'normal':
      return {
        overall: LOW_RATING_THRESHOLD,
        dimension: LOW_DIMENSION_THRESHOLD,
      };
    default:
      return assertNever(frequency);
  }
}

function adjustedCooldownMs(
  cooldownMs: number,
  frequency: RefereeInterventionFrequency,
): number {
  switch (frequency) {
    case 'low':
      return cooldownMs * 2;
    case 'high':
      return Math.floor(cooldownMs / 2);
    case 'normal':
      return cooldownMs;
    default:
      return assertNever(frequency);
  }
}

function compromiseMessagePrefix(settings: RefereeSettings): string {
  switch (settings.compromisePreference) {
    case 'practical':
      return 'Try the most practical next step:';
    case 'fair':
      return 'Try the fairest compromise:';
    case 'balanced':
      return 'Try this compromise:';
    default:
      return assertNever(settings.compromisePreference);
  }
}

function applyInterventionStyle(
  draft: InterventionDraft,
  style: RefereeInterventionStyle,
): InterventionDraft {
  switch (style) {
    case 'gentle':
      return {
        ...draft,
        message: `Gently, ${lowercaseFirst(draft.message)}`,
      };
    case 'direct':
      return {
        ...draft,
        message: `Pause now: ${draft.message}`,
      };
    case 'balanced':
      return draft;
    default:
      return assertNever(style);
  }
}

function lowestScoredDimension(event: ArgumentRatingUpdatedEvent): {
  label: string;
  score: number;
} {
  const dimensions: Array<{ label: string; score: number }> = [
    { label: 'clarity', score: event.dimensions.clarity },
    { label: 'evidence quality', score: event.dimensions.evidenceQuality },
    { label: 'logical consistency', score: event.dimensions.logicalConsistency },
    { label: 'listening', score: event.dimensions.listening },
    { label: 'emotional control', score: event.dimensions.emotionalControl },
    { label: 'fairness', score: event.dimensions.fairness },
  ];

  return dimensions.reduce(
    (lowest, dimension) =>
      dimension.score < lowest.score ? dimension : lowest,
    dimensions[0],
  );
}

function buildInterventionId(draft: InterventionDraft): string {
  return `intervention-${slugify(
    `${draft.sourceEvent}-${draft.sourceId ?? draft.category}`,
  )}`;
}

function formatFallacyKind(fallacy: FallacyKind): string {
  return fallacy.replace(/_/g, ' ');
}

function slugify(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80);

  return slug || 'referee-action';
}

function truncate(value: string, maxLength: number): string {
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}

function lowercaseFirst(value: string): string {
  return value.length > 0 ? `${value[0].toLowerCase()}${value.slice(1)}` : value;
}

function assertNever(value: never): never {
  throw new Error(`Unhandled intervention value: ${JSON.stringify(value)}`);
}
