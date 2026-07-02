import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/backend_config.dart';

/// Reads the referee's live guidance — the line shown in the "the ref says"
/// bubble — aloud.
///
/// Mirrors [CompromiseSoundPlayer]: an interface with a real implementation and
/// a silent no-op so the controller and tests can run without touching the
/// network or a platform audio player.
abstract interface class RefVoice {
  /// Speak [text]. Implementations dedupe identical consecutive lines and let a
  /// newer line replace one that's still being fetched/played, so the ref only
  /// ever voices its latest call.
  Future<void> speak(String text);

  Future<void> dispose();
}

/// Says nothing. The default so voice is strictly opt-in.
class SilentRefVoice implements RefVoice {
  const SilentRefVoice();

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> dispose() async {}
}

/// Fetches ElevenLabs speech from the backend `POST /v1/speech` endpoint and
/// plays the returned MP3 through [audioplayers].
///
/// Failures (no backend key, network error, playback error) are swallowed with
/// a debug log — a missing voice must never disrupt the live referee, exactly
/// like the whistle in [RefereeWhistlePlayer].
class ElevenLabsRefVoice implements RefVoice {
  ElevenLabsRefVoice({AudioPlayer? player, http.Client? client})
    : _player = player ?? AudioPlayer(),
      _client = client ?? http.Client();

  final AudioPlayer _player;
  final http.Client _client;
  bool _disposed = false;

  /// The last line we started speaking, so a caption that redraws without
  /// changing text doesn't stutter the audio.
  String? _lastSpoken;

  /// Bumped on every [speak] so a slow synthesis that resolves after a newer
  /// line was requested is discarded instead of playing stale guidance.
  int _requestId = 0;

  @override
  Future<void> speak(String text) async {
    final line = text.trim();
    if (_disposed || line.isEmpty || line == _lastSpoken) return;
    _lastSpoken = line;
    final requestId = ++_requestId;

    final Uint8List audio;
    try {
      final response = await _client
          .post(
            BackendConfig.speechUri(),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'text': line}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
            'Ref voice request failed (${response.statusCode}): '
            '${response.body}',
          );
        }
        return;
      }
      audio = response.bodyBytes;
    } catch (error) {
      if (kDebugMode) debugPrint('Ref voice request error: $error');
      return;
    }

    // A newer line was requested (or we were torn down) while synthesizing —
    // drop this one rather than talk over the ref's latest call.
    if (_disposed || requestId != _requestId) return;

    try {
      await _player.stop();
      await _player.play(BytesSource(audio, mimeType: 'audio/mpeg'));
    } catch (error) {
      if (kDebugMode) debugPrint('Ref voice playback error: $error');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _client.close();
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
