import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'beats.dart';
import 'referee.dart';

/// A self-contained, "living" referee for use outside the main scene — the
/// guide that walks the user through onboarding and greets them on the welcome
/// screen.
///
/// It owns the same continuous signals as the main screen (breathe, sway, blink,
/// saccade) but takes its expression ([mood], [mouth], [gaze]) as inputs, so a
/// parent can pose it per step. Changing any input eases via [RefereeFace]'s
/// built-in transitions.
class RefereeGuide extends StatefulWidget {
  const RefereeGuide({
    super.key,
    this.mood = Mood.listen,
    this.mouth = MouthShape.neutral,
    this.gaze = Speaker.none,
    this.scale = 0.82,
  });

  final Mood mood;
  final MouthShape mouth;

  /// Where the eyes point. [Speaker.none] looks straight at the user.
  final Speaker gaze;

  /// Uniform scale applied to the 200×250 character drawing.
  final double scale;

  @override
  State<RefereeGuide> createState() => _RefereeGuideState();
}

class _RefereeGuideState extends State<RefereeGuide>
    with TickerProviderStateMixin {
  late final AnimationController _breathe;
  late final AnimationController _sway;
  Timer? _blinkTimer;
  Timer? _saccadeTimer;
  final _random = math.Random();

  bool _blinking = false;
  double _saccadeJitter = 0;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2300),
    )..repeat(reverse: true);
    _sway = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat(reverse: true);

    _blinkTimer = Timer.periodic(blinkInterval, (_) => _blink());
    _saccadeTimer = Timer.periodic(saccadeInterval, (_) => _saccade());
  }

  void _blink() {
    if (!mounted) return;
    setState(() => _blinking = true);
    Timer(blinkClosedDuration, () {
      if (!mounted) return;
      setState(() => _blinking = false);
    });
  }

  void _saccade() {
    if (!mounted) return;
    setState(() => _saccadeJitter = (_random.nextDouble() - 0.5) * 3);
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _saccadeTimer?.cancel();
    _breathe.dispose();
    _sway.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final beat = Beat(
      active: widget.gaze,
      mood: widget.mood,
      mouth: widget.mouth,
      caption: '',
    );
    return SizedBox(
      width: 200 * widget.scale,
      height: 250 * widget.scale,
      child: FittedBox(
        fit: BoxFit.contain,
        child: RefereeFace(
          beat: beat,
          blinking: _blinking,
          saccadeJitter: _saccadeJitter,
          breathe: _breathe,
          sway: _sway,
        ),
      ),
    );
  }
}
