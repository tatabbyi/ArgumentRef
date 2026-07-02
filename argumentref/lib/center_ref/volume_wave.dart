import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A live "room volume" meter — a row of rounded bars whose heights ripple into
/// a travelling wave, centred on the midline like a classic audio equaliser.
///
/// It reads the room rather than any real microphone: [level] (0→1) sets how
/// tall/energetic the wave is and [color] tints it (typically the current
/// speaker's colour, or the alert red when the ref is on edge). Both ease when
/// they change so speaker hand-offs and cut-ins glide instead of snapping. A
/// single always-running controller drives the horizontal travel.
class VolumeWave extends StatefulWidget {
  const VolumeWave({
    super.key,
    required this.color,
    required this.level,
    this.height = 38,
  });

  /// Bar colour — eases toward this value over [_kEase].
  final Color color;

  /// Room energy, 0 (near-silent) → 1 (loud). Eases toward this value.
  final double level;

  /// Overall height of the meter.
  final double height;

  @override
  State<VolumeWave> createState() => _VolumeWaveState();
}

/// How long colour/level changes take to ease in — matches the beat-driven
/// transitions elsewhere in the scene.
const Duration _kEase = Duration(milliseconds: 600);

class _VolumeWaveState extends State<VolumeWave>
    with SingleTickerProviderStateMixin {
  // Continuous 0→1 phase that scrolls the wave sideways.
  late final AnimationController _travel;

  @override
  void initState() {
    super.initState();
    _travel = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ease colour, then level, then repaint every frame on the travel phase.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.color),
      duration: _kEase,
      curve: Curves.easeOut,
      builder: (context, color, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: widget.level.clamp(0.0, 1.0)),
        duration: _kEase,
        curve: Curves.easeOut,
        builder: (context, level, _) => SizedBox(
          height: widget.height,
          child: AnimatedBuilder(
            animation: _travel,
            builder: (context, _) => CustomPaint(
              size: Size.infinite,
              painter: _WavePainter(
                phase: _travel.value,
                level: level,
                color: color ?? widget.color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.phase,
    required this.level,
    required this.color,
  });

  /// 0→1 horizontal travel of the wave.
  final double phase;

  /// Eased room energy, 0→1.
  final double level;

  /// Eased bar colour.
  final Color color;

  static const int _barCount = 27;
  static const double _gap = 3;
  static const double _minBar = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth =
        ((size.width - _gap * (_barCount - 1)) / _barCount).clamp(1.0, 20.0);
    final midY = size.height / 2;
    final travel = phase * 2 * math.pi;
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < _barCount; i++) {
      final t = i / (_barCount - 1); // 0→1 across the meter.

      // Two harmonics scrolling in opposite-ish phases read as an organic
      // wave rather than a rigid sine.
      final wave = 0.6 * math.sin(t * math.pi * 4 - travel) +
          0.4 * math.sin(t * math.pi * 2 - travel * 0.6);
      final unit = 0.5 + 0.5 * wave; // 0→1.

      // Taper the ends to zero so the wave fades in/out at the edges.
      final envelope = math.sin(t * math.pi);
      final strength = unit * envelope * level;

      final barHeight =
          (_minBar + (size.height - _minBar) * strength).clamp(_minBar, size.height);

      final x = i * (barWidth + _gap);
      final rect = Rect.fromLTWH(
        x,
        midY - barHeight / 2,
        barWidth,
        barHeight,
      );
      // Quiet bars fade back; loud crests glow toward full colour.
      paint.color = color.withValues(alpha: 0.3 + 0.7 * strength);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.phase != phase || old.level != level || old.color != color;
}
