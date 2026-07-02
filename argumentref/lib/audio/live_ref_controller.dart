import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../center_ref/beats.dart';
import 'audio_session.dart';
import 'ref_events.dart';

/// One finalised line of conversation, tagged with the speaker chair we mapped
/// it to.
@immutable
class TranscriptLine {
  const TranscriptLine({required this.speaker, required this.text});

  final Speaker speaker;
  final String text;
}

/// Turns the raw event stream from an [AudioSession] into everything the live
/// referee screen shows: which chair holds the floor (→ the ref's eyes/head),
/// a running flow balance, a rough interruption count, and the live transcript.
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
  }) : session =
           session ??
           AudioSession(
             sessionId: sessionId ?? _generateId('sess'),
             participantId: participantId ?? _generateId('phone'),
             speakerLabels: [leftName, rightName],
           );

  final String leftName;
  final String rightName;
  final AudioSession session;

  static const int _idleGapMs = 2200; // silence before the floor goes empty
  static const int _cutInWindowMs = 800; // overlap tight enough to be a cut-in
  static const int _concernHoldMs = 2600; // how long the ref stays flagged
  static const int _maxLines = 60;

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
  bool _hasHeardAnything = false;

  bool _idle = true;
  bool _concerned = false;

  int _leftWeight = 0;
  int _rightWeight = 0;
  int _cutIns = 0;

  bool _transcriptionLive = false;
  bool _transcriptionDisabled = false;
  bool _compromisesDisabled = false;
  String? _compromiseError;

  final List<TranscriptLine> _lines = [];
  final List<CompromiseSuggestion> _compromises = [];
  String _partialText = '';
  Speaker _partialSpeaker = Speaker.none;

  String _signature = '';

  // ── public surface read by the screen ────────────────────────────────────

  /// The current referee "beat" — active speaker + mood + mouth + a coaching
  /// caption (with `{L}` / `{R}` tokens the screen fills in).
  Beat get beat {
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

  /// Finalised transcript, oldest first.
  List<TranscriptLine> get transcript => List.unmodifiable(_lines);

  /// Ranked compromise ideas from the backend, best first.
  List<CompromiseSuggestion> get compromises => List.unmodifiable(_compromises);

  bool get hasCompromises => _compromises.isNotEmpty;

  CompromiseSuggestion? get topCompromise =>
      _compromises.isEmpty ? null : _compromises.first;

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

  Future<void> stop() => session.stop();

  /// Clears the visible conversation state while keeping the live socket and
  /// any backend speaker mappings learned during calibration.
  void resetConversationStats({Duration ignoreIncoming = Duration.zero}) {
    _activeSpeaker = Speaker.none;
    _lastActivityAt = DateTime.fromMillisecondsSinceEpoch(0);
    _concernUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _ignoreConversationUntil =
        ignoreIncoming > Duration.zero
            ? DateTime.now().add(ignoreIncoming)
            : DateTime.fromMillisecondsSinceEpoch(0);
    _hasHeardAnything = false;
    _idle = true;
    _concerned = false;
    _leftWeight = 0;
    _rightWeight = 0;
    _cutIns = 0;
    _lines.clear();
    _compromises.clear();
    _compromiseError = null;
    _partialText = '';
    _partialSpeaker = Speaker.none;
    _signature = '';
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
    unawaited(session.dispose());
    super.dispose();
  }

  // ── event handling ─────────────────────────────────────────────────────

  void _onStatusChanged() => _refresh();

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
      case CompromiseSuggestedEvent(suggestions: final suggestions):
        _handleCompromises(suggestions);
      case CompromiseDisabledEvent():
        _compromisesDisabled = true;
      case CompromiseErrorEvent(message: final message):
        _compromiseError = message;
      case _:
        break;
    }
    _refresh();
  }

  void _handleTranscript(TranscriptEvent event) {
    final now = DateTime.now();
    final speaker = _resolveSpeaker(
      event.speaker,
      speakerLabel: event.speakerLabel,
    );
    if (now.isBefore(_ignoreConversationUntil)) return;

    // Cut-in heuristic: the floor changed hands while the previous voice had
    // only just been active — i.e. they talked over each other.
    if (_hasHeardAnything &&
        speaker != Speaker.none &&
        _activeSpeaker != Speaker.none &&
        speaker != _activeSpeaker &&
        now.difference(_lastActivityAt).inMilliseconds < _cutInWindowMs) {
      _cutIns++;
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

  void _appendLine(Speaker speaker, String text) {
    _lines.add(TranscriptLine(speaker: speaker, text: text));
    if (_lines.length > _maxLines) _lines.removeAt(0);
  }

  void _handleCompromises(List<CompromiseSuggestion> suggestions) {
    _compromiseError = null;
    _compromisesDisabled = false;
    if (suggestions.isEmpty) return;

    _compromises
      ..clear()
      ..addAll([...suggestions]..sort((a, b) => a.rank.compareTo(b.rank)));
  }

  void _addWeight(Speaker speaker, String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (speaker == Speaker.left) _leftWeight += words;
    if (speaker == Speaker.right) _rightWeight += words;
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
    final now = DateTime.now();
    _idle =
        !_hasHeardAnything ||
        now.difference(_lastActivityAt).inMilliseconds > _idleGapMs;
    _concerned = now.isBefore(_concernUntil);

    final active = _idle ? Speaker.none : _activeSpeaker;
    final mappedLabels = _mappedLabels.toList()..sort();
    final top = topCompromise;
    final sig =
        '$active|$_concerned|$flow|$_cutIns|$statusLabel|'
        '${mappedLabels.join(',')}|'
        '$_partialSpeaker:$_partialText|${_lines.length}|'
        '${top?.id}:${top?.score}|$_compromisesDisabled|$_compromiseError';
    if (sig == _signature) return;
    _signature = sig;
    notifyListeners();
  }

  static String _generateId(String prefix) {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = math.Random().nextInt(0x7fffffff);
    return '$prefix-$ts-$rand';
  }

  static String _normalizeLabel(String? label) =>
      label?.trim().toLowerCase() ?? '';
}
