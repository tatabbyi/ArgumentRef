import 'package:flutter/widgets.dart';

/// Which speaker currently holds the floor.
enum Speaker { left, right, none }

/// The referee's emotional read on the room. Drives brows, eye offset, head
/// tilt and eyelid rest position.
enum Mood { listen, curious, concern, alert, approve }

/// The mouth shape shown for a beat.
enum MouthShape { neutral, smile, frown, o, tense }

/// One scripted moment in the referee's reaction loop.
///
/// Mirrors the `beats` array in the design prototype's `<script>`. [flow] and
/// [cut] are nullable: a null value means "leave the read-out where it was",
/// exactly like the prototype which only writes those fields when present.
@immutable
class Beat {
  const Beat({
    required this.active,
    required this.mood,
    required this.mouth,
    required this.caption,
    this.flow,
    this.cut,
  });

  final Speaker active;
  final Mood mood;
  final MouthShape mouth;
  final String caption;
  final int? flow;
  final int? cut;

  /// Horizontal pupil offset (px) for the active speaker.
  double get eyeDx => switch (active) {
    Speaker.left => -6,
    Speaker.right => 6,
    Speaker.none => 0,
  };

  /// Vertical pupil offset (px) — the eyes lift a touch when approving,
  /// drop when concerned.
  double get eyeDy => switch (mood) {
    Mood.approve => 2,
    Mood.concern => -1,
    _ => 0,
  };

  /// Left brow rotation (degrees).
  double get browLeftDeg => switch (mood) {
    Mood.concern => 16,
    Mood.curious => -18,
    Mood.alert => 12,
    _ => 0,
  };

  /// Right brow rotation (degrees).
  double get browRightDeg => switch (mood) {
    Mood.concern => -16,
    Mood.alert => -12,
    _ => 0,
  };

  /// Shared vertical shift applied to both brows (px).
  double get browTransY => switch (mood) {
    Mood.concern => 3,
    Mood.curious => -4,
    Mood.approve => -3,
    Mood.alert => 4,
    _ => 0,
  };

  /// Head tilt (degrees) — turns toward whoever is speaking.
  double get headRotDeg => switch (active) {
    Speaker.left => -4,
    Speaker.right => 4,
    Speaker.none => 0,
  };

  /// Head bob (px) — a small approving nod.
  double get headTransY => mood == Mood.approve ? 3 : 0;

  /// Resting eyelid scale — lids ride a little lower when approving or on alert.
  double get lidRest => (mood == Mood.approve || mood == Mood.alert) ? 0.34 : 0;

  /// Whether the whistle should glow (about to intervene).
  bool get whistleGlow => mood == Mood.alert;
}

/// The referee's scripted reaction loop, transcribed verbatim from the design
/// prototype. Each beat holds for [beatDuration].
const List<Beat> kBeats = [
  Beat(
    active: Speaker.left,
    mood: Mood.listen,
    mouth: MouthShape.neutral,
    caption: 'Let {L} finish',
    flow: 58,
    cut: 2,
  ),
  Beat(
    active: Speaker.left,
    mood: Mood.curious,
    mouth: MouthShape.o,
    caption: 'Hear {L} out',
  ),
  Beat(
    active: Speaker.right,
    mood: Mood.listen,
    mouth: MouthShape.neutral,
    caption: 'Your turn, {R}',
    flow: 52,
  ),
  Beat(
    active: Speaker.right,
    mood: Mood.concern,
    mouth: MouthShape.tense,
    caption: 'One at a time',
    cut: 3,
  ),
  Beat(
    active: Speaker.left,
    mood: Mood.alert,
    mouth: MouthShape.tense,
    caption: 'Let {L} speak',
  ),
  Beat(
    active: Speaker.right,
    mood: Mood.listen,
    mouth: MouthShape.neutral,
    caption: 'Go ahead, {R}',
    flow: 57,
  ),
  Beat(
    active: Speaker.right,
    mood: Mood.approve,
    mouth: MouthShape.smile,
    caption: 'Nice point — build on it',
    flow: 63,
  ),
  Beat(
    active: Speaker.left,
    mood: Mood.approve,
    mouth: MouthShape.smile,
    caption: 'Keep hearing each other out',
    flow: 66,
  ),
  Beat(
    active: Speaker.none,
    mood: Mood.listen,
    mouth: MouthShape.neutral,
    caption: 'Watching the room…',
  ),
];

/// How long each beat is held (ms) — the prototype's `setInterval(…, 2400)`.
const Duration beatDuration = Duration(milliseconds: 2400);

/// Blink cadence — prototype's `setInterval(this.blink(), 3400)`.
const Duration blinkInterval = Duration(milliseconds: 3400);

/// How long a blink closes the lids — prototype's `setTimeout(…, 130)`.
const Duration blinkClosedDuration = Duration(milliseconds: 130);

/// Saccade (eye micro-jitter) cadence — prototype's `setInterval(…, 1300)`.
const Duration saccadeInterval = Duration(milliseconds: 1300);
