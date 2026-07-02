import 'package:flutter/foundation.dart';

/// Someone the user talks things through with, captured during onboarding.
@immutable
class Contact {
  const Contact({required this.name, required this.relationship});

  final String name;

  /// A label from [kRelationships] — e.g. "Partner", "Colleague".
  final String relationship;

  Contact copyWith({String? name, String? relationship}) => Contact(
    name: name ?? this.name,
    relationship: relationship ?? this.relationship,
  );

  Map<String, dynamic> toJson() => {'name': name, 'relationship': relationship};

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    name: (json['name'] ?? '') as String,
    relationship: (json['relationship'] ?? 'Other') as String,
  );

  @override
  bool operator ==(Object other) =>
      other is Contact &&
      other.name == name &&
      other.relationship == relationship;

  @override
  int get hashCode => Object.hash(name, relationship);
}

/// Everything we remember about a user between sessions. Persisted locally as
/// JSON via `ProfileStore`.
@immutable
class UserProfile {
  const UserProfile({
    this.name = '',
    this.contacts = const [],
    this.flaws = const [],
    this.recentNames = const [],
    this.onboardingComplete = false,
  });

  /// The user's own name.
  final String name;

  /// People they argue / talk things through with most.
  final List<Contact> contacts;

  /// Self-identified argument tendencies (ids from [kFlaws]).
  final List<String> flaws;

  /// Names used in past sessions (most-recent first) so they can be re-picked.
  final List<String> recentNames;

  /// Whether the one-time onboarding has been finished.
  final bool onboardingComplete;

  /// The empty starting profile for a brand-new install.
  static const empty = UserProfile();

  /// Every name we can offer as a quick pick: the user, their contacts and any
  /// names used before — de-duplicated, preserving a sensible order.
  List<String> get knownNames {
    final seen = <String>{};
    final ordered = <String>[];
    void add(String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      if (seen.add(v.toLowerCase())) ordered.add(v);
    }

    add(name);
    for (final c in contacts) {
      add(c.name);
    }
    for (final n in recentNames) {
      add(n);
    }
    return ordered;
  }

  UserProfile copyWith({
    String? name,
    List<Contact>? contacts,
    List<String>? flaws,
    List<String>? recentNames,
    bool? onboardingComplete,
  }) {
    return UserProfile(
      name: name ?? this.name,
      contacts: contacts ?? this.contacts,
      flaws: flaws ?? this.flaws,
      recentNames: recentNames ?? this.recentNames,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    );
  }

  /// Returns a copy with [names] promoted to the front of the recent list.
  UserProfile withRecentNames(Iterable<String> names) {
    final seen = <String>{};
    final ordered = <String>[];
    void add(String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      if (seen.add(v.toLowerCase())) ordered.add(v);
    }

    for (final n in names) {
      add(n);
    }
    for (final n in recentNames) {
      add(n);
    }
    return copyWith(recentNames: ordered.take(12).toList());
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'contacts': contacts.map((c) => c.toJson()).toList(),
    'flaws': flaws,
    'recentNames': recentNames,
    'onboardingComplete': onboardingComplete,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      name: (json['name'] ?? '') as String,
      contacts: ((json['contacts'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => Contact.fromJson(e.cast<String, dynamic>()))
          .toList(),
      flaws: ((json['flaws'] ?? const []) as List).cast<String>(),
      recentNames: ((json['recentNames'] ?? const []) as List).cast<String>(),
      onboardingComplete: (json['onboardingComplete'] ?? false) as bool,
    );
  }
}
