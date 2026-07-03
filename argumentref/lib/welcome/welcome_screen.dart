import 'package:flutter/material.dart';

import '../center_ref/referee_guide.dart';
import '../data/profile_store.dart';
import '../models/user_profile.dart';
import '../onboarding/onboarding_flow.dart';
import '../ui/ref_theme.dart';
import 'calibration_screen.dart';
import 'referee_settings_screen.dart';

/// The landing surface shown every time the app opens (once onboarding is done),
/// built to the **3b "Clean & Airy"** design direction: usability-first, no
/// metaphor. The ref greets from a small chat bubble up top; below it a big
/// friendly heading and two generous name fields set up who's talking — typed
/// fresh or tapped from previously used names — then start the live referee.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.profile,
    required this.store,
    required this.onProfileChanged,
  });

  final UserProfile profile;
  final ProfileStore store;
  final ValueChanged<UserProfile> onProfileChanged;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _aCtrl = TextEditingController();
  final _bCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Seed the first speaker with the user's own name — they're usually one of
    // the two in the room.
    _aCtrl.text = widget.profile.name;
    _aCtrl.addListener(_onChanged);
    _bCtrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _aCtrl.dispose();
    _bCtrl.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  String get _a => _aCtrl.text.trim();
  String get _b => _bCtrl.text.trim();

  bool get _canStart =>
      _a.isNotEmpty && _b.isNotEmpty && _a.toLowerCase() != _b.toLowerCase();

  bool get _sameName =>
      _a.isNotEmpty && _b.isNotEmpty && _a.toLowerCase() == _b.toLowerCase();

  void _start() {
    if (!_canStart) return;
    FocusScope.of(context).unfocus();
    final updated = widget.profile.withRecentNames([_a, _b]);
    widget.store.save(updated);
    widget.onProfileChanged(updated);
    // Calibrate each voice first, then the calibration screen hands off to the
    // live referee.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CalibrationScreen(
          leftName: _a,
          rightName: _b,
          refereeSettings: updated.refereeSettings,
        ),
      ),
    );
  }

  void _editRefereeSettings() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RefereeSettingsScreen(
          settings: widget.profile.refereeSettings,
          onChanged: (settings) {
            final updated = widget.profile.copyWith(refereeSettings: settings);
            widget.store.save(updated);
            widget.onProfileChanged(updated);
          },
        ),
      ),
    );
  }

  Future<void> _editProfile() async {
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OnboardingFlow(
          initialProfile: widget.profile,
          onComplete: (updated) {
            widget.store.save(updated);
            widget.onProfileChanged(updated);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
    if (mounted && _aCtrl.text.trim().isEmpty) {
      _aCtrl.text = widget.profile.name;
    }
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
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _speaker(
                      label: 'FIRST SPEAKER',
                      controller: _aCtrl,
                      accent: RefPalette.green,
                    ),
                    const SizedBox(height: 26),
                    _speaker(
                      label: 'SECOND SPEAKER',
                      controller: _bCtrl,
                      accent: RefPalette.orange,
                    ),
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  /// The ref, small and friendly, saying hello from a chat bubble. A quiet tune
  /// action on the right lets the user re-open onboarding to edit their profile
  /// (the 3b mock has no chrome for this, but the real app needs a way in).
  Widget _refChatRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const RefHeadBadge(size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _RefChatBubble(text: 'Let’s get you both signed in.'),
            ),
          ),
          IconButton(
            onPressed: RefHaptics.wrap(_editRefereeSettings),
            icon: const Icon(Icons.sports_rounded),
            color: RefPalette.ink.withValues(alpha: 0.55),
            iconSize: 20,
            tooltip: 'Tune your ref',
          ),
          IconButton(
            onPressed: RefHaptics.wrap(_editProfile),
            icon: const Icon(Icons.tune_rounded),
            color: RefPalette.ink.withValues(alpha: 0.55),
            iconSize: 20,
            tooltip: 'Edit your profile',
          ),
        ],
      ),
    );
  }

  Widget _heading() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Who’s talking\ntoday?',
            style: zilla(size: 30, weight: FontWeight.w700, height: 1.08),
          ),
          const SizedBox(height: 9),
          Text(
            'Add both names so the ref knows who’s who.',
            style: mulish(
              size: 14,
              color: RefPalette.ink.withValues(alpha: 0.55),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _speaker({
    required String label,
    required TextEditingController controller,
    required Color accent,
  }) {
    final value = controller.text.trim();
    final initial = value.isEmpty ? '?' : value.characters.first.toUpperCase();
    // Offer previously used names as quick fills, minus whatever the other field
    // already holds so the two can't collide.
    final other = (controller == _aCtrl ? _b : _a).toLowerCase();
    final picks = widget.profile.knownNames
        .where((n) => n.toLowerCase() != other)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Text(
                initial,
                style: zilla(
                  size: 14,
                  weight: FontWeight.w700,
                  color: RefPalette.cream,
                ),
              ),
            ),
            const SizedBox(width: 9),
            Text(
              label,
              style: mulish(
                size: 11,
                weight: FontWeight.w800,
                letterSpacing: 11 * 0.16,
                color: RefPalette.ink.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _AiryField(
          controller: controller,
          accent: accent,
          onSubmitted: (_) {
            if (_canStart) _start();
          },
        ),
        if (picks.isNotEmpty) ...[
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in picks)
                _QuickName(
                  label: n,
                  onTap: () {
                    controller.text = n;
                    controller.selection = TextSelection.collapsed(
                      offset: n.length,
                    );
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RefPrimaryButton(
            label: 'Start session',
            onPressed: _canStart ? _start : null,
            borderRadius: 18,
            fontSize: 17,
            verticalPadding: 17,
          ),
          SizedBox(
            height: 30,
            child: Center(
              child: _sameName
                  ? Text(
                      'Pick two different names',
                      style: mulish(
                        size: 13,
                        color: RefPalette.ink.withValues(alpha: 0.5),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The ref's greeting bubble — warm orange gradient with the pointer notched
/// into the bottom-left corner so it reads as coming from the head beside it.
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

/// A generous, focus-aware name input. On focus the border picks up the
/// speaker's accent, the fill brightens to white and a soft ring blooms —
/// matching the 3b `style-focus` treatment.
class _AiryField extends StatefulWidget {
  const _AiryField({
    required this.controller,
    required this.accent,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final Color accent;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_AiryField> createState() => _AiryFieldState();
}

class _AiryFieldState extends State<_AiryField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: focused ? Colors.white : const Color(0xFFFCF7EE),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: focused ? widget.accent : RefPalette.ink.withValues(alpha: 0.14),
          width: 1.5,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: widget.accent.withValues(alpha: 0.2),
                  spreadRadius: 3,
                  blurRadius: 0,
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: widget.onSubmitted,
        cursorColor: widget.accent,
        style: mulish(size: 19, weight: FontWeight.w600, color: RefPalette.ink),
        decoration: InputDecoration.collapsed(
          hintText: 'Enter a name',
          hintStyle: mulish(
            size: 19,
            color: RefPalette.ink.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

/// A soft, borderless quick-fill pill for a previously used name.
class _QuickName extends StatelessWidget {
  const _QuickName({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RefPalette.ink.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: RefHaptics.wrap(onTap, haptic: RefHaptic.selection),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: mulish(
              size: 14,
              weight: FontWeight.w600,
              color: RefPalette.ink,
            ),
          ),
        ),
      ),
    );
  }
}
