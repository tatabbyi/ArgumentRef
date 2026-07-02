import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../center_ref/beats.dart';
import 'audio_session.dart';
import 'compromise_sound_player.dart';
import 'ref_events.dart';
import 'ref_voice.dart';

/// One finalised line of conversation, tagged with the speaker chair we mapped
/// it to.
@immutable
class TranscriptLine {
  const TranscriptLine({required this.speaker, required this.text});

  final Speaker speaker;
  final String text;
}

@immutable
class RoomToneStatus {
  const RoomToneStatus({
    required this.label,
    required this.detail,
    required this.score,
    required this.loudness,
    required this.isHeated,
    required this.isRepairing,
    required this.hasAiSignal,
    this.speaker = Speaker.none,
  });

  final String label;
  final String detail;
  final int score;
  final double loudness;
  final bool isHeated;
  final bool isRepairing;
  final bool hasAiSignal;
  final Speaker speaker;

  double get waveLevel {
    final volumeEnergy = 0.18 + loudness * 0.72;
    final toneEnergy = (score / 100) * (isHeated ? 0.95 : 0.72);
    return math.max(volumeEnergy, toneEnergy).clamp(0.16, 1.0).toDouble();
  }
}

@immutable
class InterruptionIncident {
  const InterruptionIncident({
    required this.interrupter,
    required this.interrupted,
    required this.confidence,
    required this.overlapMs,
    required this.gapMs,
    required this.reason,
  });

  final Speaker interrupter;
  final Speaker interrupted;
  final double confidence;
  final int overlapMs;
  final int gapMs;
  final String reason;
}

@immutable
class InterruptionStats {
  const InterruptionStats({
    required this.leftCutRight,
    required this.rightCutLeft,
    this.latest,
  });

  final int leftCutRight;
  final int rightCutLeft;
  final InterruptionIncident? latest;

  int get total => leftCutRight + rightCutLeft;
}

/// Turns the raw event stream from an [AudioSession] into everything the live
/// referee screen shows: which chair holds the floor (→ the ref's eyes/head),
/// a running flow balance, directional interruption counts, and the live
/// transcript.
///
/// When the backend sends calibration labels, those labels decide which chair a
/// diarized voice belongs to. Older/no-label streams still fall back to
/// **first-heard → left, second-heard → right**.
class LiveRefController extends ChangeNotifier {
  LiveRefController({
    required this.leftName,
    required this.rightName,
    AudioSession? session,
    String? sessionId,
    String? participantId,
    CompromiseSoundPlayer? compromiseSoundPlayer,
    TimeOutSoundPlayer? timeOutSoundPlayer,
    RefVoice? voice,
    Duration? voiceCooldown,
    Duration? voiceSettle,
    DateTime Function()? now,
  }) : session =
           session ??
           AudioSession(
             sessionId: sessionId ?? _generateId('sess'),
             participantId: participantId ?? _generateId('phone'),
             speakerLabels: [leftName, rightName],
           ),
       _compromiseSoundPlayer =
           compromiseSoundPlayer ?? const SilentCompromiseSoundPlayer(),
       _timeOutSoundPlayer =
           timeOutSoundPlayer ?? const SilentTimeOutSoundPlayer(),
       _voice = voice ?? const SilentRefVoice(),
       _voiceCooldown = voiceCooldown ?? const Duration(seconds: 7),
       _voiceSettle = voiceSettle ?? const Duration(milliseconds: 1400),
       _now = now ?? DateTime.now {
    this.session.loudnessListenable.addListener(_onLoudnessChanged);
  }

  final String leftName;
  final String rightName;
  final AudioSession session;
  final CompromiseSoundPlayer _compromiseSoundPlayer;
  final TimeOutSoundPlayer _timeOutSoundPlayer;
  final RefVoice _voice;
  final DateTime Function() _now;

  /// Minimum gap between two spoken referee calls, so the ref never rattles off
  /// guidance back-to-back.
  final Duration _voiceCooldown;

  /// How long the floor must be quiet before the ref speaks — it waits for a
  /// natural break rather than talking over whoever holds the floor.
  final Duration _voiceSettle;

  /// When true, the ref reads its live *interventions* (the "the ref says"
  /// bubble, when it's a real call — a cut-in flag or a compromise, not routine
  /// turn cues) aloud through [_voice]. Off by default so calibration stays
  /// silent; the conversation screen turns it on once the real session begins.
  bool voiceEnabled = false;

