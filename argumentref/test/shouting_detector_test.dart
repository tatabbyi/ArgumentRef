import 'package:argumentref/audio/shouting_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShoutingDetector', () {
    test('stays calm through a normal-volume conversation', () {
      final detector = ShoutingDetector();
      // Ordinary back-and-forth talking with little lulls.
      for (final level in [0.2, 0.35, 0.1, 0.3, 0.25, 0.4, 0.15, 0.3]) {
        expect(detector.classify(level), isFalse);
      }
    });

    test('flags an outright-loud burst regardless of baseline', () {
      final detector = ShoutingDetector();
      expect(detector.classify(0.9), isTrue);
    });

    test('flags a burst that is loud *relative to* a quiet room', () {
      final detector = ShoutingDetector();
      // Settle the baseline to a soft-spoken room.
      for (var i = 0; i < 20; i++) {
        detector.classify(0.18);
      }
      // 0.6 is below the old fixed 0.82 threshold, but it is well above this
      // room's learned normal — the ported baseline logic catches it.
      expect(detector.classify(0.6), isTrue);
    });

    test('holds the shout through a brief dip, releases once calm', () {
      final detector = ShoutingDetector();
      expect(detector.classify(0.9), isTrue);
      // Momentary dip that is still heated — stays flagged (hysteresis).
      expect(detector.classify(0.6), isTrue);
      // Genuinely back to normal — releases.
      expect(detector.classify(0.2), isFalse);
    });

    test('reset clears the shout and returns the baseline to default', () {
      final detector = ShoutingDetector();
      detector.classify(0.95);
      expect(detector.isShouting, isTrue);
      detector.reset();
      expect(detector.isShouting, isFalse);
      expect(detector.baseline, closeTo(0.14, 1e-9));
    });
  });
}
