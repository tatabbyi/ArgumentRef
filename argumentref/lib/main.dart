import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  runApp(const ArgumentRefApp());
}

class ArgumentRefApp extends StatelessWidget {
  const ArgumentRefApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Argument Referee',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16636F),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F4EE),
        fontFamily: 'Roboto',
      ),
      home: const SessionHomeScreen(),
    );
  }
}

class LiveSessionController extends ChangeNotifier {
  LiveSessionController({SpeechToText? speechToText})
    : _speechToText = speechToText ?? SpeechToText();

  final SpeechToText _speechToText;
  final Stopwatch _sessionClock = Stopwatch();
  final List<TranscriptLine> _transcript = [];
  final List<FactCheckItem> _checks = [];

  Timer? _meterTimer;
  Timer? _restartTimer;
  DateTime? _lastMeterTick;
  bool _speechInitialized = false;
  bool _speechAvailable = false;
  bool _sessionRunning = false;
  bool _initializing = false;
  bool _userStopped = true;
  double _rawMinLevel = 999;
  double _rawMaxLevel = -999;
  double _soundLevel = 0;
  String _partialTranscript = '';
  String _statusMessage = 'Ready to listen';
  String? _lastCommittedText;
  Duration _speechTime = Duration.zero;
  int _nextClaimId = 1;

  bool get sessionRunning => _sessionRunning;
  bool get initializing => _initializing;
  bool get speechAvailable => _speechAvailable;
  bool get speechInitialized => _speechInitialized;
  bool get isListening => _speechToText.isListening;
  double get soundLevel => _soundLevel;
  String get partialTranscript => _partialTranscript;
  String get statusMessage => _statusMessage;
  Duration get elapsed => _sessionClock.elapsed;
  Duration get totalTalkTime => _speechTime;
  int get totalInterruptions => 0;
  int get claimCount => _checks.length;

  List<TranscriptLine> get transcript => List.unmodifiable(_transcript);
  List<FactCheckItem> get checks => List.unmodifiable(_checks);

  List<SpeakerStats> get speakers {
    return [
      SpeakerStats(
        name: 'Live mic',
        role: 'Device speech recognizer',
        color: const Color(0xFF16636F),
        talkTime: _speechTime,
        interruptions: 0,
        volumeLevel: _soundLevel,
        isSpeaking: _sessionRunning && _soundLevel > 0.18,
      ),
    ];
  }

  Future<void> toggleSession() async {
    if (_sessionRunning || _initializing) {
      await stopSession();
      return;
    }

    await startSession();
  }