  static const int _idleGapMs = 2200; // silence before the floor goes empty
  static const int _cutInWindowMs = 800; // overlap tight enough to be a cut-in
  static const int _concernHoldMs = 2600; // how long the ref stays flagged
  static const int _maxLines = 60;
  static const double _shoutingStartLoudness = 0.82;
  static const double _shoutingStopLoudness = 0.56;
  static const Duration _timeOutTriggerDuration = Duration(seconds: 6);
  static const Duration _twoSpeakerShoutingWindow = Duration(seconds: 8);

  StreamSubscription<RefEvent>? _eventSub;
  Timer? _tick;
  bool _started = false;
  bool _disposed = false;

  // Diarization label → chair (0 = left, 1 = right), in first-heard order.
  final Map<String, int> _speakerSlots = {};
  final Set<String> _mappedLabels = {};

  Speaker _activeSpeaker = Speaker.none;
  DateTime _lastActivityAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _concernUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _ignoreConversationUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLeftHeardAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRightHeardAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _shoutingStartedAt;
  bool _hasHeardAnything = false;

  bool _idle = true;
  bool _concerned = false;
  bool _timeOutActive = false;

  int _leftWeight = 0;
  int _rightWeight = 0;
  int _cutIns = 0;
  int _leftCutRight = 0;
  int _rightCutLeft = 0;

  bool _transcriptionLive = false;
  bool _transcriptionDisabled = false;
  bool _compromisesDisabled = false;
  String? _compromiseError;
  bool _roomToneDisabled = false;
  String? _roomToneError;

  final List<TranscriptLine> _lines = [];
  final List<CompromiseSuggestion> _compromises = [];
  RoomToneAnalyzedEvent? _roomToneAnalysis;
  Speaker _roomToneSpeaker = Speaker.none;
  InterruptionIncident? _latestInterruption;
  String _partialText = '';
  Speaker _partialSpeaker = Speaker.none;
  String? _lastWhistledCompromiseId;

  String _signature = '';
  String _lastVoicedCaption = '';
  DateTime _lastVoicedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── public surface read by the screen ────────────────────────────────────

  /// The current referee "beat" — active speaker + mood + mouth + a coaching
  /// caption (with `{L}` / `{R}` tokens the screen fills in).
  Beat get beat {
    if (_timeOutActive) {
      return Beat(
        active: _idle ? Speaker.none : _activeSpeaker,
        mood: Mood.alert,
        mouth: MouthShape.tense,
        caption: 'Time out - lower the volume',
      );
    }

    final pushed = topCompromise;
    if (pushed != null && pushed.shouldPushHard) {
      return Beat(
        active: _idle ? Speaker.none : _activeSpeaker,
        mood: Mood.alert,
        mouth: MouthShape.tense,
        caption: 'Try this deal now: ${pushed.title}',
      );
    }

    if (pushed != null && pushed.quality == CompromiseQuality.strong) {
      return Beat(
        active: _idle ? Speaker.none : _activeSpeaker,
        mood: Mood.approve,
        mouth: MouthShape.smile,
        caption: 'Strong compromise: ${pushed.title}',
      );
    }

    return Beat(
      active: _idle ? Speaker.none : _activeSpeaker,
      mood: _concerned ? Mood.concern : Mood.listen,
      mouth: _concerned ? MouthShape.tense : MouthShape.neutral,
      caption: _caption(),
    );
  }

  /// Left speaker's share of the floor, 0–100 (50 until anyone speaks).
  int get flow {
    final total = _leftWeight + _rightWeight;
    if (total == 0) return 50;
    return ((_leftWeight / total) * 100).round();
  }

  int get cutIns => _cutIns;

  InterruptionStats get interruptions => InterruptionStats(
    leftCutRight: _leftCutRight,
    rightCutLeft: _rightCutLeft,
    latest: _latestInterruption,
  );

  /// Finalised transcript, oldest first.
  List<TranscriptLine> get transcript => List.unmodifiable(_lines);

  /// Ranked compromise ideas from the backend, best first.
  List<CompromiseSuggestion> get compromises => List.unmodifiable(_compromises);

  bool get hasCompromises => _compromises.isNotEmpty;

  CompromiseSuggestion? get topCompromise =>
      _compromises.isEmpty ? null : _compromises.first;

  bool get timeOutActive => _timeOutActive;

