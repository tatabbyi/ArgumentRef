import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

abstract interface class CompromiseSoundPlayer {
  Future<void> playCompromiseFound();

  Future<void> dispose();
}

class SilentCompromiseSoundPlayer implements CompromiseSoundPlayer {
  const SilentCompromiseSoundPlayer();

  @override
  Future<void> playCompromiseFound() async {}

  @override
  Future<void> dispose() async {}
}

class RefereeWhistlePlayer implements CompromiseSoundPlayer {
  RefereeWhistlePlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  static const assetPath = 'audio/referee_whistle.mp3';

  final AudioPlayer _player;
  bool _disposed = false;

  @override
  Future<void> playCompromiseFound() async {
    if (_disposed) return;

    try {
      await _player.stop();
      await _player.play(AssetSource(assetPath));
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Could not play compromise whistle at assets/$assetPath: $error',
        );
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
