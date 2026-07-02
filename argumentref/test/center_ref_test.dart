import 'dart:convert';

import 'package:argumentref/audio/audio_session.dart';
import 'package:argumentref/audio/live_ref_controller.dart';
import 'package:argumentref/audio/ref_events.dart';
import 'package:argumentref/center_ref/center_ref_screen.dart';
import 'package:argumentref/main.dart';
import 'package:argumentref/models/user_profile.dart';
import 'package:argumentref/onboarding/onboarding_flow.dart';
import 'package:argumentref/ui/ref_theme.dart';
import 'package:argumentref/welcome/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loads the app and lets the async profile read resolve, without ever calling
/// pumpAndSettle (the living referee animates forever and would time out).
Future<void> _bootApp(WidgetTester tester) async {
  await tester.pumpWidget(const ArgumentRefApp());
  await tester.pump(); // splash frame
  await tester.pump(const Duration(milliseconds: 50)); // profile load resolves
}

void main() {
  setUpAll(() {
    // Keep tests offline & deterministic — use bundled fallbacks, never fetch.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('CenterRefScreen', () {
    testWidgets('beat loop advances caption and read-outs (custom names)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(leftName: 'Ada', rightName: 'Ben'),
          ),
        ),
      );
      await tester.pump();

      // Beat 0 — caption uses the left name; read-outs seeded.
      expect(find.text('Let Ada finish'), findsOneWidget);
      expect(find.text('58/100'), findsOneWidget);
      expect(find.text('Ada cut off Ben'), findsOneWidget);
      expect(find.text('Ben cut off Ada'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(2));

      // Beat 1 — still on the left speaker.
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.text('Hear Ada out'), findsOneWidget);

      // Beat 2 — right name + flow updates.
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.text('Your turn, Ben'), findsOneWidget);
      expect(find.text('52/100'), findsOneWidget);

      // Beat 3 — cut-in flagged, count rises.
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.text('One at a time'), findsOneWidget);
      expect(find.text('Ada cut off Ben'), findsOneWidget);
      expect(find.text('Ben cut off Ada'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('renders both speaker names and initials', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(leftName: 'Ada', rightName: 'Ben'),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps cut-ins and room tone tiles the same size', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(leftName: 'Ada', rightName: 'Ben'),
          ),
        ),
      );
      await tester.pump();

      final cutInsSize = tester.getSize(
        find.byKey(const ValueKey('center-ref-cut-ins-tile')),
      );
      final roomToneSize = tester.getSize(
        find.byKey(const ValueKey('center-ref-room-tone-tile')),
      );

      expect(cutInsSize, roomToneSize);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows directional cut-in counts without a total counter', (
      tester,
    ) async {
      final controller = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        session: _QuietAudioSession(),
      );
      controller.onEventForTest(
        const InterruptionDetectedEvent(
          interrupter: 'speaker_1',
          interrupterLabel: 'Ben',
          interrupted: 'speaker_0',
          interruptedLabel: 'Ada',
          interrupterText: 'No that is not fair',
          interruptedText: 'I was trying to explain this because',
          overlapMs: 450,
          gapMs: 0,
          confidence: 0.84,
          reason: 'speaker_overlap',
        ),
      );
      controller.onEventForTest(
        const InterruptionDetectedEvent(
          interrupter: 'speaker_0',
          interrupterLabel: 'Ada',
          interrupted: 'speaker_1',
          interruptedLabel: 'Ben',
          interrupterText: 'Hold on',
          interruptedText: 'The point I am making is',
          overlapMs: 390,
          gapMs: 0,
          confidence: 0.81,
          reason: 'speaker_overlap',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(
              leftName: 'Ada',
              rightName: 'Ben',
              liveController: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Ada cut off Ben'), findsOneWidget);
      expect(find.text('Ben cut off Ada'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(2));
      expect(find.text('2'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows room tone on the matching speaker chip', (tester) async {
      final controller = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        session: _QuietAudioSession(),
      );
      controller.onEventForTest(
        const RoomToneAnalyzedEvent(
          model: 'gemini-3.1-flash-lite',
          generatedAt: '2026-07-02T12:00:00Z',
          lineNumber: 1,
          sentenceIndex: 1,
          speaker: 'speaker_1',
          speakerLabel: 'Ben',
          text: 'You always do this.',
          dominantTone: RoomToneSignal.accusatory,
          trend: RoomToneTrend.escalating,
          intensity: 82,
          confidence: 0.9,
          summary: 'Direct blame',
          signals: [RoomToneSignal.accusatory],
          phrases: [
            RoomTonePhrase(
              text: 'always do this',
              signal: RoomToneSignal.accusatory,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(
              leftName: 'Ada',
              rightName: 'Ben',
              liveController: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('speaker-room-tone-Ben')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('speaker-room-tone-Ada')), findsNothing);
      expect(find.text('ACCUSATORY'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows timeout overlay until the room quiets down', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 7, 2, 12);
      final controller = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        session: _QuietAudioSession(),
        now: () => now,
      );
      controller.onEventForTest(
        const TranscriptEvent(
          isFinal: false,
          speaker: 'speaker_0',
          text: 'you are not hearing me',
        ),
      );
      controller.onEventForTest(
        const TranscriptEvent(
          isFinal: false,
          speaker: 'speaker_1',
          text: 'no, you are not hearing me',
        ),
      );
      controller.session.loudnessListenable.value = 0.9;
      now = now.add(const Duration(seconds: 7));
      controller.onEventForTest(const UnknownEvent('tick'));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(
              leftName: 'Ada',
              rightName: 'Ben',
              liveController: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('TIME OUT'), findsOneWidget);
      expect(find.text('Lower voices to stop the whistle.'), findsOneWidget);

      controller.session.loudnessListenable.value = 0.4;
      await tester.pump();

      expect(find.text('TIME OUT'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opens compromise details from a tapped card', (tester) async {
      final controller = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        session: _QuietAudioSession(),
      );
      controller.onEventForTest(
        const CompromiseSuggestedEvent(
          model: 'gemini-3.5-flash',
          generatedAt: '2026-07-02T12:00:00Z',
          transcriptLineCount: 4,
          suggestions: [
            CompromiseSuggestion(
              id: 'compromise-1',
              rank: 1,
              title: 'Two-week trial',
              summary: 'Try the plan for two weeks and review it.',
              whyItCouldWork: 'It lowers the risk for both people.',
              score: 94,
              quality: CompromiseQuality.reallyGood,
              pushLevel: CompromisePushLevel.urgent,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(
              leftName: 'Ada',
              rightName: 'Ben',
              liveController: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Two-week trial'), findsOneWidget);
      expect(find.text('It lowers the risk for both people.'), findsNothing);

      await tester.tap(find.text('Two-week trial'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('WHY IT COULD WORK'), findsOneWidget);
      expect(find.text('It lowers the risk for both people.'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('WHY IT COULD WORK'), findsNothing);
      expect(find.text('Compromises ready - tap to view'), findsOneWidget);
      expect(find.text('Two-week trial'), findsNothing);

      await tester.tap(find.text('Compromises ready - tap to view'));
      await tester.pump();

      expect(find.text('Two-week trial'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('collapses untouched compromise cards after five seconds', (
      tester,
    ) async {
      final controller = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        session: _QuietAudioSession(),
      );
      controller.onEventForTest(
        const CompromiseSuggestedEvent(
          model: 'gemini-3.5-flash',
          generatedAt: '2026-07-02T12:00:00Z',
          transcriptLineCount: 4,
          suggestions: [
            CompromiseSuggestion(
              id: 'compromise-1',
              rank: 1,
              title: 'Two-week trial',
              summary: 'Try the plan for two weeks and review it.',
              whyItCouldWork: 'It lowers the risk for both people.',
              score: 94,
              quality: CompromiseQuality.reallyGood,
              pushLevel: CompromisePushLevel.urgent,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CenterRefScreen(
              leftName: 'Ada',
              rightName: 'Ben',
              liveController: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Two-week trial'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));

      expect(find.text('Two-week trial'), findsNothing);
      expect(find.text('Compromises ready - tap to view'), findsOneWidget);

      await tester.tap(find.text('Compromises ready - tap to view'));
      await tester.pump();

      expect(find.text('Two-week trial'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('App routing', () {
    testWidgets('a fresh install lands in onboarding', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _bootApp(tester);

      expect(find.byType(OnboardingFlow), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(find.text('How this works'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a completed profile lands on the welcome screen', (
      tester,
    ) async {
      const profile = UserProfile(
        name: 'Alex',
        contacts: [Contact(name: 'Sam', relationship: 'Partner')],
        flaws: ['anger'],
        recentNames: ['Alex', 'Sam'],
        onboardingComplete: true,
      );
      SharedPreferences.setMockInitialValues({
        'user_profile_v1': jsonEncode(profile.toJson()),
      });
      await _bootApp(tester);

      expect(find.byType(WelcomeScreen), findsOneWidget);
      // The 3b "Clean & Airy" setup screen: ref greeting + big heading.
      expect(find.textContaining('signed in'), findsOneWidget);
      expect(find.textContaining('Who’s talking'), findsOneWidget);
      expect(find.text('Start session'), findsOneWidget);
      // Previously-used names are offered as quick picks.
      expect(find.text('Sam'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Debug tools', () {
    testWidgets('the debug badge opens tools and can trigger onboarding', (
      tester,
    ) async {
      const profile = UserProfile(
        name: 'Alex',
        recentNames: ['Alex'],
        onboardingComplete: true,
      );
      SharedPreferences.setMockInitialValues({
        'user_profile_v1': jsonEncode(profile.toJson()),
      });
      await _bootApp(tester);
      expect(find.byType(WelcomeScreen), findsOneWidget);

      // The badge only exists in debug builds (tests run in debug).
      expect(find.text('DEBUG'), findsOneWidget);
      await tester.tap(find.text('DEBUG'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Debug tools'), findsOneWidget);

      // Restart onboarding → the app re-enters the flow.
      await tester.tap(find.text('Restart onboarding (keep data)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(OnboardingFlow), findsOneWidget);
      expect(find.text('How this works'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Onboarding', () {
    testWidgets('the ref guides the flow and gates Continue on a name', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _bootApp(tester);

      // The living referee is guiding.
      expect(find.byType(RefPrimaryButton), findsOneWidget);

      // Intro → name step.
      await tester.tap(find.byType(RefPrimaryButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Your name'), findsOneWidget);

      // Continue is disabled with no name — tapping does nothing.
      await tester.tap(find.byType(RefPrimaryButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Your name'), findsOneWidget);

      // Enter a name, then Continue advances to the people step.
      await tester.enterText(find.byType(TextField), 'Sam');
      await tester.pump();
      await tester.tap(find.byType(RefPrimaryButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Who do you argue with?'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the people step adds multiple contacts inline', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _bootApp(tester);

      // Intro → name → people. Settle each AnimatedSwitcher transition fully so
      // the outgoing step's TextField is gone before we interact.
      await tester.tap(find.byType(RefPrimaryButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Sam');
      await tester.pump();
      await tester.tap(find.byType(RefPrimaryButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Who do you argue with?'), findsOneWidget);
      expect(find.text('0'), findsOneWidget); // count badge starts empty
      // The always-visible inline add button is present.
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);

      // Add two people (submitting the field runs the same add path).
      await tester.enterText(find.byType(TextField), 'Jordan');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Riley');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('2'), findsOneWidget); // count badge
      expect(find.text('Jordan'), findsOneWidget);
      expect(find.text('Riley'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _QuietAudioSession extends AudioSession {
  _QuietAudioSession()
    : super(sessionId: 'test-session', participantId: 'test-participant');

  @override
  Future<void> start() async {
    statusListenable.value = AudioSessionStatus.streaming;
  }

  @override
  Future<void> stop() async {
    statusListenable.value = AudioSessionStatus.ended;
  }
}
