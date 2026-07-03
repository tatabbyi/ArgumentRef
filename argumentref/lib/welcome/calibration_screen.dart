import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/audio_session.dart';
import '../audio/compromise_sound_player.dart';
import '../audio/live_ref_controller.dart';
import '../audio/ref_voice.dart';
import '../center_ref/center_ref_screen.dart';
import '../center_ref/referee_guide.dart';
import '../center_ref/volume_wave.dart';
import '../models/referee_settings.dart';
import '../ui/ref_theme.dart';

/// A short voice-calibration step that sits between "Who's talking today?" and
/// the live referee. Each speaker in turn reads a ten-second line aloud so the
/// ref can "learn" their voice and tell the two apart mid-argument.
///
/// This uses the same live audio session as the conversation itself. The
/// backend receives both reads with `speakerLabels` in name order, maps the
/// diarization IDs it hears, then the still-open session is handed to the live
/// referee screen.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({
    super.key,
    required this.leftName,
    required this.rightName,
    this.refereeSettings = RefereeSettings.defaults,
  });

  /// First speaker (green). Reads first.
  final String leftName;

  /// Second speaker (orange). Reads second.
  final String rightName;

  /// The user's referee tuning, applied to the live session opened here (the
  /// same socket later handed to the conversation screen).
  final RefereeSettings refereeSettings;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

/// The most a single speaker's read runs — the ceiling if they keep going. A
/// read normally ends sooner, the moment the speaker's finished (see
/// [_CalibrationScreenState._completeRead]).
const Duration _kReadLength = Duration(seconds: 10);

/// Minimum share of [_kReadLength] to capture before a backend voice match is
/// allowed to end a read early — a match can land after a word or two, and
/// cutting the speaker off that fast feels abrupt.
const double _kMinReadForMatch = 0.3;

/// Where each speaker sits in the calibration flow.
enum _CalStatus { idle, preparing, recording, done }

