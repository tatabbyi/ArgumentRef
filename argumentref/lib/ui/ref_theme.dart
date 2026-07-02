import 'package:flutter/material.dart';

import '../center_ref/palette.dart';

export '../center_ref/palette.dart';

/// A speech bubble the referee "says" — the warm orange→terracotta gradient
/// lifted from the 1a "drifting nudge", with an upward pointer so it reads as
/// coming from the ref drawn above it.
class RefSpeechBubble extends StatelessWidget {
  const RefSpeechBubble({
    super.key,
    required this.text,
    this.eyebrow = '⚑ THE REF SAYS',
    this.pointDown = false,
    this.compact = false,
  });

  final String text;
  final String eyebrow;

  /// When true the tail sits *below* the bubble and points down — use when the
  /// bubble is drawn above the referee, so it still reads as his call. Defaults
  /// to pointing up (bubble below the ref).
  final bool pointDown;

  /// A tighter variant — smaller padding and text — for space-constrained
  /// screens like onboarding.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(15, 11, 15, 12)
          : const EdgeInsets.fromLTRB(18, 15, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compact ? 16 : 20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            RefPalette.orange.withValues(alpha: 0.96),
            RefPalette.red.withValues(alpha: 0.92),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: RefPalette.red.withValues(alpha: 0.28),
            blurRadius: compact ? 18 : 26,
            offset: Offset(0, compact ? 8 : 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: mulish(
              size: compact ? 9 : 10,
              weight: FontWeight.w800,
              letterSpacing: (compact ? 9 : 10) * 0.16,
              color: RefPalette.cream.withValues(alpha: 0.9),
            ),
          ),
          SizedBox(height: compact ? 5 : 7),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: Text(
              text,
              key: ValueKey(text),
              style: zilla(
                size: compact ? 15 : 18,
                weight: FontWeight.w500,
                color: RefPalette.cream,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );

    // The tail blends into whichever edge of the gradient it hugs — orange at
    // the top, terracotta at the bottom.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: pointDown
          ? [
              bubble,
              const CustomPaint(
                size: Size(20, 9),
                painter: _BubblePointer(down: true),
              ),
            ]
          : [
              const CustomPaint(
                size: Size(20, 9),
                painter: _BubblePointer(down: false),
              ),
              bubble,
            ],
    );
  }
}

class _BubblePointer extends CustomPainter {
  const _BubblePointer({required this.down});

  final bool down;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (down ? RefPalette.red : RefPalette.orange)
          .withValues(alpha: down ? 0.92 : 0.96);
    final path = Path();
    if (down) {
      // Apex at the bottom, base along the top — points down at the ref.
      path
        ..moveTo(size.width / 2, size.height)
        ..lineTo(size.width, 0)
        ..lineTo(0, 0)
        ..close();
    } else {
      // Apex at the top, base along the bottom — points up at the ref.
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BubblePointer oldDelegate) => oldDelegate.down != down;
}

/// The primary call-to-action — a solid ink pill with cream lettering.
/// A null [onPressed] renders it disabled.
class RefPrimaryButton extends StatelessWidget {
  const RefPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.expand = true,
    this.color = RefPalette.ink,
    this.borderRadius = 16,
    this.fontSize = 16,
    this.verticalPadding = 15,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;

  /// Fill colour of the pill. Defaults to ink; pass e.g. [RefPalette.red] for a
  /// destructive action like ending a session.
  final Color color;

  /// Corner radius of the pill.
  final double borderRadius;

  /// Label size — the "Clean & Airy" (3b) call-to-action runs a touch larger.
  final double fontSize;

  /// Vertical padding, i.e. the pill's height above/below the label.
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled ? color : color.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(borderRadius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          width: expand ? double.infinity : null,
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: verticalPadding),
          alignment: Alignment.center,
          child: Text(
            label,
            style: zilla(
              size: fontSize,
              weight: FontWeight.w600,
              color: RefPalette.cream.withValues(alpha: enabled ? 1 : 0.6),
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet, underline-free text action — used for "skip" / "add later".
class RefTextAction extends StatelessWidget {
  const RefTextAction({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          label,
          style: mulish(
            size: 14,
            weight: FontWeight.w600,
            color: RefPalette.ink.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// A selectable pill. Fills with [accent] when [selected], otherwise reads as a
/// soft outlined chip.
class RefChip extends StatelessWidget {
  const RefChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent = RefPalette.orange,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;

  /// A more compact variant — smaller padding and text, for tight rows of
  /// many options.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: dense
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent : RefPalette.ink.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? accent
                : RefPalette.ink.withValues(alpha: 0.14),
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: mulish(
            size: dense ? 12.5 : 13.5,
            weight: FontWeight.w600,
            color: selected ? RefPalette.cream : RefPalette.ink,
          ),
        ),
      ),
    );
  }
}

/// A themed single-line text input on a soft card.
class RefTextField extends StatelessWidget {
  const RefTextField({
    super.key,
    required this.controller,
    this.hint = '',
    this.autofocus = false,
    this.textInputAction = TextInputAction.done,
    this.textCapitalization = TextCapitalization.words,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final TextInputAction textInputAction;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7F0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RefPalette.ink.withValues(alpha: 0.12)),
      ),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        cursorColor: RefPalette.orange,
        style: mulish(size: 16, weight: FontWeight.w600, color: RefPalette.ink),
        decoration: InputDecoration.collapsed(
          hintText: hint,
          hintStyle: mulish(
            size: 16,
            color: RefPalette.ink.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }
}

/// The step indicator — a row of dots with the current one stretched to a pill.
class RefProgressDots extends StatelessWidget {
  const RefProgressDots({
    super.key,
    required this.count,
    required this.index,
  });

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 20 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: active
                ? RefPalette.orange
                : RefPalette.ink.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

/// The compact wordmark used on the welcome & splash surfaces.
class RefWordmark extends StatelessWidget {
  const RefWordmark({super.key, this.showLiveDot = false});

  final bool showLiveDot;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'CONVERSATION REFEREE',
          style: zilla(
            size: 13,
            weight: FontWeight.w700,
            letterSpacing: 13 * 0.16,
          ),
        ),
        if (showLiveDot) ...[
          const SizedBox(width: 8),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: RefPalette.red,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}
