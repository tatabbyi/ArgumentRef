import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../audio/live_ref_controller.dart';
import '../ui/ref_theme.dart';
import 'beats.dart';
import 'referee.dart';
import 'volume_wave.dart';

/// Variant 2a — "Center Ref". The referee is the whole screen: he reacts to the
/// room but never speaks. His eyes track whoever's talking while the brows,
/// mouth and whistle respond live; everything else orbits him.
///
/// In **demo mode** (default) the scene is driven by [kBeats], a scripted loop
/// that advances every [beatDuration] — a faithful rebuild of the design
/// prototype's embedded controller.
///
/// In **live mode** ([live] = true) the same face is driven by a
/// [LiveRefController]: real microphone audio is streamed to the backend and the
/// referee reacts to the transcripts that come back — who holds the floor, the
/// flow balance, interruptions — with the live transcript shown beneath him.
/// Either way the continuous breathing/sway/blink/saccade signals keep him
/// alive.
class CenterRefScreen extends StatefulWidget {
  const CenterRefScreen({
    super.key,
    this.leftName = 'Maya',
    this.rightName = 'Devin',
    this.onEnd,
    this.live = false,
  });

  /// The speaker on the left (green). Defaults to the prototype's "Maya".
  final String leftName;

  /// The speaker on the right (orange). Defaults to the prototype's "Devin".
  final String rightName;

  /// Called when the user ends the session. Defaults to stopping any live
  /// session and popping this route (back to the welcome screen) when null.
  final VoidCallback? onEnd;

  /// When true, capture the microphone and drive the ref from real transcripts
  /// instead of the scripted [kBeats] demo loop.
  final bool live;

  @override
  State<CenterRefScreen> createState() => _CenterRefScreenState();
}