  Future<void> startSession() async {
    if (_sessionRunning || _initializing) {
      return;
    }

    _initializing = true;
    _statusMessage = 'Checking microphone and speech access';
    notifyListeners();

    try {
      if (!_speechInitialized) {
        _speechAvailable = await _speechToText.initialize(
          onStatus: _handleSpeechStatus,
          onError: _handleSpeechError,
          finalTimeout: const Duration(seconds: 2),
        );
        _speechInitialized = true;
      }

      if (!_speechAvailable) {
        _statusMessage =
            'Speech recognition is unavailable or permission was denied';
        _sessionRunning = false;
        return;
      }

      _userStopped = false;
      _sessionRunning = true;
      _sessionClock.start();
      _startMeter();
      _statusMessage = 'Listening. Speak normally.';
      await _startListening();
    } catch (error) {
      _sessionRunning = false;
      _statusMessage = 'Could not start listening: $error';
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> stopSession() async {
    _userStopped = true;
    _sessionRunning = false;
    _restartTimer?.cancel();
    _meterTimer?.cancel();
    _lastMeterTick = null;
    _sessionClock.stop();
    _partialTranscript = '';
    _soundLevel = 0;
    _statusMessage = 'Stopped';

    if (_speechToText.isListening) {
      await _speechToText.stop();
    }

    notifyListeners();
  }

  Future<void> resetSession() async {
    await stopSession();
    _sessionClock.reset();
    _transcript.clear();
    _checks.clear();
    _partialTranscript = '';
    _lastCommittedText = null;
    _speechTime = Duration.zero;
    _soundLevel = 0;
    _rawMinLevel = 999;
    _rawMaxLevel = -999;
    _nextClaimId = 1;
    _statusMessage = 'Ready to listen';
    notifyListeners();
  }

  String exportText() {
    final buffer =
        StringBuffer()
          ..writeln('Argument Referee session')
          ..writeln('Elapsed: ${formatDuration(elapsed)}')
          ..writeln('Detected talk time: ${formatDuration(totalTalkTime)}')
          ..writeln('Claims detected: ${checks.length}')
          ..writeln()
          ..writeln('Transcript');

    if (_transcript.isEmpty) {
      buffer.writeln('No transcript captured.');
    } else {
      for (final line in _transcript) {
        buffer.writeln('[${line.timestamp}] ${line.speaker}: ${line.text}');
      }
    }

    buffer
      ..writeln()
      ..writeln('Fact-check queue');

    if (_checks.isEmpty) {
      buffer.writeln('No checkable claims detected.');
    } else {
      for (final item in _checks) {
        buffer.writeln(
          '[${item.timestamp}] ${item.speaker}: ${item.claim} '
          '(${verdictStyle(item.verdict).label})',
        );
      }
    }

    return buffer.toString();
  }

  Future<void> _startListening() async {
    if (!_sessionRunning || !_speechAvailable || _speechToText.isListening) {
      return;
    }

    try {
      await _speechToText.listen(
        onResult: _handleSpeechResult,
        onSoundLevelChange: _handleSoundLevel,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(minutes: 1),
          pauseFor: const Duration(seconds: 4),
          autoPunctuation: true,
        ),
      );
    } catch (error) {
      _statusMessage = 'Listening failed: $error';
      _scheduleRestart();
    }
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final words = result.recognizedWords.trim();
    if (words.isEmpty) {
      return;
    }

    _partialTranscript = words;

    if (result.finalResult) {
      _commitTranscript(words);
      _partialTranscript = '';
    }

    notifyListeners();
  }

  void _commitTranscript(String text) {
    final cleaned = _cleanTranscript(text);
    if (cleaned.isEmpty || cleaned == _lastCommittedText) {
      return;
    }

    _lastCommittedText = cleaned;
    final timestamp = formatDuration(_sessionClock.elapsed);
    final checkable = isCheckableClaim(cleaned);

    _transcript.add(
      TranscriptLine(
        speaker: 'Live mic',
        timestamp: timestamp,
        text: cleaned,
        isClaim: checkable,
      ),
    );

    if (checkable) {
      _checks.insert(
        0,
        FactCheckItem(
          id: 'claim-${_nextClaimId++}',
          speaker: 'Live mic',
          timestamp: timestamp,
          claim: cleaned,
          verdict: Verdict.checking,
          source: 'Queued for source-backed fact-checking',
        ),
      );
    }
  }

  void _handleSoundLevel(double level) {
    if (level.isNaN || level.isInfinite) {
      return;
    }

    _rawMinLevel = level < _rawMinLevel ? level : _rawMinLevel;
    _rawMaxLevel = level > _rawMaxLevel ? level : _rawMaxLevel;
    final spread = _rawMaxLevel - _rawMinLevel;

    if (spread <= 0.5) {
      _soundLevel = level > 0 ? 0.25 : 0;
    } else {
      _soundLevel = ((level - _rawMinLevel) / spread).clamp(0, 1).toDouble();
    }

    notifyListeners();
  }

  void _handleSpeechStatus(String status) {
    if (status == 'listening') {
      _statusMessage = 'Listening. Speak normally.';
    } else if (status == 'done' || status == 'notListening') {
      if (_sessionRunning && !_userStopped) {
        _statusMessage = 'Restarting listener after platform timeout';
        _scheduleRestart();
      } else if (!_sessionRunning) {
        _statusMessage = 'Stopped';
      }
    }

    notifyListeners();
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    _statusMessage = 'Speech error: ${error.errorMsg}';

    if (error.permanent) {
      _sessionRunning = false;
      _userStopped = true;
      _meterTimer?.cancel();
    } else {
      _scheduleRestart();
    }

    notifyListeners();
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();

    if (!_sessionRunning || _userStopped) {
      return;
    }

    _restartTimer = Timer(const Duration(milliseconds: 450), () {
      if (_sessionRunning && !_userStopped) {
        unawaited(_startListening());
      }
    });
  }

  void _startMeter() {
    _meterTimer?.cancel();
    _lastMeterTick = DateTime.now();
    _meterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = DateTime.now();
      final previous = _lastMeterTick ?? now;
      final delta = now.difference(previous);
      _lastMeterTick = now;

      if (_sessionRunning && _soundLevel > 0.14) {
        _speechTime += delta;
      }

      notifyListeners();
    });
  }

  String _cleanTranscript(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) {
      return compact;
    }

    return compact[0].toUpperCase() + compact.substring(1);
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _meterTimer?.cancel();
    unawaited(_speechToText.cancel());
    super.dispose();
  }
}

