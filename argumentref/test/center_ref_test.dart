import 'dart:convert';

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
          home: Scaffold(body: CenterRefScreen(leftName: 'Ada', rightName: 'Ben')),
        ),
      );
      await tester.pump();

      // Beat 0 — caption uses the left name; read-outs seeded.
      expect(find.text('Let Ada finish'), findsOneWidget);
      expect(find.text('58/100'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

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
      expect(find.text('3'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('renders both speaker names and initials', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CenterRefScreen(leftName: 'Ada', rightName: 'Ben')),
        ),
      );
      await tester.pump();

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);

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

    testWidgets('the people step adds multiple contacts inline', (tester) async {
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