  RoomToneStatus get roomTone {
    final loudness = session.loudnessLevel;
    final volume = _volumeLabel(loudness);
    final analysis = _roomToneAnalysis;

    if (analysis == null) {
      final score = (loudness * 72).round().clamp(0, 100).toInt();
      final label = switch (score) {
        >= 62 => 'Loud',
        >= 30 => 'Steady',
        _ => 'Quiet',
      };
      final detail =
          _roomToneDisabled
              ? '$volume volume - Tone AI needs Gemini'
              : _roomToneError != null
              ? '$volume volume - Tone AI catching up'
              : '$volume volume';
      return RoomToneStatus(
        label: label,
        detail: detail,
        score: score,
        loudness: loudness,
        isHeated: loudness >= 0.82,
        isRepairing: false,
        hasAiSignal: false,
      );
    }

    final heated = _isHeatedTone(analysis);
    final repairing = _isRepairTone(analysis);
    final loudBoost = switch (loudness) {
      >= 0.82 => 16,
      >= 0.62 => 9,
      >= 0.42 => 4,
      _ => 0,
    };
    final score =
        math
            .max(analysis.intensity + loudBoost, loudness * 100)
            .round()
            .clamp(0, 100)
            .toInt();
    final label =
        loudness >= 0.78 &&
                !repairing &&
                (analysis.dominantTone == RoomToneSignal.neutral ||
                    analysis.dominantTone == RoomToneSignal.calm)
            ? 'Loud'
            : loudness >= 0.78 && heated
            ? '${_toneLabel(analysis.dominantTone)} + loud'
            : _toneLabel(analysis.dominantTone);
    final summary =
        analysis.summary.isNotEmpty
            ? analysis.summary
            : analysis.phrases.isNotEmpty
            ? analysis.phrases.first.text
            : _toneLabel(analysis.dominantTone);

    return RoomToneStatus(
      label: label,
      detail: '$volume volume - $summary',
      score: score,
      loudness: loudness,
      isHeated: heated || loudness >= 0.86,
      isRepairing: repairing,
      hasAiSignal: true,
      speaker: _roomToneSpeaker,
    );
  }

  String? get compromiseStatusLabel {
    if (_compromisesDisabled) return 'Compromise coach needs Gemini';
    if (_compromiseError != null) return 'Compromise coach is catching up';
    return null;
  }

  /// The in-flight (interim) line, if any — shown greyed so you can see the ref
  /// hearing words as they land.
  String get partialText => _partialText;
  Speaker get partialSpeaker => _partialSpeaker;
  bool get hasPartial => _partialText.isNotEmpty;

  AudioSessionStatus get status => session.status;
  bool get isStarted => _started;

  bool get micDenied => status == AudioSessionStatus.permissionDenied;
  bool get isError => status == AudioSessionStatus.error;
  bool get isProblem => micDenied || isError || _transcriptionDisabled;

  /// A short banner line describing the pipeline state.
  String get statusLabel {
    switch (status) {
      case AudioSessionStatus.idle:
      case AudioSessionStatus.requestingPermission:
        return 'Asking for mic access…';
      case AudioSessionStatus.permissionDenied:
        return 'Mic access denied — enable it in Settings';
      case AudioSessionStatus.connecting:
        return 'Connecting to the ref…';
      case AudioSessionStatus.streaming:
        if (_transcriptionDisabled) return 'Transcription is off on the server';
        if (_transcriptionLive) return 'Refereeing live';
        return 'Listening…';
      case AudioSessionStatus.error:
        return session.errorMessage ?? 'Connection error';
      case AudioSessionStatus.ended:
        return 'Session ended';
    }
  }

  bool hasMappedLabel(String label) =>
      _mappedLabels.contains(_normalizeLabel(label));