class SpeakerStats {
  const SpeakerStats({
    required this.name,
    required this.role,
    required this.color,
    required this.talkTime,
    required this.interruptions,
    required this.volumeLevel,
    required this.isSpeaking,
  });

  final String name;
  final String role;
  final Color color;
  final Duration talkTime;
  final int interruptions;
  final double volumeLevel;
  final bool isSpeaking;
}

class TranscriptLine {
  const TranscriptLine({
    required this.speaker,
    required this.timestamp,
    required this.text,
    required this.isClaim,
  });

  final String speaker;
  final String timestamp;
  final String text;
  final bool isClaim;
}

enum Verdict { supported, disputed, unclear, checking }

class FactCheckItem {
  const FactCheckItem({
    required this.id,
    required this.speaker,
    required this.timestamp,
    required this.claim,
    required this.verdict,
    required this.source,
  });

  final String id;
  final String speaker;
  final String timestamp;
  final String claim;
  final Verdict verdict;
  final String source;
}

class SessionHomeScreen extends StatefulWidget {
  const SessionHomeScreen({super.key});

  @override
  State<SessionHomeScreen> createState() => _SessionHomeScreenState();
}

class _SessionHomeScreenState extends State<SessionHomeScreen> {
  late final LiveSessionController _controller;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = LiveSessionController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pages = [
          SessionDashboard(controller: _controller),
          FactCheckFeed(checks: _controller.checks),
          SessionSummary(controller: _controller),
        ];

        return Scaffold(
          appBar: AppBar(
            title: const Text('Argument Referee'),
            centerTitle: false,
            actions: [
              IconButton(
                tooltip: 'Export session',
                onPressed:
                    _controller.transcript.isEmpty
                        ? null
                        : () => unawaited(_copySession(context)),
                icon: const Icon(Icons.ios_share_rounded),
              ),
              IconButton(
                tooltip: 'Reset session',
                onPressed: () => unawaited(_controller.resetSession()),
                icon: const Icon(Icons.restart_alt_rounded),
              ),
            ],
          ),
          body: SafeArea(child: pages[_selectedIndex]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedIndex = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.speed_rounded),
                label: 'Live',
              ),
              NavigationDestination(
                icon: Icon(Icons.fact_check_rounded),
                label: 'Checks',
              ),
              NavigationDestination(
                icon: Icon(Icons.summarize_rounded),
                label: 'Recap',
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copySession(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _controller.exportText()));

    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Session copied to clipboard')),
    );
  }
}

