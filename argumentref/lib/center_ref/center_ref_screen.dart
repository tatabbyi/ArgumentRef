import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../audio/compromise_sound_player.dart';
import '../audio/live_ref_controller.dart';
import '../audio/ref_events.dart';
import '../audio/ref_voice.dart';
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
  Timer? _compromiseAutoCollapseTimer;
  final _random = math.Random();

  int _beatIndex = 0;
  bool _blinking = false;
  double _saccadeJitter = 0;
  String? _visibleCompromiseSetKey;
  bool _compromisePanelExpanded = false;
  bool _compromiseSetClicked = false;

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
            timeOutSoundPlayer: LongWhiteTimeOutPlayer(),
            voice: ElevenLabsRefVoice(),
          );
      _live = controller;
      // The conversation is where the ref speaks — read the "the ref says"
      // bubble aloud (calibration leaves this off so it stays quiet).
      controller.voiceEnabled = true;
      controller.addListener(_onLive);
      _syncCompromisePanelState();
      // Fire-and-forget: status/errors surface through the controller's state.
      unawaited(controller.start());
    } else {
      _beatTimer = Timer.periodic(beatDuration, (_) => _advanceBeat());
    }
    _blinkTimer = Timer.periodic(blinkInterval, (_) => _blink());
    _saccadeTimer = Timer.periodic(saccadeInterval, (_) => _saccade());
  }

  void _onLive() {
    if (!mounted) return;
    _syncCompromisePanelState();
    setState(() {});
  }

  void _syncCompromisePanelState() {
    final suggestions = _live?.compromises ?? const <CompromiseSuggestion>[];
    if (suggestions.isEmpty) {
      _compromiseAutoCollapseTimer?.cancel();
      _visibleCompromiseSetKey = null;
      _compromisePanelExpanded = false;
      _compromiseSetClicked = false;
      return;
    }

    final key = _compromiseSetKey(suggestions);
    if (key == _visibleCompromiseSetKey) return;

    _visibleCompromiseSetKey = key;
    _compromisePanelExpanded = true;
    _compromiseSetClicked = false;
    _compromiseAutoCollapseTimer?.cancel();
    _compromiseAutoCollapseTimer = Timer(
      const Duration(seconds: 5),
      () => _collapseCompromisesIfUnclicked(key),
    );
  }

  String _compromiseSetKey(List<CompromiseSuggestion> suggestions) {
    return suggestions
        .map((suggestion) => '${suggestion.id}:${suggestion.score}')
        .join('|');
  }

  void _collapseCompromisesIfUnclicked(String key) {
    if (!mounted || key != _visibleCompromiseSetKey || _compromiseSetClicked) {
      return;
    }

    setState(() => _compromisePanelExpanded = false);
  }

  void _expandCompromisePanel() {
    if (_live?.compromises.isEmpty ?? true) return;
    setState(() => _compromisePanelExpanded = true);
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
    _compromiseAutoCollapseTimer?.cancel();
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
        child: Stack(
          children: [
            Column(
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
            if (_live?.timeOutActive ?? false) _timeOutOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _timeOutOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _ping,
          builder: (context, _) {
            final pulse = (math.sin(_ping.value * math.pi * 2) + 1) / 2;
            final eased = Curves.easeInOut.transform(pulse);

            return Semantics(
              liveRegion: true,
              label:
                  'Time out. Voices are too loud. Lower voices to stop the whistle.',
              child: ColoredBox(
                color: RefPalette.red.withValues(alpha: 0.12 + eased * 0.2),
                child: Center(
                  child: Transform.scale(
                    scale: 1 + eased * 0.045,
                    child: Container(
                      width: math.min(
                        420.0,
                        MediaQuery.sizeOf(context).width - 44,
                      ),
                      margin: const EdgeInsets.all(22),
                      padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
                      decoration: BoxDecoration(
                        color: RefPalette.red.withValues(
                          alpha: 0.86 + eased * 0.12,
                        ),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: RefPalette.cream.withValues(alpha: 0.78),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: RefPalette.red.withValues(alpha: 0.42),
                            blurRadius: 32 + eased * 16,
                            spreadRadius: 4 + eased * 8,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.front_hand_rounded,
                            size: 44,
                            color: RefPalette.cream.withValues(alpha: 0.96),
                          ),
                          const SizedBox(height: 12),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'TIME OUT',
                              maxLines: 1,
                              style: zilla(
                                size: 58,
                                weight: FontWeight.w700,
                                color: RefPalette.cream,
                                height: 0.92,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Lower voices to stop the whistle.',
                            textAlign: TextAlign.center,
                            style: mulish(
                              size: 16,
                              weight: FontWeight.w900,
                              color: RefPalette.cream.withValues(alpha: 0.92),
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
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
    final showSuggestions = hasSuggestions && _compromisePanelExpanded;

    return GestureDetector(
      onTap: hasSuggestions && !showSuggestions ? _expandCompromisePanel : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        height: showSuggestions ? _compromisePanelHeight(context) : 62,
        margin: const EdgeInsets.fromLTRB(22, 4, 22, 0),
        padding:
            showSuggestions
                ? const EdgeInsets.fromLTRB(14, 12, 14, 14)
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
            !showSuggestions
                ? Center(
                  child: Text(
                    hasSuggestions
                        ? 'Compromises ready - tap to view'
                        : status ?? 'Listening for a fair deal.',
                    textAlign: TextAlign.center,
                    style: mulish(
                      size: 12.5,
                      weight: FontWeight.w700,
                      color:
                          hasSuggestions
                              ? _compromiseColor(suggestions.first)
                              : RefPalette.ink.withValues(alpha: 0.48),
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
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder:
                            (context, index) =>
                                _compromiseTile(suggestions[index]),
                      ),
                    ),
                  ],
                ),
      ),
    );
  }

  Widget _compromiseTile(CompromiseSuggestion suggestion) {
    final color = _compromiseColor(suggestion);
    final urgent = suggestion.shouldPushHard;

    return Semantics(
      button: true,
      label: 'Open details for ${suggestion.title}',
      child: Material(
        color: color.withValues(alpha: urgent ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: RefHaptics.wrap(
            () => unawaited(_showCompromiseDetails(suggestion)),
            haptic: RefHaptic.selection,
          ),
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 78),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${suggestion.rank}',
                      style: zilla(
                        size: 16,
                        weight: FontWeight.w700,
                        color: RefPalette.cream,
                        height: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                                  size: urgent ? 16.5 : 15.5,
                                  weight: FontWeight.w700,
                                  color: RefPalette.ink,
                                  height: 1.05,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _compromiseLabel(suggestion),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: mulish(
                                  size: 10,
                                  weight: FontWeight.w900,
                                  color: color,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          suggestion.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: mulish(
                            size: 12.3,
                            weight: FontWeight.w600,
                            color: RefPalette.ink.withValues(alpha: 0.68),
                            height: 1.18,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 9),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 19,
                    color: color.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _compromisePanelHeight(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return math.min(292.0, math.max(226.0, screenHeight * 0.34));
  }

  Future<void> _showCompromiseDetails(CompromiseSuggestion suggestion) async {
    _compromiseSetClicked = true;
    _compromiseAutoCollapseTimer?.cancel();
    final compromiseSetKey = _visibleCompromiseSetKey;
    final color = _compromiseColor(suggestion);
    final label = _compromiseLabel(suggestion);

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close compromise details',
      barrierColor: RefPalette.ink.withValues(alpha: 0.34),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, _) {
        final height = MediaQuery.sizeOf(dialogContext).height;
        return SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: _CompromiseDetailsModal(
                suggestion: suggestion,
                color: color,
                label: label,
                maxHeight: math.max(260, height - 44),
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final eased = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: eased,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(eased),
            child: child,
          ),
        );
      },
    );

    if (!mounted || compromiseSetKey != _visibleCompromiseSetKey) return;
    setState(() => _compromisePanelExpanded = false);
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
              roomTone: _roomToneFor(Speaker.left),
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
              roomTone: _roomToneFor(Speaker.right),
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

  RoomToneStatus? _roomToneFor(Speaker speaker) {
    final tone = _live?.roomTone;
    if (tone == null || !tone.hasAiSignal || tone.speaker != speaker) {
      return null;
    }
    return tone;
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
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _cutInsTile()),
                const SizedBox(width: 10),
                Expanded(child: _roomToneTile()),
              ],
            ),
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

    return _directionalCutInsTile(
      leftCutRight: stats.leftCutRight,
      rightCutLeft: stats.rightCutLeft,
      latest: stats.latest,
    );
  }

  Widget _directionalCutInsTile({
    required int leftCutRight,
    required int rightCutLeft,
    InterruptionIncident? latest,
  }) {
    final latestInterrupter = latest?.interrupter;

    return Container(
      key: const ValueKey('center-ref-cut-ins-tile'),
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
          const SizedBox(height: 7),
          _cutInDirection(
            '${widget.leftName} cut off ${widget.rightName}',
            leftCutRight,
            RefPalette.green,
            isLatest: latestInterrupter == Speaker.left,
          ),
          const SizedBox(height: 5),
          _cutInDirection(
            '${widget.rightName} cut off ${widget.leftName}',
            rightCutLeft,
            RefPalette.orange,
            isLatest: latestInterrupter == Speaker.right,
          ),
        ],
      ),
    );
  }

  Widget _simpleCutInsTile(int total) {
    final rightCutLeft = (total / 2).ceil();
    final leftCutRight = total - rightCutLeft;

    return _directionalCutInsTile(
      leftCutRight: leftCutRight,
      rightCutLeft: rightCutLeft,
    );
  }

  Widget _cutInDirection(
    String label,
    int count,
    Color color, {
    bool isLatest = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mulish(
              size: 10.5,
              weight: FontWeight.w800,
              color: RefPalette.ink.withValues(alpha: isLatest ? 0.76 : 0.58),
              height: 1.05,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 28,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: isLatest ? 0.2 : 0.11),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: color.withValues(alpha: isLatest ? 0.34 : 0.12),
            ),
          ),
          child: Text(
            '$count',
            style: zilla(
              size: 17,
              weight: FontWeight.w700,
              color: color,
              height: 1,
            ),
          ),
        ),
      ],
    );
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
      key: const ValueKey('center-ref-room-tone-tile'),
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

class _CompromiseDetailsModal extends StatelessWidget {
  const _CompromiseDetailsModal({
    required this.suggestion,
    required this.color,
    required this.label,
    required this.maxHeight,
    required this.onClose,
  });

  final CompromiseSuggestion suggestion;
  final Color color;
  final String label;
  final double maxHeight;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final boundedHeight = math.min(620.0, math.max(260.0, maxHeight));

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 430, maxHeight: boundedHeight),
      child: Material(
        color: RefPalette.cream,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: RefPalette.ink.withValues(alpha: 0.14)),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: RefPalette.ink.withValues(alpha: 0.16),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${suggestion.rank}',
                        style: zilla(
                          size: 20,
                          weight: FontWeight.w700,
                          color: RefPalette.cream,
                          height: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            suggestion.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: zilla(
                              size: 24,
                              weight: FontWeight.w700,
                              color: RefPalette.ink,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$label / ${suggestion.score}/100',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mulish(
                              size: 11,
                              weight: FontWeight.w900,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _closeButton(),
                  ],
                ),
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _detailSection('THE OFFER', suggestion.summary),
                        const SizedBox(height: 16),
                        _detailSection(
                          'WHY IT COULD WORK',
                          suggestion.whyItCouldWork,
                        ),
                        const SizedBox(height: 18),
                        _scoreBar(),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _metric(
                                'QUALITY',
                                _qualityText(suggestion.quality),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _metric(
                                'PUSH LEVEL',
                                _pushLevelText(suggestion.pushLevel),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _closeButton() {
    return Semantics(
      button: true,
      label: 'Close compromise details',
      child: Material(
        color: RefPalette.ink.withValues(alpha: 0.06),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: RefHaptics.wrap(onClose),
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              Icons.close_rounded,
              size: 21,
              color: RefPalette.ink.withValues(alpha: 0.58),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailSection(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: mulish(size: 10.5, weight: FontWeight.w900, color: color),
        ),
        const SizedBox(height: 7),
        Text(
          body,
          style: mulish(
            size: 15,
            weight: FontWeight.w600,
            color: RefPalette.ink.withValues(alpha: 0.78),
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Widget _scoreBar() {
    final score = (suggestion.score / 100).clamp(0.0, 1.0).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'SCORE',
              style: mulish(size: 10.5, weight: FontWeight.w900, color: color),
            ),
            Text(
              '${suggestion.score}/100',
              style: zilla(
                size: 18,
                weight: FontWeight.w700,
                color: color,
                height: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Container(
            height: 8,
            color: RefPalette.ink.withValues(alpha: 0.1),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: score,
              child: ColoredBox(color: color),
            ),
          ),
        ),
      ],
    );
  }

  Widget _metric(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: mulish(size: 10.5, weight: FontWeight.w900, color: color),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: zilla(
            size: 17,
            weight: FontWeight.w700,
            color: RefPalette.ink,
            height: 1.05,
          ),
        ),
      ],
    );
  }

  String _qualityText(CompromiseQuality quality) {
    return switch (quality) {
      CompromiseQuality.reallyGood => 'Really good',
      CompromiseQuality.strong => 'Strong',
      CompromiseQuality.promising => 'Promising',
      CompromiseQuality.weak => 'Early',
    };
  }

  String _pushLevelText(CompromisePushLevel pushLevel) {
    return switch (pushLevel) {
      CompromisePushLevel.urgent => 'Urgent',
      CompromisePushLevel.firm => 'Firm',
      CompromisePushLevel.normal => 'Normal',
    };
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
    this.roomTone,
  });

  final String initial;
  final String name;
  final Color color;
  final bool active;
  final Animation<double> ping;
  final RoomToneStatus? roomTone;

  @override
  Widget build(BuildContext context) {
    final tone = roomTone;
    final hasTone = tone != null;
    final toneColor =
        tone == null
            ? color
            : tone.isHeated
            ? RefPalette.red
            : tone.isRepairing
            ? RefPalette.green
            : RefPalette.olive;
    final pulsing = tone?.isHeated ?? false;

    return AnimatedBuilder(
      animation: ping,
      builder: (context, _) {
        final pulse = Curves.easeInOut.transform(ping.value);
        final ringAlpha =
            !hasTone
                ? 0.0
                : pulsing
                ? 0.36 + 0.3 * pulse
                : 0.32;
        final fillAlpha =
            !hasTone
                ? 0.0
                : pulsing
                ? 0.08 + 0.08 * pulse
                : 0.1;
        final glowAlpha =
            !hasTone
                ? 0.0
                : pulsing
                ? 0.18 + 0.22 * pulse
                : 0.12;

        return AnimatedScale(
          scale:
              active
                  ? 1.06
                  : hasTone
                  ? 1.03
                  : 1.0,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: active || hasTone ? 1.0 : 0.45,
            duration: const Duration(milliseconds: 450),
            child: Container(
              key: hasTone ? ValueKey('speaker-room-tone-$name') : null,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
              decoration: BoxDecoration(
                color:
                    hasTone
                        ? toneColor.withValues(alpha: fillAlpha)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                border:
                    hasTone
                        ? Border.all(
                          color: toneColor.withValues(alpha: ringAlpha),
                          width: pulsing ? 2.2 + 1.2 * pulse : 1.6,
                        )
                        : null,
                boxShadow:
                    hasTone
                        ? [
                          BoxShadow(
                            color: toneColor.withValues(alpha: glowAlpha),
                            blurRadius: pulsing ? 18 + 12 * pulse : 14,
                            spreadRadius: pulsing ? 2 + 3 * pulse : 1,
                          ),
                        ]
                        : const [],
              ),
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
                            child: Transform.scale(
                              scale:
                                  0.65 +
                                  (1.9 - 0.65) *
                                      Curves.easeOut.transform(ping.value),
                              child: Opacity(
                                opacity:
                                    ping.value < 0.8
                                        ? 0.5 * (1 - ping.value / 0.8)
                                        : 0.0,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: color, width: 2),
                                  ),
                                ),
                              ),
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
                  if (hasTone) ...[
                    const SizedBox(height: 5),
                    Container(
                      constraints: const BoxConstraints(maxWidth: 88),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: toneColor.withValues(
                          alpha: pulsing ? 0.92 : 0.18,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tone.label.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mulish(
                          size: 9,
                          weight: FontWeight.w900,
                          color: pulsing ? RefPalette.cream : toneColor,
                          height: 1,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
