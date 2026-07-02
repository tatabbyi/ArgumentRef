import 'package:flutter/material.dart';

import '../main.dart';
import '../models/user_profile.dart';
import '../onboarding/onboarding_flow.dart';
import '../ui/ref_theme.dart';

/// The small translucent badge pinned to the top-left corner in debug builds.
/// Tapping it opens the [DebugScreen].
class DebugOverlayButton extends StatelessWidget {
  const DebugOverlayButton({super.key});

  void _open() {
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const DebugScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: RefPalette.ink.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.bug_report_rounded,
                  size: 15,
                  color: RefPalette.cream,
                ),
                const SizedBox(width: 5),
                Text(
                  'DEBUG',
                  style: mulish(
                    size: 10,
                    weight: FontWeight.w800,
                    letterSpacing: 1,
                    color: RefPalette.cream,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A developer-only panel for exercising the onboarding flow and inspecting the
/// saved profile. Only reachable via [DebugOverlayButton] in debug builds.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  UserProfile? get _profile => appRootKey.currentState?.profile;

  /// Launches onboarding as a throwaway overlay — nothing is persisted, and it
  /// simply pops when finished. Good for a quick look.
  void _previewOnboarding() {
    final base = _profile ?? UserProfile.empty;
    final nav = Navigator.of(context);
    nav.push(
      MaterialPageRoute(
        builder: (_) => OnboardingFlow(
          initialProfile: base,
          onComplete: (_) => nav.pop(),
        ),
      ),
    );
  }

  /// Clears the "onboarding done" flag (keeping saved answers) so the real app
  /// re-enters onboarding, then closes this panel to reveal it.
  Future<void> _restartOnboarding() async {
    await appRootKey.currentState?.restartOnboarding();
    if (mounted) Navigator.of(context).pop();
  }

  /// Wipes the profile entirely and re-enters onboarding from a blank slate.
  Future<void> _wipeAndRestart() async {
    await appRootKey.currentState?.wipeProfile();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      backgroundColor: RefPalette.cream,
      appBar: AppBar(
        backgroundColor: RefPalette.cream,
        surfaceTintColor: RefPalette.cream,
        foregroundColor: RefPalette.ink,
        elevation: 0,
        title: Text(
          'Debug tools',
          style: zilla(size: 18, weight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _sectionLabel('ONBOARDING'),
            const SizedBox(height: 12),
            RefPrimaryButton(
              label: 'Preview onboarding',
              onPressed: _previewOnboarding,
            ),
            const SizedBox(height: 10),
            RefPrimaryButton(
              label: 'Restart onboarding (keep data)',
              onPressed: _restartOnboarding,
            ),
            const SizedBox(height: 18),
            Center(
              child: RefTextAction(
                label: 'Wipe profile & restart',
                onPressed: _wipeAndRestart,
              ),
            ),
            const SizedBox(height: 28),
            _sectionLabel('SAVED PROFILE'),
            const SizedBox(height: 12),
            _profileCard(profile),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: mulish(
      size: 11,
      weight: FontWeight.w800,
      letterSpacing: 11 * 0.14,
      color: RefPalette.ink.withValues(alpha: 0.45),
    ),
  );

  Widget _profileCard(UserProfile? profile) {
    if (profile == null) {
      return Text(
        'No profile loaded yet.',
        style: mulish(size: 14, color: RefPalette.ink.withValues(alpha: 0.6)),
      );
    }
    final contacts = profile.contacts
        .map((c) => '${c.name} (${c.relationship})')
        .join(', ');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7F0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RefPalette.ink.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Onboarding complete', profile.onboardingComplete ? 'yes' : 'no'),
          _row('Name', profile.name.isEmpty ? '—' : profile.name),
          _row('Contacts', contacts.isEmpty ? '—' : contacts),
          _row('Watch-outs', profile.flaws.isEmpty ? '—' : profile.flaws.join(', ')),
          _row(
            'Recent names',
            profile.recentNames.isEmpty ? '—' : profile.recentNames.join(', '),
          ),
        ],
      ),
    );
  }

  Widget _row(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          key,
          style: mulish(
            size: 11,
            weight: FontWeight.w700,
            color: RefPalette.ink.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: mulish(size: 14, weight: FontWeight.w600, color: RefPalette.ink),
        ),
      ],
    ),
  );
}