class SessionDashboard extends StatelessWidget {
  const SessionDashboard({super.key, required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 820;

        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 6,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: _scoreboardWidgets(),
                ),
              ),
              Expanded(
                flex: 5,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: _conversationWidgets(),
                ),
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            ..._scoreboardWidgets(),
            const SizedBox(height: 16),
            ..._conversationWidgets(),
          ],
        );
      },
    );
  }

  List<Widget> _scoreboardWidgets() {
    return [
      SessionHeader(controller: controller),
      const SizedBox(height: 16),
      MetricsStrip(
        totalTalkTime: controller.totalTalkTime,
        checkCount: controller.claimCount,
        elapsed: controller.elapsed,
      ),
      const SizedBox(height: 16),
      SpeakerScoreboard(
        speakers: controller.speakers,
        totalTalkTime: controller.totalTalkTime,
      ),
      const SizedBox(height: 16),
      AudioSignalPanel(controller: controller),
    ];
  }

  List<Widget> _conversationWidgets() {
    return [
      LiveTranscript(
        lines: controller.transcript,
        partialTranscript: controller.partialTranscript,
      ),
      const SizedBox(height: 16),
      FactCheckFeed(checks: controller.checks, compact: true),
    ];
  }
}

class SessionHeader extends StatelessWidget {
  const SessionHeader({super.key, required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = controller.sessionRunning;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFECE5D8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD8CEBD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPill(
                active: active,
                initializing: controller.initializing,
                unavailable:
                    controller.speechInitialized && !controller.speechAvailable,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => unawaited(controller.toggleSession()),
                icon: Icon(active ? Icons.stop_rounded : Icons.mic_rounded),
                label: Text(active ? 'Stop' : 'Start'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Live conversation',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF1D282A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            controller.statusMessage,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF526062),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: controller.soundLevel,
              color:
                  controller.soundLevel > 0.72
                      ? const Color(0xFFC6542F)
                      : const Color(0xFF16636F),
              backgroundColor: const Color(0xFFD8CEBD),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.active,
    required this.initializing,
    required this.unavailable,
  });

  final bool active;
  final bool initializing;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final status = _status();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: status.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 16, color: status.foreground),
          const SizedBox(width: 6),
          Text(
            status.label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: status.foreground,
            ),
          ),
        ],
      ),
    );
  }

  _StatusVisual _status() {
    if (unavailable) {
      return const _StatusVisual(
        label: 'Unavailable',
        icon: Icons.mic_off_rounded,
        foreground: Color(0xFFAC3F2F),
        background: Color(0xFFFFE8E1),
      );
    }

    if (initializing) {
      return const _StatusVisual(
        label: 'Starting',
        icon: Icons.hourglass_top_rounded,
        foreground: Color(0xFF7A5A11),
        background: Color(0xFFFFF8E6),
      );
    }

    if (active) {
      return const _StatusVisual(
        label: 'Listening',
        icon: Icons.mic_rounded,
        foreground: Color(0xFF1F6F3F),
        background: Color(0xFFDFF3E3),
      );
    }

    return const _StatusVisual(
      label: 'Ready',
      icon: Icons.mic_none_rounded,
      foreground: Color(0xFF16636F),
      background: Color(0xFFEAF6F7),
    );
  }
}

class _StatusVisual {
  const _StatusVisual({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;
}

class MetricsStrip extends StatelessWidget {
  const MetricsStrip({
    super.key,
    required this.totalTalkTime,
    required this.checkCount,
    required this.elapsed,
  });

  final Duration totalTalkTime;
  final int checkCount;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: MetricTile(
            icon: Icons.timer_rounded,
            label: 'Speech time',
            value: formatDuration(totalTalkTime),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
            icon: Icons.av_timer_rounded,
            label: 'Elapsed',
            value: formatDuration(elapsed),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
            icon: Icons.travel_explore_rounded,
            label: 'Claims',
            value: '$checkCount',
          ),
        ),
      ],
    );
  }
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 94),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0D8CC)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF16636F), size: 22),
          const SizedBox(height: 18),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: const Color(0xFF1D282A),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: const Color(0xFF637174),
            ),
          ),
        ],
      ),
    );
  }
}