class _CenterRefScreenState extends State<CenterRefScreen>
    with TickerProviderStateMixin {
  // Continuous, always-running signals.
  late final AnimationController _breathe;
  late final AnimationController _sway;
  late final AnimationController _liveDot;
  late final AnimationController _ping;

  // Scripted / discrete signals.
  Timer? _beatTimer;
  Timer? _blinkTimer;
  Timer? _saccadeTimer;
  final _random = math.Random();

  int _beatIndex = 0;
  bool _blinking = false;
  double _saccadeJitter = 0;

  /// The live pipeline, created only in live mode. Null → scripted demo.
  LiveRefController? _live;

  // Demo read-outs persist between beats until a beat overwrites them.
  late int _demoFlow = kBeats.first.flow!;
  late int _demoCut = kBeats.first.cut!;

  /// The current beat — from the live controller when streaming, else the
  /// scripted demo loop.
  Beat get _beat => _live?.beat ?? kBeats[_beatIndex];

  int get _flow => _live?.flow ?? _demoFlow;
  int get _cut => _live?.cutIns ?? _demoCut;

  /// First letter of a name, upper-cased, for the avatar chip.
  String _initial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }

  /// Fills the beat caption's `{L}` / `{R}` tokens with the participant names.
  String get _captionText => _beat.caption
      .replaceAll('{L}', widget.leftName)
      .replaceAll('{R}', widget.rightName);

  @override
  void initState() {
    super.initState();
    // reverse-repeat halves the period so a full there-and-back matches the
    // prototype's keyframe durations (breathe 4.6s, sway 8s, etc.).
    _breathe = _repeat(const Duration(milliseconds: 2300), reverse: true);
    _sway = _repeat(const Duration(milliseconds: 4000), reverse: true);
    _liveDot = _repeat(const Duration(milliseconds: 800), reverse: true);
    _ping = _repeat(const Duration(milliseconds: 1500));

    if (widget.live) {
      final controller = LiveRefController(
        leftName: widget.leftName,
        rightName: widget.rightName,
      );
      _live = controller;
      controller.addListener(_onLive);
      // Fire-and-forget: status/errors surface through the controller's state.
      unawaited(controller.start());
    } else {
      _beatTimer = Timer.periodic(beatDuration, (_) => _advanceBeat());
    }
    _blinkTimer = Timer.periodic(blinkInterval, (_) => _blink());
    _saccadeTimer = Timer.periodic(saccadeInterval, (_) => _saccade());
  }

  void _onLive() {
    if (mounted) setState(() {});
  }

  AnimationController _repeat(Duration period, {bool reverse = false}) {
    return AnimationController(vsync: this, duration: period)
      ..repeat(reverse: reverse);
  }

  void _advanceBeat() {
    if (!mounted) return;
    setState(() {
      _beatIndex = (_beatIndex + 1) % kBeats.length;
      final b = _beat;
      if (b.flow != null) _demoFlow = b.flow!;
      if (b.cut != null) _demoCut = b.cut!;
    });
  }

  void _blink() {
    if (!mounted) return;
    setState(() => _blinking = true);
    Timer(blinkClosedDuration, () {
      if (!mounted) return;
      setState(() => _blinking = false);
    });
  }

  void _saccade() {
    if (!mounted) return;
    // Prototype: j = (Math.random() - 0.5) * 3 — a small horizontal tremor.
    setState(() => _saccadeJitter = (_random.nextDouble() - 0.5) * 3);
  }

  @override
  void dispose() {
    _beatTimer?.cancel();
    _blinkTimer?.cancel();
    _saccadeTimer?.cancel();
    _live?.removeListener(_onLive);
    _live?.dispose();
    _breathe.dispose();
    _sway.dispose();
    _liveDot.dispose();
    _ping.dispose();
    super.dispose();
  }

  /// Ends a live session promptly (the controller also stops on dispose) and
  /// returns to the welcome screen.
  void _handleEnd() {
    unawaited(_live?.stop());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: RefPalette.cream,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(),
            if (_live != null) _statusBar(_live!),
            _guidance(),
            Expanded(child: _stage()),
            if (_live != null) _transcriptPanel(_live!),
            _stats(),
            _endButton(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── End session ────────────────────────────────────────────────────────
  /// A prominent "end call"-style action that closes the live session and
  /// returns to the welcome screen.
  Widget _endButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
      child: RefPrimaryButton(
        label: 'End session',
        color: RefPalette.red,
        onPressed: widget.onEnd ?? _handleEnd,
      ),
    );
  }

  // ── Title ──────────────────────────────────────────────────────────────
  Widget _title() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'CONVERSATION REFEREE',
            style: zilla(
              size: 14,
              weight: FontWeight.w700,
              letterSpacing: 14 * 0.16,
            ),
          ),
          const SizedBox(width: 10),
          // Live "on air" pulse.
          AnimatedBuilder(
            animation: _liveDot,
            builder: (context, _) {
              final v = _liveDot.value;
              return Opacity(
                opacity: 1 - 0.65 * v,
                child: Transform.scale(
                  scale: 1 - 0.3 * v,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: RefPalette.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Live status ─────────────────────────────────────────────────────────
  /// A one-line banner under the title describing the audio/transcription
  /// pipeline state (connecting / listening / live / mic denied / error).
  Widget _statusBar(LiveRefController live) {
    final problem = live.isProblem;
    final color = problem ? RefPalette.red : RefPalette.olive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              live.statusLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: mulish(
                size: 11.5,
                weight: FontWeight.w700,
                letterSpacing: 0.2,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Live transcript ─────────────────────────────────────────────────────
  /// The rolling transcript beneath the ref: finalised lines plus the in-flight
  /// (interim) line, newest at the bottom.
  Widget _transcriptPanel(LiveRefController live) {
    final lines = live.transcript;
    final rows = <Widget>[
      if (live.hasPartial)
        _transcriptRow(live.partialSpeaker, live.partialText, faded: true),
      for (final line in lines.reversed)
        _transcriptRow(line.speaker, line.text, faded: false),
    ];

    return Container(
      height: 92,
      margin: const EdgeInsets.fromLTRB(22, 4, 22, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: RefPalette.ink.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: rows.isEmpty
          ? Center(
              child: Text(
                'What everyone says will show up here.',
                style: mulish(
                  size: 12.5,
                  color: RefPalette.ink.withValues(alpha: 0.4),
                ),
              ),
            )
          : ListView(
              reverse: true,
              padding: EdgeInsets.zero,
              children: rows,
            ),
    );
  }

  Widget _transcriptRow(Speaker speaker, String text, {required bool faded}) {
    final color = switch (speaker) {
      Speaker.left => RefPalette.green,
      Speaker.right => RefPalette.orange,
      Speaker.none => RefPalette.olive,
    };
    final name = switch (speaker) {
      Speaker.left => widget.leftName,
      Speaker.right => widget.rightName,
      Speaker.none => 'Someone',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$name  ',
              style: mulish(size: 12.5, weight: FontWeight.w800, color: color),
            ),
            TextSpan(
              text: text,
              style: mulish(
                size: 12.5,
                weight: FontWeight.w500,
                color: RefPalette.ink.withValues(alpha: faded ? 0.45 : 0.82),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage ──────────────────────────────────────────────────────────────
  Widget _stage() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.85,
          colors: [Color(0x2EE8963C), Color(0x00FBF3E7)],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 16,
            top: 6,
            child: _Speaker(
              initial: _initial(widget.leftName),
              name: widget.leftName,
              color: RefPalette.green,
              active: _beat.active == Speaker.left,
              ping: _ping,
            ),
          ),
          Positioned(
            right: 16,
            top: 6,
            child: _Speaker(
              initial: _initial(widget.rightName),
              name: widget.rightName,
              color: RefPalette.orange,
              active: _beat.active == Speaker.right,
              ping: _ping,
            ),
          ),
          Align(
            alignment: const Alignment(0, -0.05),
            child: RefereeFace(
              beat: _beat,
              blinking: _blinking,
              saccadeJitter: _saccadeJitter,
              breathe: _breathe,
              sway: _sway,
            ),
          ),
          // The room-volume wave sits under the ref, anchored to the bottom of
          // the stage. (The ref's guidance now lives above him — see _guidance.)
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Center(
              child: SizedBox(
                width: math.min(248.0, MediaQuery.sizeOf(context).width - 96),
                child: VolumeWave(
                  color: _waveColor,
                  level: _roomLevel,
                  height: 48,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The wave tints toward whoever holds the floor, flushing red when the ref
  /// flags a cut-in or goes on alert.
  Color get _waveColor => switch (_beat.mood) {
    Mood.alert || Mood.concern => RefPalette.red,
    _ => switch (_beat.active) {
      Speaker.left => RefPalette.green,
      Speaker.right => RefPalette.orange,
      Speaker.none => RefPalette.olive,
    },
  };

  /// How energetic the room reads — quietest when no one holds the floor,
  /// loudest on a cut-in.
  double get _roomLevel => switch (_beat.mood) {
    Mood.alert => 1.0,
    Mood.concern => 0.85,
    Mood.approve => 0.7,
    Mood.curious => 0.6,
    Mood.listen => _beat.active == Speaker.none ? 0.28 : 0.6,
  };

  // ── Guidance ───────────────────────────────────────────────────────────
  /// The ref's live coaching cue — what the room should do next — sitting
  /// prominently above him with its tail pointing down so it reads as his call.
  /// Falls back to a quiet "watching the room" line when there's nothing to
  /// flag.
  Widget _guidance() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 2),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 48,
          ),
          child: RefSpeechBubble(text: _captionText, pointDown: true),
        ),
      ),
    );
  }

  // ── Stats ──────────────────────────────────────────────────────────────
  Widget _stats() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _flowBalance(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _cutInsTile()),
              const SizedBox(width: 10),
              Expanded(child: _roomToneTile()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _flowBalance() {
    final labelStyle = mulish(
      size: 11,
      weight: FontWeight.w700,
      letterSpacing: 11 * 0.12,
      color: RefPalette.ink.withValues(alpha: 0.5),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('FLOW BALANCE', style: labelStyle),
            Text('$_flow/100', style: labelStyle),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Container(
            height: 8,
            color: RefPalette.ink.withValues(alpha: 0.1),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _flow / 100),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              builder: (context, value, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.clamp(0.0, 1.0),
                child: const ColoredBox(color: RefPalette.green),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _cutInsTile() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: RefPalette.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CUT-INS',
            style: mulish(
              size: 10,
              weight: FontWeight.w700,
              letterSpacing: 10 * 0.12,
              color: RefPalette.red,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$_cut',
            style: zilla(
              size: 22,
              weight: FontWeight.w700,
              color: RefPalette.red,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomToneTile() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: RefPalette.green.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ROOM TONE',
            style: mulish(
              size: 10,
              weight: FontWeight.w700,
              letterSpacing: 10 * 0.12,
              color: RefPalette.olive,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Warming',
            style: zilla(
              size: 16,
              weight: FontWeight.w600,
              color: RefPalette.olive,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// A speaker chip that orbits the referee — dims when off the floor, brightens
/// and pings with a concentric ring when it holds the floor.
class _Speaker extends StatelessWidget {
  const _Speaker({
    required this.initial,
    required this.name,
    required this.color,
    required this.active,
    required this.ping,
  });

  final String initial;
  final String name;
  final Color color;
  final bool active;
  final Animation<double> ping;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: active ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: active ? 1.0 : 0.45,
        duration: const Duration(milliseconds: 450),
        child: Column(
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (active)
                    Positioned(
                      left: -7,
                      top: -7,
                      right: -7,
                      bottom: -7,
                      child: AnimatedBuilder(
                        animation: ping,
                        builder: (context, _) {
                          final v = ping.value;
                          final scale = 0.65 +
                              (1.9 - 0.65) * Curves.easeOut.transform(v);
                          final opacity = v < 0.8 ? 0.5 * (1 - v / 0.8) : 0.0;
                          return Transform.scale(
                            scale: scale,
                            child: Opacity(
                              opacity: opacity,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: color, width: 2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      initial,
                      style: zilla(
                        size: 22,
                        weight: FontWeight.w700,
                        color: RefPalette.cream,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              style: zilla(size: 14, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
