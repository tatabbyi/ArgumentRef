import 'dart:async';

import 'package:flutter/services.dart';

enum RefHaptic { light, medium, heavy, selection }

class RefHaptics {
  const RefHaptics._();

  static Future<void> play(RefHaptic haptic) {
    return switch (haptic) {
      RefHaptic.light => HapticFeedback.lightImpact(),
      RefHaptic.medium => HapticFeedback.mediumImpact(),
      RefHaptic.heavy => HapticFeedback.heavyImpact(),
      RefHaptic.selection => HapticFeedback.selectionClick(),
    };
  }

  static VoidCallback? wrap(
    VoidCallback? callback, {
    RefHaptic haptic = RefHaptic.light,
  }) {
    if (callback == null) return null;
    return () {
      unawaited(play(haptic));
      callback();
    };
  }
}
