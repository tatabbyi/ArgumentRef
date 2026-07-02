import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'beats.dart';
import 'palette.dart';
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

/// A small, static head-only referee "avatar" — the cap, brim, eyes and a
/// smile, with no body, whistle or animation. Drawn at a 46×46 base and scaled
/// to [size] via a [FittedBox], so it stays crisp at any size.
///
/// Coordinates are lifted verbatim from the compact ref header in the design
/// prototype (variants 1a / 3b), where the full [RefereeGuide] body would be
/// too much.
class RefHeadBadge extends StatelessWidget {
  const RefHeadBadge({super.key, this.size = 46});

  /// Rendered edge length in logical pixels (the drawing is square).
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Stack(
            children: [
              // Face.
              Positioned(
                left: 3,
                top: 7,
                child: Container(
                  width: 40,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: RefPalette.skin,
                    borderRadius: BorderRadius.all(Radius.elliptical(20, 19)),
                  ),
                ),
              ),
              // Cap crown.
              Positioned(
                left: 4,
                top: 0,
                child: Container(
                  width: 38,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: RefPalette.cap,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(6),
                      bottomRight: Radius.circular(6),
                    ),
                  ),
                ),
              ),
              // Orange band.
              Positioned(
                left: 4,
                top: 12,
                child: Container(width: 38, height: 4, color: RefPalette.orange),
              ),
              // Brim.
              Positioned(
                left: 0,
                top: 15,
                child: Container(
                  width: 46,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: RefPalette.capBand,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(3),
                      topRight: Radius.circular(3),
                      bottomLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
                  ),
                ),
              ),
              // Eyes.
              const Positioned(left: 16, top: 26, child: _EyeDot()),
              const Positioned(left: 26, top: 26, child: _EyeDot()),
              // Smile.
              const Positioned(
                left: 18,
                top: 32,
                child: CustomPaint(
                  size: Size(11, 6),
                  painter: _BadgeSmilePainter(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EyeDot extends StatelessWidget {
  const _EyeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: const BoxDecoration(
        color: RefPalette.ink,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The little upturned mouth on [RefHeadBadge] — a shallow smile stroked to
/// mirror the prototype's rounded bottom border.
class _BadgeSmilePainter extends CustomPainter {
  const _BadgeSmilePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = RefPalette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(1, 1)
      ..quadraticBezierTo(size.width / 2, size.height + 3, size.width - 1, 1);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BadgeSmilePainter oldDelegate) => false;
}
