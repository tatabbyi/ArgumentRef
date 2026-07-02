import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_profile.dart';

/// Loads and persists the [UserProfile] to on-device storage
/// (`shared_preferences`). Everything the onboarding and welcome flows collect
/// lives here — there is no backend.
class ProfileStore {
  static const _key = 'user_profile_v1';

  /// Reads the saved profile, or [UserProfile.empty] if none exists / is
  /// unreadable (a corrupt blob should never brick the app).
  Future<UserProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return UserProfile.empty;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return UserProfile.fromJson(json);
    } catch (_) {
      return UserProfile.empty;
    }
  }

  /// Writes [profile] back to disk.
  Future<void> save(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(profile.toJson()));
  }
}
