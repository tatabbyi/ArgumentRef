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
          speakerLabel: _strOrNull(decoded['speakerLabel']),
          text: _str(decoded['text']).trim(),
          confidence: _doubleOrNull(decoded['confidence']),
        );
      case 'interruption.detected':
        return InterruptionDetectedEvent(
          interrupter: _str(
            decoded['interrupter'],
            fallback: 'speaker_unknown',
          ),
          interrupterLabel: _strOrNull(decoded['interrupterLabel']),
          interrupted: _str(
            decoded['interrupted'],
            fallback: 'speaker_unknown',
          ),
          interruptedLabel: _strOrNull(decoded['interruptedLabel']),
          interrupterText: _str(decoded['interrupterText']).trim(),
          interruptedText: _str(decoded['interruptedText']).trim(),
          overlapMs: _int(decoded['overlapMs']),
          gapMs: _int(decoded['gapMs']),
          confidence:
              (_doubleOrNull(decoded['confidence']) ?? 0)
                  .clamp(0.0, 1.0)
                  .toDouble(),
          reason: _str(decoded['reason']),
        );
      case 'compromise.suggested':
        return CompromiseSuggestedEvent(
          model: _str(decoded['model']),
          generatedAt: _str(decoded['generatedAt']),
          transcriptLineCount: _int(decoded['transcriptLineCount']),
          suggestions: _compromiseSuggestions(decoded['suggestions']),
        );
      case 'compromise.disabled':
        return CompromiseDisabledEvent(_str(decoded['reason']));
      case 'compromise.error':
        return CompromiseErrorEvent(_str(decoded['message']));
      case 'room_tone.analyzed':
        return RoomToneAnalyzedEvent(
          model: _str(decoded['model']),
          generatedAt: _str(decoded['generatedAt']),
          lineNumber: _positiveInt(decoded['lineNumber'], fallback: 1),
          sentenceIndex: _positiveInt(decoded['sentenceIndex'], fallback: 1),
          speaker: _str(decoded['speaker'], fallback: 'speaker_unknown'),
          speakerLabel: _strOrNull(decoded['speakerLabel']),
          text: _str(decoded['text']).trim(),
          dominantTone: _roomToneSignal(decoded['dominantTone']),
          trend: _roomToneTrend(decoded['trend']),
          intensity: _score(decoded['intensity']),
          confidence:
              (_doubleOrNull(decoded['confidence']) ?? 0)
                  .clamp(0.0, 1.0)
                  .toDouble(),
          summary: _str(decoded['summary']).trim(),
          signals: _roomToneSignals(decoded['signals']),
          phrases: _roomTonePhrases(decoded['phrases']),
        );
      case 'room_tone.disabled':
        return RoomToneDisabledEvent(_str(decoded['reason']));
      case 'room_tone.error':
        return RoomToneErrorEvent(_str(decoded['message']));
      case 'speaker.diarization_status':
        return SpeakerDiarizationStatusEvent(
          status: _str(decoded['status']),
          speakers: _stringList(decoded['speakers']),
          totalWords: _int(decoded['totalWords']),
          wordsWithSpeaker: _int(decoded['wordsWithSpeaker']),
          message: _str(decoded['message']),
        );
      case 'speaker.mapped':
        return SpeakerMappedEvent(
          speaker: _str(decoded['speaker'], fallback: 'speaker_unknown'),
          speakerLabel: _str(decoded['speakerLabel']),
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
    this.speakerLabel,
    required this.text,
    this.confidence,
  });

  final bool isFinal;
  final String speaker;
  final String? speakerLabel;
  final String text;
  final double? confidence;

  bool get isEmpty => text.isEmpty;
}

/// A backend-timed cut-in where one diarized speaker starts before, or very
/// tightly after, another speaker had clearly finished.
class InterruptionDetectedEvent extends RefEvent {
  const InterruptionDetectedEvent({
    required this.interrupter,
    this.interrupterLabel,
    required this.interrupted,
    this.interruptedLabel,
    required this.interrupterText,
    required this.interruptedText,
    required this.overlapMs,
    required this.gapMs,
    required this.confidence,
    required this.reason,
  });

