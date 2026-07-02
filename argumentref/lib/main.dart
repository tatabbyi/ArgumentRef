import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'center_ref/beats.dart';
import 'center_ref/referee_guide.dart';
import 'data/profile_store.dart';
import 'debug/debug_screen.dart';
import 'models/user_profile.dart';
import 'onboarding/onboarding_flow.dart';
import 'ui/ref_theme.dart';
import 'welcome/welcome_screen.dart';

/// The app's root navigator — used by the debug overlay (which lives above the
/// navigator) to push the debug screen.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Handle to the [AppRoot] state so the debug tools can restart / wipe the
/// onboarding flow from anywhere.
final GlobalKey<AppRootState> appRootKey = GlobalKey<AppRootState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Dark status-bar glyphs read well over the warm cream background.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );
  runApp(const ArgumentRefApp());
}

class ArgumentRefApp extends StatelessWidget {
  const ArgumentRefApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conversation Referee',
      debugShowCheckedModeBanner: false,
      color: RefPalette.cream,
      navigatorKey: rootNavigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: RefPalette.cream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: RefPalette.orange,
          primary: RefPalette.ink,
          surface: RefPalette.cream,
        ),
      ),
      // In debug builds only, float a small tools button in the top-left corner
      // over every screen.
      builder: (context, child) {
        return Stack(
          children: [
            Positioned.fill(child: child ?? const SizedBox.shrink()),
            if (kDebugMode)
              const Positioned(
                left: 0,
                top: 0,
                child: SafeArea(child: DebugOverlayButton()),
              ),
          ],
        );
      },
      home: AppRoot(key: appRootKey),
    );
  }
}

/// Decides — after loading any saved profile — whether to run first-time
/// onboarding or drop the user on the welcome screen. Holds the profile in
/// memory and keeps it in sync with the store.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => AppRootState();
}

class AppRootState extends State<AppRoot> {
  final _store = ProfileStore();
  UserProfile? _profile;

  /// The current in-memory profile (null while still loading). Read by the
  /// debug tools.
  UserProfile? get profile => _profile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    UserProfile profile;
    try {
      profile = await _store.load();
    } catch (error, stack) {
      // A storage/plugin failure (e.g. a missing platform plugin) must never
      // strand the user on the splash — fall back to a fresh profile so the
      // app still opens into onboarding.
      debugPrint('Profile load failed, starting fresh: $error\n$stack');
      profile = UserProfile.empty;
    }
    if (!mounted) return;
    setState(() => _profile = profile);
  }

  Future<void> _completeOnboarding(UserProfile profile) async {
    await _store.save(profile);
    if (!mounted) return;
    setState(() => _profile = profile);
  }

  void _onProfileChanged(UserProfile profile) {
    setState(() => _profile = profile);
  }

  /// DEBUG: re-run onboarding while keeping the user's saved answers.
  Future<void> restartOnboarding() async {
    final base = _profile ?? UserProfile.empty;
    final updated = base.copyWith(onboardingComplete: false);
    await _store.save(updated);
    if (!mounted) return;
    setState(() => _profile = updated);
  }

  /// DEBUG: erase everything and start onboarding from a blank slate.
  Future<void> wipeProfile() async {
    await _store.save(UserProfile.empty);
    if (!mounted) return;
    setState(() => _profile = UserProfile.empty);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    if (profile == null) return const _Splash();

    if (!profile.onboardingComplete) {
      return OnboardingFlow(
        initialProfile: profile,
        onComplete: _completeOnboarding,
      );
    }

    return WelcomeScreen(
      profile: profile,
      store: _store,
      onProfileChanged: _onProfileChanged,
    );
  }
}

/// A brief branded splash shown while the saved profile loads.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RefPalette.cream,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const RefereeGuide(
              mood: Mood.listen,
              mouth: MouthShape.neutral,
              scale: 0.7,
            ),
            const SizedBox(height: 20),
            const RefWordmark(showLiveDot: true),
            const SizedBox(height: 10),
            Text(
              'warming up…',
              style: mulish(
                size: 13,
                color: RefPalette.ink.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
