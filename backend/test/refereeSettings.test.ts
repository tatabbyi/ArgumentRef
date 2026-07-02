import { describe, expect, it } from 'vitest';
import {
  DEFAULT_REFEREE_SETTINGS,
  parseRefereeSettingsFromUrl,
} from '../src/referee/refereeSettings.js';

describe('referee settings', () => {
  it('uses defaults when query settings are missing', () => {
    const url = new URL('wss://example.com/v1/audio');

    expect(parseRefereeSettingsFromUrl(url)).toEqual(DEFAULT_REFEREE_SETTINGS);
  });

  it('parses supported query settings', () => {
    const url = new URL(
      'wss://example.com/v1/audio?interventionStyle=gentle&fallacySensitivity=low&factCheckStrictness=high&compromisePreference=fair&interventionFrequency=high',
    );

    expect(parseRefereeSettingsFromUrl(url)).toEqual({
      interventionStyle: 'gentle',
      fallacySensitivity: 'low',
      factCheckStrictness: 'high',
      compromisePreference: 'fair',
      interventionFrequency: 'high',
    });
  });

  it('falls back safely for unsupported query settings', () => {
    const url = new URL(
      'wss://example.com/v1/audio?interventionStyle=angry&fallacySensitivity=maximum&factCheckStrictness=nope&compromisePreference=winner&interventionFrequency=constant',
    );

    expect(parseRefereeSettingsFromUrl(url)).toEqual(DEFAULT_REFEREE_SETTINGS);
  });
});