  final String interrupter;
  final String? interrupterLabel;
  final String interrupted;
  final String? interruptedLabel;
  final String interrupterText;
  final String interruptedText;
  final int overlapMs;
  final int gapMs;
  final double confidence;
  final String reason;
}

enum CompromiseQuality { weak, promising, strong, reallyGood }

enum CompromisePushLevel { normal, firm, urgent }

/// One ranked possible agreement produced by the backend compromise advisor.
class CompromiseSuggestion {
  const CompromiseSuggestion({
    required this.id,
    required this.rank,
    required this.title,
    required this.summary,
    required this.whyItCouldWork,
    required this.score,
    required this.quality,
    required this.pushLevel,
  });

  final String id;
  final int rank;
  final String title;
  final String summary;
  final String whyItCouldWork;
  final int score;
  final CompromiseQuality quality;
  final CompromisePushLevel pushLevel;

  bool get isReallyGood => quality == CompromiseQuality.reallyGood;

  bool get shouldPushHard =>
      isReallyGood || pushLevel == CompromisePushLevel.urgent;
}

/// A fresh ranked set of compromise suggestions for the current transcript.
class CompromiseSuggestedEvent extends RefEvent {
  const CompromiseSuggestedEvent({
    required this.model,
    required this.generatedAt,
    required this.transcriptLineCount,
    required this.suggestions,
  });

  final String model;
  final String generatedAt;
  final int transcriptLineCount;
  final List<CompromiseSuggestion> suggestions;
}

/// The backend has no `GEMINI_API_KEY`, so compromise suggestions are off.
class CompromiseDisabledEvent extends RefEvent {
  const CompromiseDisabledEvent(this.reason);

  final String reason;
}

/// Gemini or compromise analysis failed mid-session.
class CompromiseErrorEvent extends RefEvent {
  const CompromiseErrorEvent(this.message);

  final String message;
}

enum RoomToneSignal {
  aggressive,
  angry,
  accusatory,
  dismissive,
  defensive,
  contemptuous,
  interruptive,
  hurt,
  sad,
  anxious,
  calm,
  forgiving,
  apologetic,
  validating,
  compromising,
  problemSolving,
  repairAttempt,
  neutral,
}

enum RoomToneTrend { escalating, deEscalating, neutral }

class RoomTonePhrase {
  const RoomTonePhrase({required this.text, required this.signal});

  final String text;
  final RoomToneSignal signal;
}

/// A fast Gemini tone reading for one final sentence, with a few previous
/// sentences used as context on the backend.
class RoomToneAnalyzedEvent extends RefEvent {
  const RoomToneAnalyzedEvent({
    required this.model,
    required this.generatedAt,
    required this.lineNumber,
    required this.sentenceIndex,
    required this.speaker,
    this.speakerLabel,
    required this.text,
    required this.dominantTone,
    required this.trend,
    required this.intensity,
    required this.confidence,
    required this.summary,
    required this.signals,
    required this.phrases,
  });

  final String model;
  final String generatedAt;
  final int lineNumber;
  final int sentenceIndex;
  final String speaker;
  final String? speakerLabel;
  final String text;
  final RoomToneSignal dominantTone;
  final RoomToneTrend trend;
  final int intensity;
  final double confidence;
  final String summary;
  final List<RoomToneSignal> signals;
  final List<RoomTonePhrase> phrases;
}

/// The backend has no `GEMINI_API_KEY`, so AI tone analysis is off.
class RoomToneDisabledEvent extends RefEvent {
  const RoomToneDisabledEvent(this.reason);

  final String reason;
}

/// Gemini room-tone analysis failed mid-session.
class RoomToneErrorEvent extends RefEvent {
  const RoomToneErrorEvent(this.message);

  final String message;
}

/// Deepgram's rolling summary of whether diarization is returning speaker IDs.
class SpeakerDiarizationStatusEvent extends RefEvent {
  const SpeakerDiarizationStatusEvent({
    required this.status,
    required this.speakers,
    required this.totalWords,
    required this.wordsWithSpeaker,
    required this.message,
  });

  final String status;
  final List<String> speakers;
  final int totalWords;
  final int wordsWithSpeaker;
  final String message;
}

