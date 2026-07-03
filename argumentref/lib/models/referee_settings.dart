import 'package:flutter/foundation.dart';

/// How the referee words its calls — mirrors the backend's
/// `RefereeInterventionStyle` (`'gentle' | 'balanced' | 'direct'`).
enum RefereeInterventionStyle { gentle, balanced, direct }

/// A three-step dial used for both fallacy sensitivity and fact-check
/// strictness — mirrors the backend's `RefereeSensitivity`
/// (`'low' | 'medium' | 'high'`).
enum RefereeSensitivity { low, medium, high }

/// What kind of deals the compromise coach favours — mirrors the backend's
/// `RefereeCompromisePreference` (`'balanced' | 'practical' | 'fair'`).
enum RefereeCompromisePreference { balanced, practical, fair }

/// How often the ref steps in at all — mirrors the backend's
/// `RefereeInterventionFrequency` (`'low' | 'normal' | 'high'`).
enum RefereeInterventionFrequency { low, normal, high }

/// The user's tuning of the live referee, sent to the backend as query
/// parameters on the `/v1/audio` WebSocket (see the backend's
/// `parseRefereeSettingsFromUrl`). Each enum's `.name` is exactly the wire
/// value the backend validates, and the defaults here match the backend's
/// `DEFAULT_REFEREE_SETTINGS`, so omitting or corrupting any value simply
/// lands on the same behaviour the server would pick anyway.
@immutable
class RefereeSettings {
  const RefereeSettings({
    this.interventionStyle = RefereeInterventionStyle.balanced,
    this.fallacySensitivity = RefereeSensitivity.medium,
    this.factCheckStrictness = RefereeSensitivity.medium,
    this.compromisePreference = RefereeCompromisePreference.balanced,
    this.interventionFrequency = RefereeInterventionFrequency.normal,
  });

  /// How the ref words a call: soft nudge ↔ blunt whistle.
  final RefereeInterventionStyle interventionStyle;

  /// How quickly shaky reasoning gets flagged.
  final RefereeSensitivity fallacySensitivity;

  /// How strictly factual claims are challenged.
  final RefereeSensitivity factCheckStrictness;

  /// What kind of middle ground the compromise coach pushes for.
  final RefereeCompromisePreference compromisePreference;

  /// How often the ref interjects at all.
  final RefereeInterventionFrequency interventionFrequency;

  /// The backend's defaults — what every session used before this was tunable.
  static const defaults = RefereeSettings();

  RefereeSettings copyWith({
    RefereeInterventionStyle? interventionStyle,
    RefereeSensitivity? fallacySensitivity,
    RefereeSensitivity? factCheckStrictness,
    RefereeCompromisePreference? compromisePreference,
    RefereeInterventionFrequency? interventionFrequency,
  }) {
    return RefereeSettings(
      interventionStyle: interventionStyle ?? this.interventionStyle,
      fallacySensitivity: fallacySensitivity ?? this.fallacySensitivity,
      factCheckStrictness: factCheckStrictness ?? this.factCheckStrictness,
      compromisePreference: compromisePreference ?? this.compromisePreference,
      interventionFrequency:
          interventionFrequency ?? this.interventionFrequency,
    );
  }

  /// The query parameters the backend reads in `parseRefereeSettingsFromUrl`.
  Map<String, String> toQueryParameters() => {
    'interventionStyle': interventionStyle.name,
    'fallacySensitivity': fallacySensitivity.name,
    'factCheckStrictness': factCheckStrictness.name,
    'compromisePreference': compromisePreference.name,
    'interventionFrequency': interventionFrequency.name,
  };

  Map<String, dynamic> toJson() => toQueryParameters();

  factory RefereeSettings.fromJson(Map<String, dynamic> json) {
    return RefereeSettings(
      interventionStyle: _parse(
        RefereeInterventionStyle.values,
        json['interventionStyle'],
        defaults.interventionStyle,
      ),
      fallacySensitivity: _parse(
        RefereeSensitivity.values,
        json['fallacySensitivity'],
        defaults.fallacySensitivity,
      ),
      factCheckStrictness: _parse(
        RefereeSensitivity.values,
        json['factCheckStrictness'],
        defaults.factCheckStrictness,
      ),
      compromisePreference: _parse(
        RefereeCompromisePreference.values,
        json['compromisePreference'],
        defaults.compromisePreference,
      ),
      interventionFrequency: _parse(
        RefereeInterventionFrequency.values,
        json['interventionFrequency'],
        defaults.interventionFrequency,
      ),
    );
  }

  static T _parse<T extends Enum>(List<T> values, Object? raw, T fallback) {
    if (raw is! String) return fallback;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is RefereeSettings &&
      other.interventionStyle == interventionStyle &&
      other.fallacySensitivity == fallacySensitivity &&
      other.factCheckStrictness == factCheckStrictness &&
      other.compromisePreference == compromisePreference &&
      other.interventionFrequency == interventionFrequency;

  @override
  int get hashCode => Object.hash(
    interventionStyle,
    fallacySensitivity,
    factCheckStrictness,
    compromisePreference,
    interventionFrequency,
  );
}
