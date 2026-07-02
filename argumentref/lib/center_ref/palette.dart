import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Whistle & Warmth" palette — the warm-modern direction the Center Ref
/// design (variant 2a) is skinned in.
///
/// Values are lifted verbatim from the design prototype
/// (`Conversation Referee Variants.dc.html`).
abstract final class RefPalette {
  /// Screen background — warm cream.
  static const cream = Color(0xFFFBF3E7);

  /// Primary ink / text colour.
  static const ink = Color(0xFF3A2E28);

  /// Maya's colour — muted olive green.
  static const green = Color(0xFF8A9A5B);

  /// Devin's colour / warm accent — amber orange.
  static const orange = Color(0xFFE8963C);

  /// Alert / live / interruption colour — terracotta red.
  static const red = Color(0xFFC1502E);

  /// Referee skin tone.
  static const skin = Color(0xFFE0AC80);

  /// Cap crown.
  static const cap = Color(0xFF2F2621);

  /// Cap band and brows — near-black.
  static const capBand = Color(0xFF241C18);

  /// Eye whites.
  static const eyeWhite = Color(0xFFFFFDF8);

  /// "Room tone" text — darker olive for legibility.
  static const olive = Color(0xFF6F7D49);
}

/// Zilla Slab — the display/slab face used for the wordmark, avatar initials,
/// speaker names, the live caption and the numeric read-outs.
TextStyle zilla({
  required double size,
  FontWeight weight = FontWeight.w400,
  Color color = RefPalette.ink,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.zillaSlab(
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Mulish — the workhorse sans used for labels and supporting copy.
TextStyle mulish({
  required double size,
  FontWeight weight = FontWeight.w400,
  Color color = RefPalette.ink,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.mulish(
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}
