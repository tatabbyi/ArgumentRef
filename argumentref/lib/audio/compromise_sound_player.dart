import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

abstract interface class CompromiseSoundPlayer {
  Future<void> playCompromiseFound();

  Future<void> dispose();
}

abstract interface class TimeOutSoundPlayer {
  Future<void> startTimeOutLoop();

  Future<void> stopTimeOutLoop();

  Future<void> dispose();
}

class SilentCompromiseSoundPlayer implements CompromiseSoundPlayer {
  const SilentCompromiseSoundPlayer();

  @override
  Future<void> playCompromiseFound() async {}

  @override
  Future<void> dispose() async {}
}

class SilentTimeOutSoundPlayer implements TimeOutSoundPlayer {
  const SilentTimeOutSoundPlayer();

  @override
  Future<void> startTimeOutLoop() async {}

  @override
  Future<void> stopTimeOutLoop() async {}

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

class LongWhiteTimeOutPlayer implements TimeOutSoundPlayer {
  LongWhiteTimeOutPlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  static const assetPath = 'audio/long_white.mp3';

  final AudioPlayer _player;
  bool _disposed = false;
  bool _looping = false;

  @override
  Future<void> startTimeOutLoop() async {
    if (_disposed || _looping) return;
    _looping = true;

    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource(assetPath));
    } catch (error) {
      _looping = false;
      if (kDebugMode) {
        debugPrint(
          'Could not play timeout whistle at assets/$assetPath: $error',
        );
      }
    }
  }

  @override
  Future<void> stopTimeOutLoop() async {
    if (_disposed || !_looping) return;
    _looping = false;

    try {
      await _player.stop();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Could not stop timeout whistle: $error');
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _looping = false;
    try {
      await _player.stop();
      await _player.dispose();
    } catch (_) {}
  }
}