/// The backend assigned an anonymous diarization speaker to a calibration name.
class SpeakerMappedEvent extends RefEvent {
  const SpeakerMappedEvent({required this.speaker, required this.speakerLabel});

  final String speaker;
  final String speakerLabel;
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

String? _strOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _int(Object? value) => value is num ? value.toInt() : 0;

double? _doubleOrNull(Object? value) => value is num ? value.toDouble() : null;

List<CompromiseSuggestion> _compromiseSuggestions(Object? value) {
  if (value is! List) return const [];

  return [
    for (var i = 0; i < value.length; i++)
      if (_compromiseSuggestion(value[i], i) case final suggestion?) suggestion,
  ];
}

CompromiseSuggestion? _compromiseSuggestion(Object? value, int index) {
  if (value is! Map<String, dynamic>) return null;

  final title = _str(value['title']).trim();
  final summary = _str(value['summary']).trim();
  if (title.isEmpty || summary.isEmpty) return null;

  return CompromiseSuggestion(
    id: _str(value['id'], fallback: 'compromise-${index + 1}'),
    rank: _positiveInt(value['rank'], fallback: index + 1),
    title: title,
    summary: summary,
    whyItCouldWork: _str(value['whyItCouldWork']).trim(),
    score: _score(value['score']),
    quality: _quality(value['quality']),
    pushLevel: _pushLevel(value['pushLevel']),
  );
}

int _positiveInt(Object? value, {required int fallback}) {
  final parsed = _int(value);
  return parsed > 0 ? parsed : fallback;
}

int _score(Object? value) {
  final parsed = value is num ? value.round() : 0;
  return parsed.clamp(0, 100).toInt();
}

CompromiseQuality _quality(Object? value) => switch (_str(value)) {
  'really_good' => CompromiseQuality.reallyGood,
  'strong' => CompromiseQuality.strong,
  'promising' => CompromiseQuality.promising,
  _ => CompromiseQuality.weak,
};

CompromisePushLevel _pushLevel(Object? value) => switch (_str(value)) {
  'urgent' => CompromisePushLevel.urgent,
  'firm' => CompromisePushLevel.firm,
  _ => CompromisePushLevel.normal,
};

RoomToneSignal _roomToneSignal(Object? value) => switch (_str(value)) {
  'aggressive' => RoomToneSignal.aggressive,
  'angry' => RoomToneSignal.angry,
  'accusatory' => RoomToneSignal.accusatory,
  'dismissive' => RoomToneSignal.dismissive,
  'defensive' => RoomToneSignal.defensive,
  'contemptuous' => RoomToneSignal.contemptuous,
  'interruptive' => RoomToneSignal.interruptive,
  'hurt' => RoomToneSignal.hurt,
  'sad' => RoomToneSignal.sad,
  'anxious' => RoomToneSignal.anxious,
  'calm' => RoomToneSignal.calm,
  'forgiving' => RoomToneSignal.forgiving,
  'apologetic' => RoomToneSignal.apologetic,
  'validating' => RoomToneSignal.validating,
  'compromising' => RoomToneSignal.compromising,
  'problem_solving' => RoomToneSignal.problemSolving,
  'repair_attempt' => RoomToneSignal.repairAttempt,
  _ => RoomToneSignal.neutral,
};

RoomToneTrend _roomToneTrend(Object? value) => switch (_str(value)) {
  'escalating' => RoomToneTrend.escalating,
  'de_escalating' => RoomToneTrend.deEscalating,
  _ => RoomToneTrend.neutral,
};

List<RoomToneSignal> _roomToneSignals(Object? value) {
  if (value is! List) return const [RoomToneSignal.neutral];
  final signals = [for (final item in value) _roomToneSignal(item)];
  return signals.isEmpty ? const [RoomToneSignal.neutral] : signals;
}

List<RoomTonePhrase> _roomTonePhrases(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (_roomTonePhrase(item) case final phrase?) phrase,
  ];
}

RoomTonePhrase? _roomTonePhrase(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final text = _str(value['text']).trim();
  if (text.isEmpty) return null;
  return RoomTonePhrase(text: text, signal: _roomToneSignal(value['signal']));
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is String) item,
  ];
}