class SpeakerScoreboard extends StatelessWidget {
  const SpeakerScoreboard({
    super.key,
    required this.speakers,
    required this.totalTalkTime,
  });

  final List<SpeakerStats> speakers;
  final Duration totalTalkTime;

  @override
  Widget build(BuildContext context) {
    return SectionPanel(
      title: 'Speaker balance',
      trailing: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF16636F)),
      child: Column(
        children: [
          for (final speaker in speakers) ...[
            SpeakerRow(
              speaker: speaker,
              share:
                  totalTalkTime.inMilliseconds <= 0
                      ? 0
                      : speaker.talkTime.inMilliseconds /
                          totalTalkTime.inMilliseconds,
            ),
            if (speaker != speakers.last) const Divider(height: 24),
          ],
          const SizedBox(height: 12),
          const InlineNotice(
            icon: Icons.info_outline_rounded,
            text:
                'Local mode captures one microphone stream. True speaker labels and interruptions need the Deepgram/backend pipeline.',
          ),
        ],
      ),
    );
  }
}

class SpeakerRow extends StatelessWidget {
  const SpeakerRow({super.key, required this.speaker, required this.share});

  final SpeakerStats speaker;
  final double share;

  @override
  Widget build(BuildContext context) {
    final percent = (share * 100).round();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: speaker.color,
              child: Text(
                speaker.name.substring(0, 1),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    speaker.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    speaker.role,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF637174),
                    ),
                  ),
                ],
              ),
            ),
            if (speaker.isSpeaking)
              const Icon(
                Icons.record_voice_over_rounded,
                color: Color(0xFF16636F),
              ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 10,
            value: share,
            color: speaker.color,
            backgroundColor: const Color(0xFFE8E0D4),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              formatDuration(speaker.talkTime),
              style: theme.textTheme.labelLarge,
            ),
            const Spacer(),
            Icon(
              Icons.volume_up_rounded,
              size: 16,
              color:
                  speaker.volumeLevel > 0.72
                      ? const Color(0xFFC6542F)
                      : const Color(0xFF637174),
            ),
            const SizedBox(width: 4),
            Text(
              '${(speaker.volumeLevel * 100).round()}%',
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
      ],
    );
  }
}

class AudioSignalPanel extends StatelessWidget {
  const AudioSignalPanel({super.key, required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final activeValue =
        controller.sessionRunning
            ? 'Active'
            : (controller.speechInitialized && !controller.speechAvailable)
            ? 'Unavailable'
            : 'Ready';

    return SectionPanel(
      title: 'Signal monitor',
      trailing: const Icon(Icons.radar_rounded, color: Color(0xFF16636F)),
      child: Column(
        children: [
          SignalRow(
            icon: Icons.hearing_rounded,
            title: 'Voice activity',
            value: activeValue,
            severity:
                controller.sessionRunning
                    ? SignalSeverity.good
                    : SignalSeverity.neutral,
          ),
          const Divider(height: 24),
          SignalRow(
            icon: Icons.volume_up_rounded,
            title: 'Input level',
            value: '${(controller.soundLevel * 100).round()}%',
            severity:
                controller.soundLevel > 0.72
                    ? SignalSeverity.warn
                    : SignalSeverity.neutral,
          ),
          const Divider(height: 24),
          const SignalRow(
            icon: Icons.call_split_rounded,
            title: 'Interruptions',
            value: 'Backend only',
            severity: SignalSeverity.neutral,
          ),
        ],
      ),
    );
  }
}

enum SignalSeverity { good, warn, neutral }

class SignalRow extends StatelessWidget {
  const SignalRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.severity,
  });

  final IconData icon;
  final String title;
  final String value;
  final SignalSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = switch (severity) {
      SignalSeverity.good => const Color(0xFF1F6F3F),
      SignalSeverity.warn => const Color(0xFFC6542F),
      SignalSeverity.neutral => const Color(0xFF637174),
    };

    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class LiveTranscript extends StatelessWidget {
  const LiveTranscript({
    super.key,
    required this.lines,
    required this.partialTranscript,
  });

  final List<TranscriptLine> lines;
  final String partialTranscript;

  @override
  Widget build(BuildContext context) {
    return SectionPanel(
      title: 'Transcript',
      trailing: const Icon(Icons.notes_rounded, color: Color(0xFF16636F)),
      child: Column(
        children: [
          if (lines.isEmpty && partialTranscript.isEmpty)
            const EmptyState(
              icon: Icons.mic_none_rounded,
              title: 'No speech captured yet',
              detail: 'Tap Start, allow microphone access, and speak.',
            )
          else ...[
            for (final line in lines) ...[
              TranscriptTile(line: line),
              if (line != lines.last || partialTranscript.isNotEmpty)
                const Divider(height: 20),
            ],
            if (partialTranscript.isNotEmpty)
              PartialTranscriptTile(text: partialTranscript),
          ],
        ],
      ),
    );
  }
}