  // ── lifecycle ────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _eventSub = session.events.listen(_onEvent);
    session.statusListenable.addListener(_onStatusChanged);
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) => _onTick());
    await session.start();
    _refresh();
  }

  Future<void> stop() {
    _setTimeOutActive(false);
    _shoutingStartedAt = null;
    return session.stop();
  }

  /// Clears the visible conversation state while keeping the live socket and
  /// any backend speaker mappings learned during calibration.
  void resetConversationStats({Duration ignoreIncoming = Duration.zero}) {
    _activeSpeaker = Speaker.none;
    _lastActivityAt = DateTime.fromMillisecondsSinceEpoch(0);
    _concernUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _ignoreConversationUntil =
        ignoreIncoming > Duration.zero
            ? _now().add(ignoreIncoming)
            : DateTime.fromMillisecondsSinceEpoch(0);
    _lastLeftHeardAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastRightHeardAt = DateTime.fromMillisecondsSinceEpoch(0);
    _shoutingStartedAt = null;
    _hasHeardAnything = false;
    _idle = true;
    _concerned = false;
    _setTimeOutActive(false);
    _leftWeight = 0;
    _rightWeight = 0;
    _cutIns = 0;
    _leftCutRight = 0;
    _rightCutLeft = 0;
    _latestInterruption = null;
    _lines.clear();
    _compromises.clear();
    _compromiseError = null;
    _lastWhistledCompromiseId = null;
    _roomToneAnalysis = null;
    _roomToneSpeaker = Speaker.none;
    _roomToneDisabled = false;
    _roomToneError = null;
    _partialText = '';
    _partialSpeaker = Speaker.none;
    _signature = '';
    _lastVoicedCaption = '';
    _lastVoicedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _tick = null;
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    // Detach before the session disposes its notifier.
    session.statusListenable.removeListener(_onStatusChanged);
    session.loudnessListenable.removeListener(_onLoudnessChanged);
    _setTimeOutActive(false);
    unawaited(_compromiseSoundPlayer.dispose());
    unawaited(_timeOutSoundPlayer.dispose());
    unawaited(_voice.dispose());
    unawaited(session.dispose());
    super.dispose();
  }

  // ── event handling ─────────────────────────────────────────────────────

  void _onStatusChanged() => _refresh();

  void _onLoudnessChanged() => _refresh();

  void _onTick() => _refresh();

  /// Feed one event as if it arrived from the socket — used by tests to drive
  /// the controller without a live audio session.
  @visibleForTesting
  void onEventForTest(RefEvent event) => _onEvent(event);

  void _onEvent(RefEvent event) {
    switch (event) {
      case TranscriptionConnectedEvent():
        _transcriptionLive = true;
      case TranscriptionDisabledEvent():
        _transcriptionDisabled = true;
      case SpeakerMappedEvent():
        _handleSpeakerMapped(event);
      case TranscriptEvent(isEmpty: false):
        _handleTranscript(event);
      case InterruptionDetectedEvent():
        _handleInterruption(event);
      case CompromiseSuggestedEvent(suggestions: final suggestions):
        _handleCompromises(suggestions);
      case CompromiseDisabledEvent():
        _compromisesDisabled = true;
      case CompromiseErrorEvent(message: final message):
        _compromiseError = message;
      case RoomToneAnalyzedEvent():
        _handleRoomTone(event);
      case RoomToneDisabledEvent():
        _roomToneDisabled = true;
      case RoomToneErrorEvent(message: final message):
        _roomToneError = message;
      case _:
        break;
    }
    _refresh();
  }

  void _handleTranscript(TranscriptEvent event) {
    final now = _now();
    final speaker = _resolveSpeaker(
      event.speaker,
      speakerLabel: event.speakerLabel,
    );
    if (now.isBefore(_ignoreConversationUntil)) return;
    _markSpeakerHeard(speaker, now);

    // Keep the ref's face reactive while the backend does the actual timed,
    // directional interruption detection.
    if (_hasHeardAnything &&
        speaker != Speaker.none &&
        _activeSpeaker != Speaker.none &&
        speaker != _activeSpeaker &&
        now.difference(_lastActivityAt).inMilliseconds < _cutInWindowMs) {
      _concernUntil = now.add(const Duration(milliseconds: _concernHoldMs));
    }

    _hasHeardAnything = true;
    if (speaker != Speaker.none) _activeSpeaker = speaker;
    _lastActivityAt = now;

    if (event.isFinal) {
      _appendLine(speaker, event.text);
      _addWeight(speaker, event.text);
      _partialText = '';
      _partialSpeaker = Speaker.none;
    } else {
      _partialText = event.text;
      _partialSpeaker = speaker;
    }
  }

  void _handleInterruption(InterruptionDetectedEvent event) {
    final now = _now();
    if (now.isBefore(_ignoreConversationUntil)) return;

    final interrupter = _resolveSpeaker(
      event.interrupter,
      speakerLabel: event.interrupterLabel,
    );
    final interrupted = _resolveSpeaker(
      event.interrupted,
      speakerLabel: event.interruptedLabel,
    );
    if (interrupter == Speaker.none ||
        interrupted == Speaker.none ||
        interrupter == interrupted) {
      return;
    }
    _markSpeakerHeard(interrupter, now);
    _markSpeakerHeard(interrupted, now);

    if (interrupter == Speaker.left && interrupted == Speaker.right) {
      _leftCutRight++;
    } else if (interrupter == Speaker.right && interrupted == Speaker.left) {
      _rightCutLeft++;
    }

    _cutIns = _leftCutRight + _rightCutLeft;
    _latestInterruption = InterruptionIncident(
      interrupter: interrupter,
      interrupted: interrupted,
      confidence: event.confidence,
      overlapMs: event.overlapMs,
      gapMs: event.gapMs,
      reason: event.reason,
    );
    _hasHeardAnything = true;
    _activeSpeaker = interrupter;
    _lastActivityAt = now;
    _concernUntil = now.add(const Duration(milliseconds: _concernHoldMs));
  }

  void _appendLine(Speaker speaker, String text) {
    _lines.add(TranscriptLine(speaker: speaker, text: text));
    if (_lines.length > _maxLines) _lines.removeAt(0);
  }

  void _handleCompromises(List<CompromiseSuggestion> suggestions) {
    _compromiseError = null;
    _compromisesDisabled = false;
    if (suggestions.isEmpty) return;

    final ranked = [...suggestions]..sort((a, b) => a.rank.compareTo(b.rank));
    final topId = ranked.first.id;
    final shouldPlayWhistle = topId != _lastWhistledCompromiseId;

    _compromises
      ..clear()
      ..addAll(ranked);

    if (shouldPlayWhistle) {
      _lastWhistledCompromiseId = topId;
      unawaited(_compromiseSoundPlayer.playCompromiseFound());
    }
  }

  void _handleRoomTone(RoomToneAnalyzedEvent event) {
    _roomToneSpeaker = _resolveSpeaker(
      event.speaker,
      speakerLabel: event.speakerLabel,
    );
    _roomToneAnalysis = event;
    _roomToneDisabled = false;
    _roomToneError = null;
  }

  void _addWeight(Speaker speaker, String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (speaker == Speaker.left) _leftWeight += words;
    if (speaker == Speaker.right) _rightWeight += words;
  }

  void _markSpeakerHeard(Speaker speaker, DateTime at) {
    if (speaker == Speaker.left) _lastLeftHeardAt = at;
    if (speaker == Speaker.right) _lastRightHeardAt = at;
  }

  void _handleSpeakerMapped(SpeakerMappedEvent event) {
    final slot = _slotForLabel(event.speakerLabel);
    if (slot == null) return;
    if (event.speaker != 'speaker_unknown') {
      _speakerSlots[event.speaker] = slot;
    }
    _mappedLabels.add(_normalizeLabel(event.speakerLabel));
  }

  /// Maps a diarization label to a chair. Unknown labels stick with whoever's
  /// already talking; a third voice keeps the current chair (only two seats).
  Speaker _resolveSpeaker(String id, {String? speakerLabel}) {
    final labelledSlot = _slotForLabel(speakerLabel);
    if (labelledSlot != null) {
      if (id != 'speaker_unknown') {
        _speakerSlots[id] = labelledSlot;
      }
      _mappedLabels.add(_normalizeLabel(speakerLabel!));
      return labelledSlot == 0 ? Speaker.left : Speaker.right;
    }

    if (id == 'speaker_unknown') {
      return _activeSpeaker == Speaker.none ? Speaker.left : _activeSpeaker;
    }
    final existing = _speakerSlots[id];
    if (existing != null) return existing == 0 ? Speaker.left : Speaker.right;
    if (_speakerSlots.length >= 2) return _activeSpeaker;
    final slot = _speakerSlots.length; // 0, then 1
    _speakerSlots[id] = slot;
    return slot == 0 ? Speaker.left : Speaker.right;
  }

  int? _slotForLabel(String? label) {
    final normalized = _normalizeLabel(label);
    if (normalized.isEmpty) return null;
    if (normalized == _normalizeLabel(leftName)) return 0;
    if (normalized == _normalizeLabel(rightName)) return 1;
    return null;
  }

  String _caption() {
    if (micDenied) return 'Enable mic access to referee live';
    if (_transcriptionDisabled) return 'Transcription is off on the server';
    if (_concerned && _latestInterruption != null) {
      return switch (_latestInterruption!.interrupted) {
        Speaker.left => 'Let {L} finish',
        Speaker.right => 'Let {R} finish',
        Speaker.none => 'One at a time',
      };
    }
    if (_concerned) return 'One at a time';
    if (!_hasHeardAnything) {
      return status == AudioSessionStatus.streaming
          ? 'Listening…'
          : 'Warming up…';
    }
    return switch (_idle ? Speaker.none : _activeSpeaker) {
      Speaker.left => 'Go on, {L}',
      Speaker.right => 'Your turn, {R}',
      Speaker.none => 'Watching the room…',
    };
  }

  /// Recomputes time-decayed flags and notifies listeners only when something
  /// user-visible actually changed.
  void _refresh() {
    if (_disposed) return;
    final now = _now();
    _idle =
        !_hasHeardAnything ||
        now.difference(_lastActivityAt).inMilliseconds > _idleGapMs;
    _concerned = now.isBefore(_concernUntil);
    _updateTimeOutState(now);

    // Runs every tick (not just on signature changes) so a call held back for a
    // lull actually gets spoken once the natural break arrives.
    _maybeVoiceCaption();

    final active = _idle ? Speaker.none : _activeSpeaker;
    final mappedLabels = _mappedLabels.toList()..sort();
    final top = topCompromise;
    final tone = _roomToneAnalysis;
    final interruption = _latestInterruption;
    final loudnessBucket = (session.loudnessLevel * 20).round();
    final sig =
        '$active|$_concerned|$flow|$_cutIns:$_leftCutRight:$_rightCutLeft|'
        '${interruption?.interrupter}>${interruption?.interrupted}:'
        '${interruption?.confidence}|$statusLabel|'
        '${mappedLabels.join(',')}|'
        '$_partialSpeaker:$_partialText|${_lines.length}|'
        '${top?.id}:${top?.score}|$_compromisesDisabled|$_compromiseError|'
        '${tone?.lineNumber}.${tone?.sentenceIndex}:${tone?.dominantTone}:'
        '${tone?.intensity}:$_roomToneSpeaker|$_roomToneDisabled|$_roomToneError|'
        '$loudnessBucket|$_timeOutActive';
    if (sig == _signature) return;
    _signature = sig;
    notifyListeners();
  }

  /// Reads the ref's live *intervention* aloud — but only when it's a real call,
  /// and with a cadence that fits what kind of call it is.
  ///
  /// - **What** — only intervention moods are voiced; the routine "Go on, X" /
  ///   "Your turn, Y" turn cues stay on-screen only, so the ref isn't narrating
  ///   every hand-off.
  /// - **Cut-in flags** ([Mood.concern] — "Let X finish" / "One at a time") are
  ///   what a ref actually raises their voice for, so they're spoken promptly
  ///   (even over the overlap) and re-asserted only after the [_voiceCooldown].
  /// - **Compromises** ([Mood.alert] / [Mood.approve]) aren't urgent, so each
  ///   distinct one is announced once and only in a lull ([_voiceSettle] of
  ///   quiet) rather than cutting across whoever holds the floor.
  /// - **How often** — a [_voiceCooldown] between any two calls so the ref never
  ///   rattles off guidance back-to-back.
  void _maybeVoiceCaption() {
    if (!voiceEnabled) return;
    if (_timeOutActive) return;

    final current = beat;
    if (!_isVoiceableMood(current.mood)) return;

    final spoken = current.caption
        .replaceAll('{L}', leftName)
        .replaceAll('{R}', rightName);
    if (spoken.isEmpty) return;

    final now = _now();
    if (now.difference(_lastVoicedAt) < _voiceCooldown) return;

    if (current.mood == Mood.concern) {
      // A cut-in — interject now; the cooldown alone spaces out repeats.
      _voiceLine(spoken, now);
      return;
    }

    // A compromise — announce each distinct one once, and only at a lull.
    if (spoken == _lastVoicedCaption) return;
    if (!_idle && now.difference(_lastActivityAt) < _voiceSettle) return;
    _voiceLine(spoken, now);
  }

  void _voiceLine(String line, DateTime at) {
    _lastVoicedCaption = line;
    _lastVoicedAt = at;
    unawaited(_voice.speak(line));
  }

  /// The ref only speaks when it actually has a call to make: a cut-in flag
  /// ([Mood.concern]) or a compromise worth surfacing ([Mood.alert] /
  /// [Mood.approve]). Everything else ([Mood.listen] turn cues, warming/idle
  /// filler) is shown but not read aloud.
  static bool _isVoiceableMood(Mood mood) =>
      mood == Mood.concern || mood == Mood.alert || mood == Mood.approve;

  void _updateTimeOutState(DateTime now) {
    final loudness = session.loudnessLevel;
    if (_timeOutActive) {
      if (loudness < _shoutingStopLoudness) {
        _shoutingStartedAt = null;
        _setTimeOutActive(false);
      }
      return;
    }

    if (loudness < _shoutingStartLoudness || !_bothSpeakersRecent(now)) {
      _shoutingStartedAt = null;
      return;
    }

    _shoutingStartedAt ??= now;
    if (now.difference(_shoutingStartedAt!) >= _timeOutTriggerDuration) {
      _setTimeOutActive(true);
    }
  }

  bool _bothSpeakersRecent(DateTime now) {
    final leftRecent =
        now.difference(_lastLeftHeardAt) <= _twoSpeakerShoutingWindow;
    final rightRecent =
        now.difference(_lastRightHeardAt) <= _twoSpeakerShoutingWindow;
    return leftRecent && rightRecent;
  }

  void _setTimeOutActive(bool active) {
    if (_timeOutActive == active) return;
    _timeOutActive = active;
    if (active) {
      unawaited(_timeOutSoundPlayer.startTimeOutLoop());
    } else {
      unawaited(_timeOutSoundPlayer.stopTimeOutLoop());
    }
  }

  static String _generateId(String prefix) {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = math.Random().nextInt(0x7fffffff);
    return '$prefix-$ts-$rand';
  }

  static String _volumeLabel(double loudness) => switch (loudness) {
    >= 0.82 => 'Very loud',
    >= 0.62 => 'Loud',
    >= 0.34 => 'Steady',
    >= 0.12 => 'Low',
    _ => 'Quiet',
  };

  static bool _isHeatedTone(RoomToneAnalyzedEvent analysis) {
    if (analysis.trend == RoomToneTrend.escalating &&
        analysis.intensity >= 58) {
      return true;
    }
    return analysis.signals.any(_isHeatedSignal);
  }

  static bool _isRepairTone(RoomToneAnalyzedEvent analysis) {
    if (analysis.trend == RoomToneTrend.deEscalating) return true;
    return analysis.signals.any(_isRepairSignal);
  }

  static bool _isHeatedSignal(RoomToneSignal signal) => switch (signal) {
    RoomToneSignal.aggressive ||
    RoomToneSignal.angry ||
    RoomToneSignal.accusatory ||
    RoomToneSignal.dismissive ||
    RoomToneSignal.defensive ||
    RoomToneSignal.contemptuous ||
    RoomToneSignal.interruptive => true,
    _ => false,
  };

  static bool _isRepairSignal(RoomToneSignal signal) => switch (signal) {
    RoomToneSignal.calm ||
    RoomToneSignal.forgiving ||
    RoomToneSignal.apologetic ||
    RoomToneSignal.validating ||
    RoomToneSignal.compromising ||
    RoomToneSignal.problemSolving ||
    RoomToneSignal.repairAttempt => true,
    _ => false,
  };

  static String _toneLabel(RoomToneSignal signal) => switch (signal) {
    RoomToneSignal.aggressive => 'Aggressive',
    RoomToneSignal.angry => 'Angry',
    RoomToneSignal.accusatory => 'Accusatory',
    RoomToneSignal.dismissive => 'Dismissive',
    RoomToneSignal.defensive => 'Defensive',
    RoomToneSignal.contemptuous => 'Contemptuous',
    RoomToneSignal.interruptive => 'Interruptive',
    RoomToneSignal.hurt => 'Hurt',
    RoomToneSignal.sad => 'Sad',
    RoomToneSignal.anxious => 'Anxious',
    RoomToneSignal.calm => 'Calm',
    RoomToneSignal.forgiving => 'Forgiving',
    RoomToneSignal.apologetic => 'Apologetic',
    RoomToneSignal.validating => 'Validating',
    RoomToneSignal.compromising => 'Compromising',
    RoomToneSignal.problemSolving => 'Problem solving',
    RoomToneSignal.repairAttempt => 'Repair attempt',
    RoomToneSignal.neutral => 'Neutral',
  };

  static String _normalizeLabel(String? label) =>
      label?.trim().toLowerCase() ?? '';
}
