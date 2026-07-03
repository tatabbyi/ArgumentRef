/// A Dart port of the `voice_analysis_proto` prototype's detection logic.
///
/// The Python prototype (`voice_analyzer.py` + `baseline_manager.py`) decided a
/// voice was escalating by comparing the current reading against a saved
/// **baseline** and flagging it `slightly_higher` / `much_higher` once it rose a
/// set ratio above that baseline — rather than using one fixed threshold. This
/// class keeps that idea but adapts it for the live app:
///
/// * The prototype captured a 30-second baseline once and stored it in
///   `baseline.json`. Here the baseline instead **learns continuously** from the
///   room's calmer moments (an EMA that only updates when nobody is shouting),
///   so it tracks how loud *this* conversation normally is with no setup step.
/// * The prototype worked on pitch (Hz); the live pipeline only exposes a single
///   mixed-mic loudness (both people share one microphone, and speaker identity
///   comes from the backend's diarization, not the local signal), so we apply
///   the same baseline/ratio decision to the normalized loudness level.
///
/// The ratio thresholds (`_slightlyAboveRatio` 1.08, `_muchAboveRatio` 1.15) are
/// carried over verbatim from the prototype's `analyze_voice_chunk`. An absolute
/// floor and hysteresis are layered on so a quiet room can't ratio its way into a
/// false alarm and a single loud burst doesn't flip the flag on and off.
class ShoutingDetector {
  ShoutingDetector({double baseline = _defaultBaseline}) : _baseline = baseline;

  // Prototype-derived ratios: how far above the learned baseline a reading has
  // to climb before it counts as raised / much-raised.
  static const double _slightlyAboveRatio = 1.08;
  static const double _muchAboveRatio = 1.15;

  /// A reading has to be at least this loud *in absolute terms* before the
  /// baseline ratio is allowed to declare a shout — stops a whisper-quiet room
  /// (tiny baseline) from tripping just because someone spoke a touch louder.
  static const double _relativeFloor = 0.45;

  /// Loud enough to be a shout on its own, no matter the baseline. Matches the
  /// original fixed threshold the controller used, kept as a ceiling shortcut.
  static const double _absoluteStartLoudness = 0.82;

  /// Below this, an in-progress shout is considered to have calmed (hysteresis
  /// so the flag doesn't chatter around the start threshold).
  static const double _absoluteStopLoudness = 0.56;

  /// Readings this quiet are silence gaps between words — ignored when learning
  /// the baseline so the "normal" level tracks talking, not the pauses.
  static const double _silenceFloor = 0.06;

  /// The baseline is never allowed below this, so a long quiet stretch can't
  /// collapse "normal" toward zero and make the next word look like a shout.
  static const double _minBaseline = 0.1;

  /// A reasonable resting loudness to start from before the room teaches us its
  /// own, so the very first loud exchange still reads as raised.
  static const double _defaultBaseline = 0.14;

  double _baseline;
  bool _shouting = false;

  /// The room's learned resting loudness (the live equivalent of the prototype's
  /// `baseline.json`).
  double get baseline => _baseline;

  /// Whether the most recent reading is an active shout.
  bool get isShouting => _shouting;

  /// Feeds one loudness reading (0 quiet … 1 loud) and returns whether the room
  /// is currently shouting, updating the learned baseline and hysteresis state.
  bool classify(double loudness) {
    final level = loudness.clamp(0.0, 1.0).toDouble();
    _adaptBaseline(level);

    final ratio = _baseline > 0 ? level / _baseline : 1.0;
    final loudInAbsolute = level >= _absoluteStartLoudness;
    final loudVsBaseline = level >= _relativeFloor && ratio >= _muchAboveRatio;
    final isShoutingNow = loudInAbsolute || loudVsBaseline;

    if (_shouting) {
      // Release only once it's both quiet in absolute terms and back near the
      // baseline — otherwise a still-heated exchange keeps the whistle going.
      final calmedDown =
          level < _absoluteStopLoudness &&
          (level < _relativeFloor || ratio < _slightlyAboveRatio);
      if (calmedDown) _shouting = false;
    } else if (isShoutingNow) {
      _shouting = true;
    }

    return _shouting;
  }

  /// Resets learned state — used when a new conversation starts.
  void reset() {
    _baseline = _defaultBaseline;
    _shouting = false;
  }

  /// Nudges the baseline toward the room's normal talking level. Outright shouts
  /// are ignored so they can't drag "normal" up and suppress detection, and
  /// silence gaps are ignored so the baseline tracks speech, not the pauses.
  /// It rises slowly but falls a little faster, so "normal" settles toward the
  /// quieter, resting level of the conversation rather than its peaks.
  void _adaptBaseline(double level) {
    if (level < _silenceFloor) return; // a gap between words, not the room level
    if (level >= _absoluteStartLoudness) return; // an outright shout, don't learn it

    final factor = level > _baseline ? 0.03 : 0.08;
    _baseline += (level - _baseline) * factor;
    if (_baseline < _minBaseline) _baseline = _minBaseline;
  }
}
