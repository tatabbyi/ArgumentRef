import 'package:flutter/material.dart';

import '../center_ref/beats.dart';
import '../center_ref/center_ref_screen.dart';
import '../center_ref/referee_guide.dart';
import '../data/profile_store.dart';
import '../models/user_profile.dart';
import '../onboarding/onboarding_flow.dart';
import '../ui/ref_theme.dart';

/// The landing surface shown every time the app opens (once onboarding is done).
/// It greets the user by name and sets up a session: pick the two people
/// talking — typed fresh or tapped from previously used names — then start the
/// live referee.
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

  String get _greeting {
    final name = widget.profile.name.trim();
    return name.isEmpty ? 'Who’s talking today?' : 'Welcome back, $name.';
  }

  void _start() {
    if (!_canStart) return;
    FocusScope.of(context).unfocus();
    final updated = widget.profile.withRecentNames([_a, _b]);
    widget.store.save(updated);
    widget.onProfileChanged(updated);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: RefPalette.cream,
          body: CenterRefScreen(leftName: _a, rightName: _b),
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
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: RefereeGuide(
                        mood: Mood.approve,
                        mouth: MouthShape.smile,
                        scale: 0.66,
                      ),
                    ),
                    Center(child: RefSpeechBubble(text: _greeting)),
                    const SizedBox(height: 26),
                    Text(
                      'WHO’S TALKING?',
                      style: mulish(
                        size: 11,
                        weight: FontWeight.w800,
                        letterSpacing: 11 * 0.14,
                        color: RefPalette.ink.withValues(alpha: 0.45),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _speakerField(
                      label: 'Speaker 1',
                      controller: _aCtrl,
                      color: RefPalette.green,
                    ),
                    const SizedBox(height: 18),
                    _speakerField(
                      label: 'Speaker 2',
                      controller: _bCtrl,
                      color: RefPalette.orange,
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

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        children: [
          const RefWordmark(showLiveDot: true),
          const Spacer(),
          IconButton(
            onPressed: _editProfile,
            icon: const Icon(Icons.tune_rounded),
            color: RefPalette.ink.withValues(alpha: 0.7),
            iconSize: 22,
            tooltip: 'Edit your profile',
          ),
        ],
      ),
    );
  }

  Widget _speakerField({
    required String label,
    required TextEditingController controller,
    required Color color,
  }) {
    final value = controller.text.trim();
    final initial = value.isEmpty ? '?' : value.characters.first.toUpperCase();
    // Offer previously used names, minus whatever the other field already holds.
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
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(
                initial,
                style: zilla(
                  size: 16,
                  weight: FontWeight.w700,
                  color: RefPalette.cream,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: mulish(
                size: 12,
                weight: FontWeight.w700,
                letterSpacing: 12 * 0.08,
                color: RefPalette.ink.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RefTextField(controller: controller, hint: 'Enter a name'),
        if (picks.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in picks)
                RefChip(
                  label: n,
                  selected: value.toLowerCase() == n.toLowerCase(),
                  accent: color,
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
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RefPrimaryButton(
            label: 'Start session',
            onPressed: _canStart ? _start : null,
          ),
          SizedBox(
            height: 34,
            child: Center(
              child: !_canStart && _a.isNotEmpty && _a.toLowerCase() == _b.toLowerCase()
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
