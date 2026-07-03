import 'package:argumentref/config/backend_config.dart';
import 'package:argumentref/models/referee_settings.dart';
import 'package:argumentref/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RefereeSettings', () {
    test('defaults match the backend DEFAULT_REFEREE_SETTINGS', () {
      expect(RefereeSettings.defaults.toQueryParameters(), {
        'interventionStyle': 'balanced',
        'fallacySensitivity': 'medium',
        'factCheckStrictness': 'medium',
        'compromisePreference': 'balanced',
        'interventionFrequency': 'normal',
      });
    });

    test('enum names are exactly the backend wire values', () {
      // The backend's readers validate against these literals; a renamed enum
      // case would silently fall back to defaults server-side.
      expect(RefereeInterventionStyle.values.map((v) => v.name), [
        'gentle',
        'balanced',
        'direct',
      ]);
      expect(RefereeSensitivity.values.map((v) => v.name), [
        'low',
        'medium',
        'high',
      ]);
      expect(RefereeCompromisePreference.values.map((v) => v.name), [
        'balanced',
        'practical',
        'fair',
      ]);
      expect(RefereeInterventionFrequency.values.map((v) => v.name), [
        'low',
        'normal',
        'high',
      ]);
    });

    test('round-trips through JSON', () {
      const tuned = RefereeSettings(
        interventionStyle: RefereeInterventionStyle.direct,
        fallacySensitivity: RefereeSensitivity.high,
        factCheckStrictness: RefereeSensitivity.low,
        compromisePreference: RefereeCompromisePreference.practical,
        interventionFrequency: RefereeInterventionFrequency.high,
      );
      expect(RefereeSettings.fromJson(tuned.toJson()), tuned);
    });

    test('falls back to defaults on unknown or missing JSON values', () {
      final parsed = RefereeSettings.fromJson({
        'interventionStyle': 'shouty',
        'fallacySensitivity': 42,
      });
      expect(parsed, RefereeSettings.defaults);
    });
  });

  group('audio URL', () {
    test('carries the referee settings as query params', () {
      final uri = BackendConfig.audioUri(
        sessionId: 'session',
        participantId: 'phone',
        sampleRateHz: 16000,
        channels: 1,
        refereeSettings: const RefereeSettings(
          interventionStyle: RefereeInterventionStyle.gentle,
          fallacySensitivity: RefereeSensitivity.high,
          factCheckStrictness: RefereeSensitivity.high,
          compromisePreference: RefereeCompromisePreference.fair,
          interventionFrequency: RefereeInterventionFrequency.low,
        ),
      );

      expect(uri.queryParameters['interventionStyle'], 'gentle');
      expect(uri.queryParameters['fallacySensitivity'], 'high');
      expect(uri.queryParameters['factCheckStrictness'], 'high');
      expect(uri.queryParameters['compromisePreference'], 'fair');
      expect(uri.queryParameters['interventionFrequency'], 'low');
    });

    test('sends the defaults explicitly when nothing was tuned', () {
      final uri = BackendConfig.audioUri(
        sessionId: 'session',
        participantId: 'phone',
        sampleRateHz: 16000,
        channels: 1,
      );

      expect(uri.queryParameters['interventionStyle'], 'balanced');
      expect(uri.queryParameters['interventionFrequency'], 'normal');
    });
  });

  group('UserProfile persistence', () {
    test('round-trips tuned referee settings', () {
      const profile = UserProfile(
        name: 'Ada',
        refereeSettings: RefereeSettings(
          interventionStyle: RefereeInterventionStyle.direct,
          interventionFrequency: RefereeInterventionFrequency.low,
        ),
      );

      final restored = UserProfile.fromJson(profile.toJson());
      expect(restored.refereeSettings, profile.refereeSettings);
    });

    test('older profiles without settings load with defaults', () {
      final restored = UserProfile.fromJson({'name': 'Ada'});
      expect(restored.refereeSettings, RefereeSettings.defaults);
    });
  });
}
