import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../audio/compromise_sound_player.dart';
import '../audio/live_ref_controller.dart';
import '../audio/ref_events.dart';
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
/// flow balance, interruptions, and likely compromises.
/// Either way the continuous breathing/sway/blink/saccade signals keep him
/// alive.
class CenterRefScreen extends StatefulWidget {
  const CenterRefScreen({
    super.key,
    this.leftName = 'Maya',
    this.rightName = 'Devin',
    this.onEnd,
    this.live = false,
    this.liveController,
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

  /// An already-started live pipeline, usually handed off from calibration.
  final LiveRefController? liveController;

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

    if (widget.live || widget.liveController != null) {
      final controller =
          widget.liveController ??
          LiveRefController(
            leftName: widget.leftName,
            rightName: widget.rightName,
            compromiseSoundPlayer: RefereeWhistlePlayer(),
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
            if (_live != null) _compromisePanel(_live!),
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
        haptic: RefHaptic.heavy,
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

  // ── Live compromises ────────────────────────────────────────────────────
  Widget _compromisePanel(LiveRefController live) {
    final suggestions = live.compromises;
    final status = live.compromiseStatusLabel;
    final hasSuggestions = suggestions.isNotEmpty;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      height: hasSuggestions ? 218 : 62,
      margin: const EdgeInsets.fromLTRB(22, 4, 22, 0),
      padding:
          hasSuggestions
              ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: RefPalette.cream,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RefPalette.ink.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: RefPalette.ink.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child:
          !hasSuggestions
              ? Center(
                child: Text(
                  status ?? 'Listening for a fair deal.',
                  textAlign: TextAlign.center,
                  style: mulish(
                    size: 12.5,
                    weight: FontWeight.w700,
                    color: RefPalette.ink.withValues(alpha: 0.48),
                  ),
                ),
              )
              : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'COMPROMISES',
                        style: mulish(
                          size: 10,
                          weight: FontWeight.w800,
                          color: RefPalette.ink.withValues(alpha: 0.48),
                        ),
                      ),
                      Text(
                        '${suggestions.first.score}/100',
                        style: mulish(
                          size: 10.5,
                          weight: FontWeight.w800,
                          color: _compromiseColor(suggestions.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Expanded(
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: suggestions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder:
                          (context, index) =>
                              _compromiseTile(suggestions[index]),
                    ),
                  ),
                ],
              ),
    );
  }

  Widget _compromiseTile(CompromiseSuggestion suggestion) {
    final color = _compromiseColor(suggestion);
    final urgent = suggestion.shouldPushHard;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: urgent ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: urgent ? 0.42 : 0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Text(
              '${suggestion.rank}',
              style: zilla(
                size: 14,
                weight: FontWeight.w700,
                color: RefPalette.cream,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        suggestion.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: zilla(
                          size: urgent ? 15 : 14,
                          weight: FontWeight.w700,
                          color: RefPalette.ink,
                          height: 1.05,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _compromiseLabel(suggestion),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mulish(
                        size: 9.5,
                        weight: FontWeight.w900,
                        color: color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  suggestion.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mulish(
                    size: 11.5,
                    weight: FontWeight.w600,
                    color: RefPalette.ink.withValues(alpha: 0.68),
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _compromiseColor(CompromiseSuggestion suggestion) {
    if (suggestion.shouldPushHard) return RefPalette.red;
    return switch (suggestion.quality) {
      CompromiseQuality.strong => RefPalette.green,
      CompromiseQuality.promising => RefPalette.orange,
      CompromiseQuality.weak => RefPalette.olive,
      CompromiseQuality.reallyGood => RefPalette.red,
    };
  }

  String _compromiseLabel(CompromiseSuggestion suggestion) {
    if (suggestion.shouldPushHard) return 'PUSH THIS';
    return switch (suggestion.quality) {
      CompromiseQuality.reallyGood => 'REALLY GOOD',
      CompromiseQuality.strong => 'STRONG',
      CompromiseQuality.promising => 'PROMISING',
      CompromiseQuality.weak => 'EARLY',
    };
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
  Color get _waveColor {
    final tone = _live?.roomTone;
    if (tone != null && tone.isHeated) return RefPalette.red;
    if (tone != null && tone.isRepairing) return RefPalette.green;

    return switch (_beat.mood) {
      Mood.alert || Mood.concern => RefPalette.red,
      _ => switch (_beat.active) {
        Speaker.left => RefPalette.green,
        Speaker.right => RefPalette.orange,
        Speaker.none => RefPalette.olive,
      },
    };
  }

  /// How energetic the room reads — quietest when no one holds the floor,
  /// loudest on a cut-in.
  double get _roomLevel =>
      _live?.roomTone.waveLevel ??
      switch (_beat.mood) {
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
              builder:
                  (context, value, _) => FractionallySizedBox(
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
    final stats = _live?.interruptions;
    if (stats == null) {
      return _simpleCutInsTile(_cut);
    }

    final latest = stats.latest;
    final latestLabel =
        latest == null
            ? 'No clear direction yet'
            : '${_speakerName(latest.interrupter)} cut ${_speakerName(latest.interrupted)}';

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${stats.total}',
                style: zilla(
                  size: 22,
                  weight: FontWeight.w700,
                  color: RefPalette.red,
                  height: 1,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  latestLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mulish(
                    size: 10,
                    weight: FontWeight.w800,
                    color: RefPalette.ink.withValues(alpha: 0.52),
                    height: 1.05,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          _cutInDirection(
            '${widget.leftName} cut ${widget.rightName}',
            stats.leftCutRight,
            RefPalette.green,
          ),
          const SizedBox(height: 3),
          _cutInDirection(
            '${widget.rightName} cut ${widget.leftName}',
            stats.rightCutLeft,
            RefPalette.orange,
          ),
        ],
      ),
    );
  }

  Widget _simpleCutInsTile(int total) {
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
            '$total',
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

  Widget _cutInDirection(String label, int count, Color color) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mulish(
              size: 10.2,
              weight: FontWeight.w700,
              color: RefPalette.ink.withValues(alpha: 0.58),
              height: 1.05,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: zilla(
            size: 14,
            weight: FontWeight.w700,
            color: color,
            height: 1,
          ),
        ),
      ],
    );
  }

  String _speakerName(Speaker speaker) {
    return switch (speaker) {
      Speaker.left => widget.leftName,
      Speaker.right => widget.rightName,
      Speaker.none => 'Someone',
    };
  }

  Widget _roomToneTile() {
    final tone =
        _live?.roomTone ??
        const RoomToneStatus(
          label: 'Warming',
          detail: 'Demo room energy',
          score: 42,
          loudness: 0.4,
          isHeated: false,
          isRepairing: false,
          hasAiSignal: false,
        );
    final color =
        tone.isHeated
            ? RefPalette.red
            : tone.isRepairing
            ? RefPalette.green
            : RefPalette.olive;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: tone.isHeated ? 0.12 : 0.16),
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
              color: color,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            tone.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: zilla(
              size: 16,
              weight: FontWeight.w600,
              color: color,
              height: 1,
            ),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 5,
              color: RefPalette.ink.withValues(alpha: 0.08),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (tone.score / 100).clamp(0.0, 1.0).toDouble(),
                child: ColoredBox(color: color),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            tone.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mulish(
              size: 10.5,
              weight: FontWeight.w700,
              color: RefPalette.ink.withValues(alpha: 0.52),
              height: 1.05,
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
                          final scale =
                              0.65 + (1.9 - 0.65) * Curves.easeOut.transform(v);
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
            Text(name, style: zilla(size: 14, weight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
