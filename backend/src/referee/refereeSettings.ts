import type {
  RefereeCompromisePreference,
  RefereeInterventionFrequency,
  RefereeInterventionStyle,
  RefereeSensitivity,
  RefereeSettings,
} from '../protocol/messages.js';

export const DEFAULT_REFEREE_SETTINGS: RefereeSettings = {
  interventionStyle: 'balanced',
  fallacySensitivity: 'medium',
  factCheckStrictness: 'medium',
  compromisePreference: 'balanced',
  interventionFrequency: 'normal',
};

export function parseRefereeSettingsFromUrl(url: URL): RefereeSettings {
  return {
    interventionStyle: readInterventionStyle(
      url.searchParams.get('interventionStyle'),
      DEFAULT_REFEREE_SETTINGS.interventionStyle,
    ),
    fallacySensitivity: readSensitivity(
      url.searchParams.get('fallacySensitivity'),
      DEFAULT_REFEREE_SETTINGS.fallacySensitivity,
    ),
    factCheckStrictness: readSensitivity(
      url.searchParams.get('factCheckStrictness'),
      DEFAULT_REFEREE_SETTINGS.factCheckStrictness,
    ),
    compromisePreference: readCompromisePreference(
      url.searchParams.get('compromisePreference'),
      DEFAULT_REFEREE_SETTINGS.compromisePreference,
    ),
    interventionFrequency: readInterventionFrequency(
      url.searchParams.get('interventionFrequency'),
      DEFAULT_REFEREE_SETTINGS.interventionFrequency,
    ),
  };
}

export function withDefaultRefereeSettings(
  settings: Partial<RefereeSettings> = {},
): RefereeSettings {
  return {
    ...DEFAULT_REFEREE_SETTINGS,
    ...settings,
  };
}

function readInterventionStyle(
  value: string | null,
  fallback: RefereeInterventionStyle,
): RefereeInterventionStyle {
  return value === 'gentle' || value === 'balanced' || value === 'direct'
    ? value
    : fallback;
}

function readSensitivity(
  value: string | null,
  fallback: RefereeSensitivity,
): RefereeSensitivity {
  return value === 'low' || value === 'medium' || value === 'high'
    ? value
    : fallback;
}

function readCompromisePreference(
  value: string | null,
  fallback: RefereeCompromisePreference,
): RefereeCompromisePreference {
  return value === 'balanced' || value === 'practical' || value === 'fair'
    ? value
    : fallback;
}

function readInterventionFrequency(
  value: string | null,
  fallback: RefereeInterventionFrequency,
): RefereeInterventionFrequency {
  return value === 'low' || value === 'normal' || value === 'high'
    ? value
    : fallback;
}
