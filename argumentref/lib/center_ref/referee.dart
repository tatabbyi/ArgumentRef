import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'beats.dart';
import 'palette.dart';

/// The referee character — a self-contained 200×250 drawing rebuilt element for
/// element from the design prototype's absolute-positioned markup.
///
/// The character is a pure function of the current [beat] plus three live
/// signals: [blinking] (lids snap shut), [saccadeJitter] (a tiny horizontal eye
/// tremor) and two continuous drivers, [breathe] and [sway]. Every beat-driven
/// change eases with the same durations the CSS transitions used.
class RefereeFace extends StatelessWidget {
  const RefereeFace({
    super.key,
    required this.beat,
    required this.blinking,
    required this.saccadeJitter,
    required this.breathe,
    required this.sway,
  });

  final Beat beat;
  final bool blinking;
  final double saccadeJitter;

  /// 0→1 breathing driver (whole body lifts and swells a touch).
  final Animation<double> breathe;

  /// 0→1 sway driver (head rocks about the neck).
  final Animation<double> sway;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: breathe,
      builder: (context, child) {
        final v = breathe.value;
        // cr-breathe: translateY(-3px) + scale(1.012) at the peak.
        return Transform.translate(
          offset: Offset(0, -3 * v),
          child: Transform.scale(scale: 1 + 0.012 * v, child: child),
        );
      },
      child: SizedBox(
        width: 200,
        height: 250,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Jersey — black/cream referee stripes.
            const Positioned(
              left: 10,
              top: 182,
              width: 180,
              height: 68,
              child: _Jersey(),
            ),
            // Neck.
            Positioned(
              left: 84,
              top: 162,
              child: Container(width: 32, height: 28, color: RefPalette.skin),
            ),
            // Whistle cords.
            const Positioned(left: 78, top: 186, child: _Cord(angleDeg: 20)),
            const Positioned(left: 117, top: 186, child: _Cord(angleDeg: -20)),
            // Whistle (glows when the ref is about to intervene).
            Positioned(
              left: 89,
              top: 212,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 22,
                height: 15,
                decoration: BoxDecoration(
                  color: RefPalette.orange,
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: beat.whistleGlow
                      ? [
                          BoxShadow(
                            color: RefPalette.red.withValues(alpha: 0.85),
                            blurRadius: 16,
                            spreadRadius: 5,
                          ),
                        ]
                      : const [],
                ),
              ),
            ),
            // Head — continuous sway about the neck, then the beat's tilt/bob.
            Positioned(
              left: 0,
              top: 0,
              width: 200,
              height: 190,
              child: AnimatedBuilder(
                animation: sway,
                builder: (context, child) {
                  // cr-sway: -1.4deg → +1.4deg → -1.4deg about the neck.
                  final deg = _lerp(-1.4, 1.4, sway.value);
                  return Transform.rotate(
                    angle: deg * math.pi / 180,
                    alignment: Alignment.bottomCenter,
                    child: child,
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                  transform: Matrix4.translationValues(0, beat.headTransY, 0),
                  child: AnimatedRotation(
                    turns: beat.headRotDeg / 360,
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                    alignment: Alignment.bottomCenter,
                    child: _HeadParts(
                      beat: beat,
                      blinking: blinking,
                      saccadeJitter: saccadeJitter,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Everything above the neck, in the head's 200×190 coordinate space.
class _HeadParts extends StatelessWidget {
  const _HeadParts({
    required this.beat,
    required this.blinking,
    required this.saccadeJitter,
  });

  final Beat beat;
  final bool blinking;
  final double saccadeJitter;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 190,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Face sits under the cap so the hat reads as resting on the head.
          Positioned(
            left: 36,
            top: 34,
            child: Container(
              width: 128,
              height: 128,
              decoration: const BoxDecoration(
                color: RefPalette.skin,
                shape: BoxShape.circle,
              ),
            ),
          ),
          // Cap crown.
          Positioned(
            left: 44,
            top: 14,
            child: Container(
              width: 112,
              height: 56,
              decoration: const BoxDecoration(
                color: RefPalette.cap,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(56),
                  topRight: Radius.circular(56),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
            ),
          ),
          // Cap button.
          Positioned(
            left: 94,
            top: 8,
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: RefPalette.cap,
                shape: BoxShape.circle,
              ),
            ),
          ),
          // Cap stripe.
          const Positioned(
            left: 44,
            top: 52,
            child: SizedBox(
              width: 112,
              height: 9,
              child: ColoredBox(color: RefPalette.orange),
            ),
          ),
          // Cap band.
          Positioned(
            left: 28,
            top: 60,
            child: Container(
              width: 144,
              height: 22,
              decoration: const BoxDecoration(
                color: RefPalette.capBand,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(6),
                  bottomLeft: Radius.circular(22),
                  bottomRight: Radius.circular(22),
                ),
              ),
            ),
          ),
          // Brows.
          Positioned(
            left: 62,
            top: 86,
            child: _Brow(rotDeg: beat.browLeftDeg, transY: beat.browTransY),
          ),
          Positioned(
            left: 106,
            top: 86,
            child: _Brow(rotDeg: beat.browRightDeg, transY: beat.browTransY),
          ),
          // Left eye: white, pupil, lid.
          const Positioned(left: 64, top: 98, child: _EyeWhite()),
          Positioned(
            left: 72,
            top: 109,
            child: _Pupil(dx: beat.eyeDx + saccadeJitter, dy: beat.eyeDy),
          ),
          Positioned(
            left: 64,
            top: 98,
            child: _Lid(open: blinking ? 1.0 : beat.lidRest),
          ),
          // Right eye: white, pupil, lid.
          const Positioned(left: 106, top: 98, child: _EyeWhite()),
          Positioned(
            left: 114,
            top: 109,
            child: _Pupil(dx: beat.eyeDx + saccadeJitter, dy: beat.eyeDy),
          ),
          Positioned(
            left: 106,
            top: 98,
            child: _Lid(open: blinking ? 1.0 : beat.lidRest),
          ),
          // Cheeks.
          const Positioned(left: 52, top: 126, child: _Cheek()),
          const Positioned(left: 130, top: 126, child: _Cheek()),
          // Mouth — only the active shape is drawn.
          _mouth(beat.mouth),
        ],
      ),
    );
  }

  Widget _mouth(MouthShape shape) {
    switch (shape) {
      case MouthShape.neutral:
        return Positioned(
          left: 84,
          top: 150,
          child: Container(
            width: 32,
            height: 7,
            decoration: BoxDecoration(
              color: RefPalette.ink,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      case MouthShape.tense:
        return Positioned(
          left: 82,
          top: 152,
          child: Container(
            width: 36,
            height: 6,
            decoration: BoxDecoration(
              color: RefPalette.ink,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      case MouthShape.o:
        return Positioned(
          left: 91,
          top: 146,
          child: Container(
            width: 18,
            height: 22,
            decoration: const BoxDecoration(
              color: RefPalette.ink,
              borderRadius: BorderRadius.all(Radius.elliptical(9, 11)),
            ),
          ),
        );
      case MouthShape.smile:
        return const Positioned(
          left: 78,
          top: 142,
          child: CustomPaint(
            size: Size(44, 22),
            painter: _MouthArcPainter(smile: true),
          ),
        );
      case MouthShape.frown:
        return const Positioned(
          left: 80,
          top: 150,
          child: CustomPaint(
            size: Size(40, 20),
            painter: _MouthArcPainter(smile: false),
          ),
        );
    }
  }
}

/// A brow bar: eases both its rotation (about its centre) and a shared vertical
/// nudge, matching the prototype's `transition: transform .45s`.
class _Brow extends StatelessWidget {
  const _Brow({required this.rotDeg, required this.transY});

  final double rotDeg;
  final double transY;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOut,
      transform: Matrix4.translationValues(0, transY, 0),
      child: AnimatedRotation(
        turns: rotDeg / 360,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
        child: Container(
          width: 32,
          height: 9,
          decoration: BoxDecoration(
            color: RefPalette.capBand,
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      ),
    );
  }
}

class _EyeWhite extends StatelessWidget {
  const _EyeWhite();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 34,
      decoration: const BoxDecoration(
        color: RefPalette.eyeWhite,
        shape: BoxShape.circle,
        // Approximates the prototype's subtle inset top shadow.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [Color(0x14000000), Color(0x00000000)],
        ),
      ),
    );
  }
}

/// The pupil — eases toward the active speaker (plus saccade jitter) over .35s.
class _Pupil extends StatelessWidget {
  const _Pupil({required this.dx, required this.dy});

  final double dx;
  final double dy;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      transform: Matrix4.translationValues(dx, dy, 0),
      width: 14,
      height: 14,
      decoration: const BoxDecoration(
        color: RefPalette.ink,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// The eyelid — a skin-coloured shutter that scales down from the top.
/// [open] is the vertical scale: 0 = fully open, 1 = closed.
class _Lid extends StatelessWidget {
  const _Lid({required this.open});

  final double open;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      transformAlignment: Alignment.topCenter,
      transform: Matrix4.diagonal3Values(1, open.clamp(0.0, 1.0), 1),
      width: 30,
      height: 34,
      decoration: const BoxDecoration(
        color: RefPalette.skin,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _Cheek extends StatelessWidget {
  const _Cheek();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 10,
      decoration: BoxDecoration(
        color: RefPalette.orange.withValues(alpha: 0.32),
        borderRadius: const BorderRadius.all(Radius.elliptical(9, 5)),
      ),
    );
  }
}

/// A whistle cord — a thin bar pinned at its top and splayed outward.
class _Cord extends StatelessWidget {
  const _Cord({required this.angleDeg});

  final double angleDeg;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angleDeg * math.pi / 180,
      alignment: Alignment.topCenter,
      child: const SizedBox(
        width: 5,
        height: 32,
        child: ColoredBox(color: RefPalette.red),
      ),
    );
  }
}

/// The striped referee jersey/shoulders.
class _Jersey extends StatelessWidget {
  const _Jersey();

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.only(
      topLeft: Radius.circular(44),
      topRight: Radius.circular(44),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: RefPalette.ink.withValues(alpha: 0.1)),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: const CustomPaint(
          size: Size(180, 68),
          painter: _StripePainter(),
        ),
      ),
    );
  }
}

/// Paints repeating vertical bands: 12px ink, 12px cream — the prototype's
/// `repeating-linear-gradient(90deg,#3A2E28 0 12px,#FBF3E7 12px 24px)`.
class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    const band = 12.0;
    final ink = Paint()..color = RefPalette.ink;
    final cream = Paint()..color = RefPalette.cream;
    for (double x = 0; x < size.width; x += band * 2) {
      canvas.drawRect(Rect.fromLTWH(x, 0, band, size.height), ink);
      canvas.drawRect(
        Rect.fromLTWH(x + band, 0, band, size.height),
        cream,
      );
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => false;
}

/// Draws the smile (opens up) or frown (opens down) mouth arc.
class _MouthArcPainter extends CustomPainter {
  const _MouthArcPainter({required this.smile});

  final bool smile;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = RefPalette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    final path = Path();
    if (smile) {
      // Endpoints ride the top corners; the curve dips at the centre.
      path
        ..moveTo(2, 2)
        ..quadraticBezierTo(w / 2, h + 8, w - 2, 2);
    } else {
      // Endpoints ride the bottom corners; the curve arches over the centre.
      path
        ..moveTo(2, h - 2)
        ..quadraticBezierTo(w / 2, -8, w - 2, h - 2);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MouthArcPainter oldDelegate) =>
      oldDelegate.smile != smile;
}
