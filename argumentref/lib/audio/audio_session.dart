import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/backend_config.dart';
import 'ref_events.dart';

/// The lifecycle of a single live audio stream.
enum AudioSessionStatus {
  idle,
  requestingPermission,
  permissionDenied,
  connecting,
  streaming,
  error,
  ended,
}

/// Captures raw PCM16 microphone audio and streams it as **binary** WebSocket
/// frames to the backend `/v1/audio` endpoint, while surfacing the JSON events
/// the server sends back (session/transcription/transcript) as typed
/// [RefEvent]s.
///
/// This is the piece the "stream microphone audio as binary PCM16 chunks"
/// instruction was asking for: wscat only proved the connection; this actually
/// pushes bytes.
class AudioSession {
  AudioSession({
    required this.sessionId,
    required this.participantId,
    this.sampleRateHz = 16000,
    this.channels = 1,
    this.speakerLabels = const [],
    AudioRecorder? recorder,
  }) : _injectedRecorder = recorder;

  final String sessionId;
  final String participantId;

  /// PCM sample rate. Kept at 16 kHz mono — plenty for speech, cheap to stream,
  /// and what the backend/Deepgram config expects.
  final int sampleRateHz;
  final int channels;
  final List<String> speakerLabels;

  // Created lazily on [start] so merely constructing a session (e.g. in a unit
  // test) never touches the platform recorder plugin.
  final AudioRecorder? _injectedRecorder;
  AudioRecorder? _recorder;
  AudioRecorder get _recorderOrCreate =>
      _recorder ??= (_injectedRecorder ?? AudioRecorder());

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _flushTimer;
  bool _closed = false;

  /// Trailing mic bytes not yet flushed to the socket.
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Flush once we've buffered ~100 ms of audio (16000 * 2 bytes * 0.1 s), so we
  /// send a steady handful of sensibly-sized binary frames rather than a flood
  /// of tiny ones.
  static const int _flushThresholdBytes = 3200;

  final StreamController<RefEvent> _events =
      StreamController<RefEvent>.broadcast();

  /// Parsed events streamed back from the server.
  Stream<RefEvent> get events => _events.stream;

  final ValueNotifier<AudioSessionStatus> statusListenable =
      ValueNotifier<AudioSessionStatus>(AudioSessionStatus.idle);

  AudioSessionStatus get status => statusListenable.value;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  final ValueNotifier<double> loudnessListenable = ValueNotifier<double>(0);

  /// Smoothed microphone loudness, normalized to 0 (quiet) through 1 (loud).
  double get loudnessLevel => loudnessListenable.value;

  /// Requests mic permission, opens the socket, and starts streaming. Safe to
  /// await; on failure it lands in [AudioSessionStatus.permissionDenied] or
  /// [AudioSessionStatus.error] rather than throwing.
  Future<void> start() async {
    if (_closed) return;
    _setStatus(AudioSessionStatus.requestingPermission);

    final bool granted;
    try {
      granted = await _recorderOrCreate.hasPermission();
    } catch (error) {
      _fail('Could not access the microphone: $error');
      return;
    }
    if (!granted) {
      _setStatus(AudioSessionStatus.permissionDenied);
      return;
    }
    if (_closed) return;

    _setStatus(AudioSessionStatus.connecting);
    try {
      final channel = WebSocketChannel.connect(
        BackendConfig.audioUri(
          sessionId: sessionId,
          participantId: participantId,
          sampleRateHz: sampleRateHz,
          channels: channels,
          speakerLabels: speakerLabels,
        ),
      );
      _channel = channel;
      await channel.ready;
      if (_closed) {
        await _teardown();
        return;
      }

      _wsSub = channel.stream.listen(
        _onServerFrame,
        onError: (Object error) => _fail('Stream error: $error'),
        onDone: _onServerDone,
      );

      final micStream = await _recorderOrCreate.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRateHz,
          numChannels: channels,
        ),
      );
      if (_closed) {
        await _teardown();
        return;
      }

      _micSub = micStream.listen(
        _onMicData,
        onError: (Object error) => debugPrint('mic stream error: $error'),
      );
      // Backstop flush so trailing audio during pauses still goes out.
      _flushTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _flush(),
      );

      _setStatus(AudioSessionStatus.streaming);
    } catch (error) {
      _fail('Could not start streaming: $error');
    }
  }

  /// Stops the mic, sends `session.stop`, and closes the socket. Idempotent.
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;

    _flushTimer?.cancel();
    _flushTimer = null;

    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}

    // Push any trailing audio, then politely end the session, before we close.
    _flush();
    _sendControl(const {'type': 'session.stop'});
    loudnessListenable.value = 0;

    await _teardown();
    if (status != AudioSessionStatus.error &&
        status != AudioSessionStatus.permissionDenied) {
      _setStatus(AudioSessionStatus.ended);
    }
  }

  /// Releases the recorder and all stream resources. Call once when done.
  Future<void> dispose() async {
    await stop();
    try {
      await _recorder?.dispose();
    } catch (_) {}
    if (!_events.isClosed) await _events.close();
    loudnessListenable.dispose();
    statusListenable.dispose();
  }

  // ── internals ──────────────────────────────────────────────────────────

  void _onMicData(Uint8List data) {
    if (_closed) return;
    _updateLoudness(data);
    _pending.add(data);
    if (_pending.length >= _flushThresholdBytes) {
      _flush();
    }
  }

  void _updateLoudness(Uint8List data) {
    final sampleCount = data.lengthInBytes ~/ 2;
    if (sampleCount == 0) return;

    final bytes = ByteData.sublistView(data);
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = bytes.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }

    final rms = math.sqrt(sumSquares / sampleCount);
    final instant = (rms * 8.0).clamp(0.0, 1.0);
    final current = loudnessLevel;
    final smoothing = instant > current ? 0.45 : 0.16;
    final next = current + (instant - current) * smoothing;

    if ((next - current).abs() > 0.01) {
      loudnessListenable.value = next;
    }
  }

  void _flush() {
    if (_pending.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    final chunk = _pending.takeBytes();
    try {
      // A Uint8List (List<int>) is sent as a binary frame — exactly the PCM16
      // bytes the backend forwards to Deepgram.
      channel.sink.add(chunk);
    } catch (error) {
      debugPrint('failed to send audio chunk: $error');
    }
  }

  void _sendControl(Map<String, Object?> message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {}
  }

  void _onServerFrame(dynamic frame) {
    if (frame is String) {
      if (!_events.isClosed) _events.add(RefEvent.parse(frame));
    }
    // Binary frames from the server aren't part of the protocol; ignore.
  }

  void _onServerDone() {
    if (_closed) return;
    // Server closed the socket on us (e.g. after session.ended). Treat as ended.
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_micSub?.cancel());
    _micSub = null;
    final recorder = _recorder;
    if (recorder != null) unawaited(recorder.stop().catchError((_) => null));
    if (status == AudioSessionStatus.streaming ||
        status == AudioSessionStatus.connecting) {
      _setStatus(AudioSessionStatus.ended);
    }
  }

  Future<void> _teardown() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
  }

  void _fail(String message) {
    _errorMessage = message;
    _setStatus(AudioSessionStatus.error);
    unawaited(_teardown());
  }

  void _setStatus(AudioSessionStatus value) {
    if (statusListenable.value == value) return;
    statusListenable.value = value;
  }
}