class _CalibrationScreenState extends State<CalibrationScreen>
    with SingleTickerProviderStateMixin {
  /// Times each read — 0→1 over [_kReadLength]. Its value feeds the countdown,
  /// the progress ring and the live meter's energy.
  late final AnimationController _read;

  /// Which speaker is on stage (0 = first, 1 = second).
  int _index = 0;

  /// Per-speaker calibration state, keyed by [_index].
  final List<_CalStatus> _status = [_CalStatus.idle, _CalStatus.idle];

  LiveRefController? _live;
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _read =
        AnimationController(vsync: this, duration: _kReadLength)
          ..addStatusListener((s) {
            // Hitting the ceiling ends the read too — the fallback when nobody taps
            // and the backend never matches the voice.
            if (s == AnimationStatus.completed) {
              _completeRead();
            }
          })
          ..addListener(_maybeAutoFinish);
  }

  @override
  void dispose() {
    _read.dispose();
    _live?.removeListener(_onLive);
    if (!_handedOff) _live?.dispose();
    super.dispose();
  }

  String get _name => _index == 0 ? widget.leftName : widget.rightName;
  Color get _accent => _index == 0 ? RefPalette.green : RefPalette.orange;
  _CalStatus get _current => _status[_index];
  bool get _isLast => _index == 1;
  bool get _currentMapped => _live?.hasMappedLabel(_name) ?? false;

  /// What tapping the mic does right now: start the read when idle, or end it
  /// early once it's running (the speaker telling us they've finished).
  VoidCallback? get _micAction {
    if (_current == _CalStatus.idle && !(_live?.isProblem ?? false)) {
      return _startRecording;
    }
    if (_current == _CalStatus.recording) return _completeRead;
    return null;
  }

  /// The line the current speaker reads — personal enough to feel like they're
  /// talking to the ref, varied enough to give the voice model something to
  /// chew on. Runs ~10 seconds at a natural pace.
  String get _script =>
      'Hey ref, it’s $_name here. I’ll make my case, hear the '
      'other side out, and trust you to keep us both honest.';

  void _startRecording() {
    if (_current != _CalStatus.idle) return;
    _read.reset();
    setState(() => _status[_index] = _CalStatus.preparing);
    unawaited(_startLiveThenRead(_ensureLiveController()));
  }

  LiveRefController _ensureLiveController() {
    final existing = _live;
    if (existing != null) return existing;

    final controller = LiveRefController(
      leftName: widget.leftName,
      rightName: widget.rightName,
      refereeSettings: widget.refereeSettings,
      compromiseSoundPlayer: RefereeWhistlePlayer(),
      timeOutSoundPlayer: LongWhistleTimeOutPlayer(),
      // Attached now but left muted (voiceEnabled defaults to false) so the ref
      // stays quiet during calibration; the conversation screen turns it on
      // once this controller is handed off in _finish().
      voice: ElevenLabsRefVoice(),
    );
    controller.addListener(_onLive);
    _live = controller;
    return controller;
  }

  Future<void> _startLiveThenRead(LiveRefController live) async {
    await live.start();
    if (!mounted || _handedOff || _current != _CalStatus.preparing) return;
    if (live.status == AudioSessionStatus.streaming) {
      _beginRead();
    } else if (live.isProblem) {
      setState(() => _status[_index] = _CalStatus.idle);
    }
  }

  void _onLive() {
    if (!mounted || _handedOff) return;
    final live = _live;
    if (live == null) return;

    if (_current == _CalStatus.preparing &&
        live.status == AudioSessionStatus.streaming) {
      _beginRead();
      return;
    }

    if (_current == _CalStatus.preparing && live.isProblem) {
      setState(() => _status[_index] = _CalStatus.idle);
      return;
    }

    setState(() {});
  }

  void _beginRead() {
    if (!mounted || _current != _CalStatus.preparing) return;
    setState(() => _status[_index] = _CalStatus.recording);
    _live?.session.startSpeakerCalibration(_name);
    _read.forward(from: 0);
  }

  /// Ends the current read the moment the speaker's finished — they tapped the
  /// mic, or [_maybeAutoFinish] saw the backend match their voice — instead of
  /// always waiting out [_kReadLength]. Freezes the ring where it is; the
  /// meter and countdown fall away with the [_CalStatus.done] state.
  void _completeRead() {
    if (_current != _CalStatus.recording) return;
    _read.stop();
    _live?.session.stopSpeakerCalibration(_name);
    setState(() => _status[_index] = _CalStatus.done);
  }

  /// Runs each frame of the read: once the ref has matched this voice (and
  /// we've captured at least [_kMinReadForMatch] of the window), wrap up early
  /// so a finished speaker isn't left waiting on the clock.
  void _maybeAutoFinish() {
    if (_current == _CalStatus.recording &&
        _currentMapped &&
        _read.value >= _kMinReadForMatch) {
      _completeRead();
    }
  }

  void _restartCalibration() {
    _read.reset();
    final live = _live;
    live?.removeListener(_onLive);
    live?.dispose();
    setState(() {
      _live = null;
      _index = 0;
      _status[0] = _CalStatus.idle;
      _status[1] = _CalStatus.idle;
    });
  }

  void _next() {
    if (!_isLast) {
      _read.reset();
      setState(() => _index = 1);
      return;
    }
    _finish();
  }

  void _finish() {
    final live = _ensureLiveController();
    live.removeListener(_onLive);
    live.resetConversationStats(ignoreIncoming: const Duration(seconds: 2));
    _handedOff = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => Scaffold(
              backgroundColor: RefPalette.cream,
              body: CenterRefScreen(
                leftName: widget.leftName,
                rightName: widget.rightName,
                live: true,
                liveController: live,
              ),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RefPalette.cream,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _refChatRow(),
            _heading(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
                // Swap the whole stage when the speaker changes so first→second
                // reads as a hand-off rather than an in-place edit.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: Column(
                    key: ValueKey(_index),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _speakerHeader(),
                      const SizedBox(height: 20),
                      _scriptCard(),
                      const SizedBox(height: 26),
                      _recorder(),
                    ],
                  ),
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  /// The ref, small and friendly, coaching the current step from a chat bubble.
  Widget _refChatRow() {
    final line = switch (_current) {
      _CalStatus.idle => 'Read me a line, $_name — I’ll learn your voice.',
      _CalStatus.preparing => 'Opening the mic…',
      _CalStatus.recording => 'Listening… tap when you’re done.',
      _CalStatus.done =>
        _currentMapped
            ? 'Got it. That’s $_name matched.'
            : 'Got the read. That helps me sort the voices.',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const RefHeadBadge(size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _RefChatBubble(text: line),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick voice\ncheck',
            style: zilla(size: 30, weight: FontWeight.w700, height: 1.08),
          ),
          const SizedBox(height: 9),
          Text(
            'Each of you reads one line before the conversation starts, '
            'so the ref can keep the voices straight.',
            style: mulish(
              size: 14,
              color: RefPalette.ink.withValues(alpha: 0.55),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          // Two steps — one per speaker.
          RefProgressDots(count: 2, index: _index),
        ],
      ),
    );
  }

  /// Who's up: accent avatar, name and a "SPEAKER ONE/TWO" eyebrow.
  Widget _speakerHeader() {
    final initial = _name.isEmpty ? '?' : _name.characters.first.toUpperCase();
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
          child: Text(
            initial,
            style: zilla(
              size: 20,
              weight: FontWeight.w700,
              color: RefPalette.cream,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isLast ? 'SPEAKER TWO' : 'SPEAKER ONE',
              style: mulish(
                size: 11,
                weight: FontWeight.w800,
                letterSpacing: 11 * 0.16,
                color: RefPalette.ink.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 2),
            Text(_name, style: zilla(size: 22, weight: FontWeight.w700)),
          ],
        ),
      ],
    );
  }

  /// The line to read, on a soft card. A quotation flourish and the accent bar
  /// make it read as something to be spoken, not a paragraph to skim.
  Widget _scriptCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _accent.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 54,
            margin: const EdgeInsets.only(top: 3, right: 14),
            decoration: BoxDecoration(
              color: _accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'READ THIS OUT LOUD',
                  style: mulish(
                    size: 10,
                    weight: FontWeight.w800,
                    letterSpacing: 10 * 0.16,
                    color: RefPalette.ink.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '“$_script”',
                  style: zilla(
                    size: 19,
                    weight: FontWeight.w500,
                    height: 1.34,
                    color: RefPalette.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The mic, its progress ring, a live meter and a status line — the moving
  /// parts of a single read.
  Widget _recorder() {
    return Column(
      children: [
        AnimatedBuilder(
          animation: _read,
          builder:
              (context, _) => _MicButton(
                status: _current,
                accent: _accent,
                progress: _current == _CalStatus.done ? 1 : _read.value,
                secondsLeft:
                    (_kReadLength.inSeconds * (1 - _read.value)).ceil(),
                onTap: _micAction,
              ),
        ),
        const SizedBox(height: 20),
        // The meter only breathes while a read is live; otherwise it rests flat.
        SizedBox(
          height: 38,
          child: AnimatedBuilder(
            animation: _read,
            builder:
                (context, _) => VolumeWave(
                  color: _accent,
                  level: _current == _CalStatus.recording ? 0.85 : 0.04,
                ),
          ),
        ),
        const SizedBox(height: 16),
        _statusLine(),
      ],
    );
  }

  Widget _statusLine() {
    final live = _live;
    if (live != null && live.isProblem) {
      return Text(
        live.statusLabel,
        textAlign: TextAlign.center,
        style: mulish(
          size: 13.5,
          weight: FontWeight.w700,
          color: RefPalette.red,
        ),
      );
    }

    switch (_current) {
      case _CalStatus.idle:
        return Text(
          'Tap the mic, then read the line above.',
          textAlign: TextAlign.center,
          style: mulish(
            size: 13.5,
            color: RefPalette.ink.withValues(alpha: 0.55),
          ),
        );
      case _CalStatus.preparing:
        return Text(
          live?.statusLabel ?? 'Opening the mic…',
          textAlign: TextAlign.center,
          style: mulish(size: 13.5, weight: FontWeight.w600, color: _accent),
        );
      case _CalStatus.recording:
        return Text(
          'Read the line, then tap the mic when you’re finished.',
          textAlign: TextAlign.center,
          style: mulish(size: 13.5, weight: FontWeight.w600, color: _accent),
        );
      case _CalStatus.done:
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 18,
              color: _currentMapped ? RefPalette.green : RefPalette.olive,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _currentMapped ? 'Voice matched.' : 'Read captured.',
                style: mulish(
                  size: 13.5,
                  weight: FontWeight.w700,
                  color: RefPalette.ink.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _reRecordButton(),
          ],
        );
    }
  }

  Widget _reRecordButton() {
    return InkWell(
      onTap: RefHaptics.wrap(_restartCalibration),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.refresh_rounded,
              size: 15,
              color: RefPalette.ink.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Text(
              'Restart',
              style: mulish(
                size: 13,
                weight: FontWeight.w700,
                color: RefPalette.ink.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    final done = _current == _CalStatus.done;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      child: RefPrimaryButton(
        label: _isLast ? 'Start conversation' : 'Next speaker',
        onPressed: done ? _next : null,
        borderRadius: 18,
        fontSize: 17,
        verticalPadding: 17,
      ),
    );
  }
}

/// The record control: an accent mic in a ring that fills as the read runs,
/// turning into a countdown while live and a green tick when the voice is in.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.status,
    required this.accent,
    required this.progress,
    required this.secondsLeft,
    required this.onTap,
  });

  final _CalStatus status;
  final Color accent;
  final double progress;
  final int secondsLeft;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final preparing = status == _CalStatus.preparing;
    final recording = status == _CalStatus.recording;
    final done = status == _CalStatus.done;
    final ringColor = done ? RefPalette.green : accent;

    return GestureDetector(
      onTap: RefHaptics.wrap(onTap, haptic: RefHaptic.medium),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 128,
        height: 128,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Progress ring — a faint track with the accent sweeping over it.
            SizedBox(
              width: 128,
              height: 128,
              child: CircularProgressIndicator(
                value: preparing ? null : (done || recording ? progress : 0),
                strokeWidth: 5,
                backgroundColor: RefPalette.ink.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation(ringColor),
              ),
            ),
            // The button face.
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    done
                        ? RefPalette.green
                        : (recording
                            ? accent
                            : accent.withValues(
                              alpha: preparing ? 0.22 : 0.14,
                            )),
                boxShadow:
                    recording
                        ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.35),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                        ]
                        : null,
              ),
              alignment: Alignment.center,
              child: _face(preparing, recording, done),
            ),
          ],
        ),
      ),
    );
  }

  Widget _face(bool preparing, bool recording, bool done) {
    if (done) {
      return const Icon(Icons.check_rounded, size: 44, color: RefPalette.cream);
    }
    if (preparing) {
      return SizedBox(
        width: 34,
        height: 34,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation(accent),
        ),
      );
    }
    if (recording) {
      // A stop glyph signals the read can be ended with a tap; the count below
      // it shows the seconds left before it wraps up on its own.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.stop_rounded, size: 32, color: RefPalette.cream),
          const SizedBox(height: 1),
          Text(
            '$secondsLeft',
            style: zilla(
              size: 17,
              weight: FontWeight.w700,
              color: RefPalette.cream.withValues(alpha: 0.9),
            ),
          ),
        ],
      );
    }
    return Icon(Icons.mic_rounded, size: 42, color: accent);
  }
}

/// The ref's coaching bubble — warm orange gradient with the pointer notched
/// into the bottom-left so it reads as coming from the head beside it. Mirrors
/// the welcome screen's bubble.
class _RefChatBubble extends StatelessWidget {
  const _RefChatBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [RefPalette.orange, Color(0xFFD9772F)],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
          bottomLeft: Radius.circular(4),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD8772F).withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Text(
        text,
        style: zilla(size: 15, color: RefPalette.cream, height: 1.2),
      ),
    );
  }
}
