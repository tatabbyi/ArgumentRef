import 'package:flutter/material.dart';

import '../center_ref/referee_guide.dart';
import '../models/referee_settings.dart';
import '../ui/ref_theme.dart';

/// Lets the user tune how the live referee behaves — the five dials the
/// backend reads off the audio socket (`parseRefereeSettingsFromUrl`): how
/// calls are worded, how sharply fallacies and shaky facts get flagged, what
/// kind of compromises get pushed, and how often the ref steps in at all.
///
/// Changes apply from the *next* session — the socket carries the settings as
/// connection parameters, so a conversation already underway keeps the tuning
/// it started with.
class RefereeSettingsScreen extends StatefulWidget {
  const RefereeSettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  /// The current tuning, usually `profile.refereeSettings`.
  final RefereeSettings settings;

  /// Fired on every change so the caller can persist immediately — backing out
  /// of the screen never loses an adjustment.
  final ValueChanged<RefereeSettings> onChanged;

  @override
  State<RefereeSettingsScreen> createState() => _RefereeSettingsScreenState();
}

class _RefereeSettingsScreenState extends State<RefereeSettingsScreen> {
  late RefereeSettings _settings = widget.settings;

  void _update(RefereeSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  bool get _isDefault => _settings == RefereeSettings.defaults;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RefPalette.cream,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _topBar(context),
            _heading(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _section<RefereeInterventionStyle>(
                      title: 'HOW THE REF SPEAKS',
                      description:
                          'The wording of a call — a soft nudge or a blunt whistle.',
                      values: RefereeInterventionStyle.values,
                      selected: _settings.interventionStyle,
                      label: (v) => switch (v) {
                        RefereeInterventionStyle.gentle => 'Gentle',
                        RefereeInterventionStyle.balanced => 'Balanced',
                        RefereeInterventionStyle.direct => 'Direct',
                      },
                      onSelect: (v) =>
                          _update(_settings.copyWith(interventionStyle: v)),
                    ),
                    _section<RefereeInterventionFrequency>(
                      title: 'HOW OFTEN IT STEPS IN',
                      description:
                          'Low keeps the ref quiet unless it really matters; '
                          'high flags more of the small stuff.',
                      values: RefereeInterventionFrequency.values,
                      selected: _settings.interventionFrequency,
                      label: (v) => switch (v) {
                        RefereeInterventionFrequency.low => 'Rarely',
                        RefereeInterventionFrequency.normal => 'Normal',
                        RefereeInterventionFrequency.high => 'Often',
                      },
                      onSelect: (v) =>
                          _update(_settings.copyWith(interventionFrequency: v)),
                    ),
                    _section<RefereeSensitivity>(
                      title: 'FALLACY CALLS',
                      description:
                          'How quickly flawed reasoning — strawmans, ad '
                          'hominems and the like — gets flagged.',
                      values: RefereeSensitivity.values,
                      selected: _settings.fallacySensitivity,
                      label: _sensitivityLabel,
                      onSelect: (v) =>
                          _update(_settings.copyWith(fallacySensitivity: v)),
                    ),
                    _section<RefereeSensitivity>(
                      title: 'FACT CHECKING',
                      description:
                          'How strictly factual claims get challenged when '
                          'they look shaky.',
                      values: RefereeSensitivity.values,
                      selected: _settings.factCheckStrictness,
                      label: _sensitivityLabel,
                      onSelect: (v) =>
                          _update(_settings.copyWith(factCheckStrictness: v)),
                    ),
                    _section<RefereeCompromisePreference>(
                      title: 'COMPROMISE STYLE',
                      description:
                          'The middle ground the ref pushes for: even trades, '
                          'whatever actually works, or whatever is most fair.',
                      values: RefereeCompromisePreference.values,
                      selected: _settings.compromisePreference,
                      label: (v) => switch (v) {
                        RefereeCompromisePreference.balanced => 'Balanced',
                        RefereeCompromisePreference.practical => 'Practical',
                        RefereeCompromisePreference.fair => 'Fair',
                      },
                      onSelect: (v) =>
                          _update(_settings.copyWith(compromisePreference: v)),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: _isDefault ? 0 : 1,
                        child: IgnorePointer(
                          ignoring: _isDefault,
                          child: RefTextAction(
                            label: 'Reset to defaults',
                            onPressed: () =>
                                _update(RefereeSettings.defaults),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sensitivityLabel(RefereeSensitivity v) => switch (v) {
    RefereeSensitivity.low => 'Relaxed',
    RefereeSensitivity.medium => 'Standard',
    RefereeSensitivity.high => 'Strict',
  };

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 22, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: RefHaptics.wrap(() => Navigator.of(context).pop()),
            icon: const Icon(Icons.arrow_back_rounded),
            color: RefPalette.ink.withValues(alpha: 0.7),
            tooltip: 'Back',
          ),
          const Spacer(),
          const RefHeadBadge(size: 46),
        ],
      ),
    );
  }

  Widget _heading() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tune your ref',
            style: zilla(size: 30, weight: FontWeight.w700, height: 1.08),
          ),
          const SizedBox(height: 9),
          Text(
            'How the ref calls the room. Changes apply from your next session.',
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

  Widget _section<T>({
    required String title,
    required String description,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onSelect,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: mulish(
              size: 11,
              weight: FontWeight.w800,
              letterSpacing: 11 * 0.16,
              color: RefPalette.ink.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: mulish(
              size: 13,
              color: RefPalette.ink.withValues(alpha: 0.55),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                RefChip(
                  label: label(value),
                  selected: value == selected,
                  onTap: () => onSelect(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