class TranscriptTile extends StatelessWidget {
  const TranscriptTile({super.key, required this.line});

  final TranscriptLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            line.timestamp,
            style: theme.textTheme.labelMedium?.copyWith(
              color: const Color(0xFF637174),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    line.speaker,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (line.isClaim) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.travel_explore_rounded,
                      size: 15,
                      color: Color(0xFFC6542F),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                line.text,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class PartialTranscriptTile extends StatelessWidget {
  const PartialTranscriptTile({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 52, child: Text('Live')),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF16636F),
              height: 1.35,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

class FactCheckFeed extends StatelessWidget {
  const FactCheckFeed({super.key, required this.checks, this.compact = false});

  final List<FactCheckItem> checks;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final feed = SectionPanel(
      title: 'Fact-check feed',
      trailing: const Icon(Icons.fact_check_rounded, color: Color(0xFF16636F)),
      child: Column(
        children: [
          if (checks.isEmpty)
            const EmptyState(
              icon: Icons.travel_explore_rounded,
              title: 'No checkable claims yet',
              detail:
                  'Claims with numbers, dates, or assertive phrasing appear here.',
            )
          else
            for (final check in checks) ...[
              FactCheckCard(item: check),
              if (check != checks.last) const SizedBox(height: 10),
            ],
        ],
      ),
    );

    if (compact) {
      return feed;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        feed,
        const SizedBox(height: 16),
        SectionPanel(
          title: 'Claim routing',
          trailing: const Icon(
            Icons.alt_route_rounded,
            color: Color(0xFF16636F),
          ),
          child: Column(
            children: const [
              PipelineStep(
                icon: Icons.subtitles_rounded,
                title: 'Local transcript watcher',
                detail:
                    'Flags sentences with numbers, dates, names, or firm assertions.',
              ),
              Divider(height: 24),
              PipelineStep(
                icon: Icons.queue_rounded,
                title: 'Fact-check queue',
                detail:
                    'Detected claims are queued immediately without blocking speech capture.',
              ),
              Divider(height: 24),
              PipelineStep(
                icon: Icons.cloud_sync_rounded,
                title: 'Backend verdict needed',
                detail:
                    'Connect Perplexity through a backend for source-backed verdicts.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class FactCheckCard extends StatelessWidget {
  const FactCheckCard({super.key, required this.item});

  final FactCheckItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = verdictStyle(item.verdict);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: verdict.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: verdict.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(verdict.icon, size: 18, color: verdict.foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  verdict.label,
                  style: TextStyle(
                    color: verdict.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${item.speaker} - ${item.timestamp}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF637174),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            item.claim,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.source_rounded,
                size: 16,
                color: Color(0xFF637174),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xFF637174),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SessionSummary extends StatelessWidget {
  const SessionSummary({super.key, required this.controller});

  final LiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final supported =
        controller.checks
            .where((item) => item.verdict == Verdict.supported)
            .length;
    final unresolved = controller.checks.length - supported;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SectionPanel(
          title: 'Session recap',
          trailing: const Icon(
            Icons.summarize_rounded,
            color: Color(0xFF16636F),
          ),
          child: Column(
            children: [
              SummaryRow(
                label: 'Elapsed time',
                value: formatDuration(controller.elapsed),
              ),
              const Divider(height: 24),
              SummaryRow(
                label: 'Detected speech time',
                value: formatDuration(controller.totalTalkTime),
              ),
              const Divider(height: 24),
              SummaryRow(
                label: 'Transcript lines',
                value: '${controller.transcript.length}',
              ),
              const Divider(height: 24),
              SummaryRow(
                label: 'Claims queued',
                value: '${controller.checks.length}',
              ),
              const Divider(height: 24),
              SummaryRow(label: 'Needs source verdict', value: '$unresolved'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SpeakerScoreboard(
          speakers: controller.speakers,
          totalTalkTime: controller.totalTalkTime,
        ),
      ],
    );
  }
}

class SummaryRow extends StatelessWidget {
  const SummaryRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF526062),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class PipelineStep extends StatelessWidget {
  const PipelineStep({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF16636F)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                detail,
                style: const TextStyle(color: Color(0xFF526062), height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F4EE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8E0D4)),
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFF637174)),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF637174),
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class InlineNotice extends StatelessWidget {
  const InlineNotice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF6F7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF16636F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF526062), height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionPanel extends StatelessWidget {
  const SectionPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0D8CC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F1D282A),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1D282A),
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class VerdictStyle {
  const VerdictStyle({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
    required this.border,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;
  final Color border;
}

VerdictStyle verdictStyle(Verdict verdict) {
  return switch (verdict) {
    Verdict.supported => const VerdictStyle(
      label: 'Supported',
      icon: Icons.verified_rounded,
      foreground: Color(0xFF1F6F3F),
      background: Color(0xFFF0FAF1),
      border: Color(0xFFC6E8CD),
    ),
    Verdict.disputed => const VerdictStyle(
      label: 'Disputed',
      icon: Icons.gpp_bad_rounded,
      foreground: Color(0xFFAC3F2F),
      background: Color(0xFFFFF1EC),
      border: Color(0xFFF0C4B6),
    ),
    Verdict.unclear => const VerdictStyle(
      label: 'Unclear',
      icon: Icons.help_rounded,
      foreground: Color(0xFF7A5A11),
      background: Color(0xFFFFF8E6),
      border: Color(0xFFE8D48D),
    ),
    Verdict.checking => const VerdictStyle(
      label: 'Queued',
      icon: Icons.sync_rounded,
      foreground: Color(0xFF16636F),
      background: Color(0xFFEAF6F7),
      border: Color(0xFFB7DDE1),
    ),
  };
}

String formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

bool isCheckableClaim(String text) {
  final lower = text.toLowerCase();
  final words = lower.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
  if (words.length < 5) {
    return false;
  }

  final hasNumber = RegExp(r'\b\d+(\.\d+)?%?\b').hasMatch(lower);
  final hasYear = RegExp(r'\b(19|20)\d\d\b').hasMatch(lower);
  final assertiveSignals = [
    ' is ',
    ' are ',
    ' was ',
    ' were ',
    ' will ',
    ' always ',
    ' never ',
    ' every ',
    ' because ',
    ' increased ',
    ' decreased ',
    ' caused ',
    ' less than ',
    ' more than ',
  ];

  final padded = ' $lower ';
  final assertive = assertiveSignals.any(padded.contains);
  return hasNumber || hasYear || assertive;
}
