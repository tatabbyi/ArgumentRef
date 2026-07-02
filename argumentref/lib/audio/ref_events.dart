import 'dart:convert';

/// A parsed event coming *back* from the backend over the /v1/audio WebSocket.
///
/// The server sends these as JSON text frames (see `protocol/messages.ts`); we
/// only model the ones the app actually reacts to and collapse the rest into
/// [UnknownEvent]. Kept dependency-free (only `dart:convert`) so it can be
/// unit-tested without a Flutter binding.
sealed class RefEvent {
  const RefEvent();

  /// Parse one server text frame. Never throws — malformed frames become an
  /// [UnknownEvent] so a bad packet can't tear down the stream.
  factory RefEvent.parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return UnknownEvent('<invalid-json>');
    }
    if (decoded is! Map<String, dynamic>) {
      return UnknownEvent('<non-object>');
    }

    final type = decoded['type'] as String? ?? '';
    switch (type) {
      case 'session.started':
        return SessionStartedEvent(
          sessionId: _str(decoded['sessionId']),
          streamId: _str(decoded['streamId']),
          participantId: _str(decoded['participantId']),
        );
      case 'audio.ack':
        return AudioAckEvent(
          bytesReceived: _int(decoded['bytesReceived']),
          chunksReceived: _int(decoded['chunksReceived']),
        );
      case 'transcription.connected':
        return TranscriptionConnectedEvent(
          model: _str(decoded['model']),
          language: _str(decoded['language']),
        );
      case 'transcription.disabled':
        return TranscriptionDisabledEvent(_str(decoded['reason']));
      case 'transcription.error':
        return TranscriptionErrorEvent(_str(decoded['message']));
      case 'transcript.partial':
      case 'transcript.final':
        return TranscriptEvent(
          isFinal: type == 'transcript.final',
          speaker: _str(decoded['speaker'], fallback: 'speaker_unknown'),
          text: _str(decoded['text']).trim(),
          confidence: _doubleOrNull(decoded['confidence']),
        );
      case 'session.ended':
        return SessionEndedEvent(
          bytesReceived: _int(decoded['bytesReceived']),
          chunksReceived: _int(decoded['chunksReceived']),
        );
      case 'error':
        return RefErrorEvent(
          code: _str(decoded['code'], fallback: 'error'),
          message: _str(decoded['message']),
        );
      default:
        return UnknownEvent(type);
    }
  }
}

/// The stream is live; storage + ids are assigned.
class SessionStartedEvent extends RefEvent {
  const SessionStartedEvent({
    required this.sessionId,
    required this.streamId,
    required this.participantId,
  });

  final String sessionId;
  final String streamId;
  final String participantId;
}

/// Per-chunk receipt — running byte/chunk totals. Useful as a "bytes are
/// actually arriving" heartbeat.
class AudioAckEvent extends RefEvent {
  const AudioAckEvent({
    required this.bytesReceived,
    required this.chunksReceived,
  });

  final int bytesReceived;
  final int chunksReceived;
}

/// Deepgram is connected and will emit transcripts.
class TranscriptionConnectedEvent extends RefEvent {
  const TranscriptionConnectedEvent({
    required this.model,
    required this.language,
  });

  final String model;
  final String language;
}

/// The backend has no `DEEPGRAM_API_KEY`, so no transcripts will ever arrive.
class TranscriptionDisabledEvent extends RefEvent {
  const TranscriptionDisabledEvent(this.reason);

  final String reason;
}

/// Deepgram reported an error mid-stream.
class TranscriptionErrorEvent extends RefEvent {
  const TranscriptionErrorEvent(this.message);

  final String message;
}

/// A chunk of transcript. [isFinal] distinguishes stabilised text from interim
/// (fast, revisable) partials. [speaker] is a diarization label like
/// `speaker_0` / `speaker_1` / `speaker_unknown`.
class TranscriptEvent extends RefEvent {
  const TranscriptEvent({
    required this.isFinal,
    required this.speaker,
    required this.text,
    this.confidence,
  });

  final bool isFinal;
  final String speaker;
  final String text;
  final double? confidence;

  bool get isEmpty => text.isEmpty;
}

/// The session was closed cleanly by the server.
class SessionEndedEvent extends RefEvent {
  const SessionEndedEvent({
    required this.bytesReceived,
    required this.chunksReceived,
  });

  final int bytesReceived;
  final int chunksReceived;
}

/// A protocol-level error from the ingestion server.
class RefErrorEvent extends RefEvent {
  const RefErrorEvent({required this.code, required this.message});

  final String code;
  final String message;
}

/// Any frame we don't model. [type] is the raw `type` field (or a sentinel for
/// unparseable frames).
class UnknownEvent extends RefEvent {
  const UnknownEvent(this.type);

  final String type;
}

String _str(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

int _int(Object? value) => value is num ? value.toInt() : 0;

double? _doubleOrNull(Object? value) => value is num ? value.toDouble() : null;
