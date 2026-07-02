import 'package:flutter/material.dart';

import '../center_ref/beats.dart';
import '../center_ref/referee_guide.dart';
import '../models/user_profile.dart';
import '../ui/ref_theme.dart';
import 'onboarding_data.dart';

/// A one-time, referee-guided onboarding for new users. The living ref sits at
/// the top and "speaks" each prompt through a speech bubble; the body below
/// collects the user's name, the people they argue with, and their own
/// argument tendencies. Every question can be skipped.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.initialProfile,
    required this.onComplete,
  });

  /// Any existing (partial) profile to prefill from.
  final UserProfile initialProfile;

  /// Called with the finished profile once the user reaches the end.
  final ValueChanged<UserProfile> onComplete;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const _stepCount = 5;

  final _nameCtrl = TextEditingController();
  final _contactNameCtrl = TextEditingController();

  int _step = 0;
  String _contactRelationship = kRelationships.first;
  late final List<Contact> _contacts;
  late final Set<String> _flaws;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.initialProfile.name;
    _nameCtrl.addListener(() => setState(() {}));
    // Keep the inline "add" button's enabled state in sync with typing.
    _contactNameCtrl.addListener(() => setState(() {}));
    _contacts = [...widget.initialProfile.contacts];
    _flaws = {...widget.initialProfile.flaws};
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contactNameCtrl.dispose();
    super.dispose();
  }

  String get _name => _nameCtrl.text.trim();

  // ── Navigation ─────────────────────────────────────────────────────────
  void _next() {
    FocusScope.of(context).unfocus();
    if (_step == _stepCount - 1) {
      _finish();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_step > 0) setState(() => _step--);
  }

  void _skipFlaws() {
    setState(_flaws.clear);
    _next();
  }

  void _finish() {
    final profile = widget.initialProfile
        .copyWith(
          name: _name,
          contacts: List.unmodifiable(_contacts),
          flaws: _flaws.toList(),
          onboardingComplete: true,
        )
        .withRecentNames([_name, ..._contacts.map((c) => c.name)]);
    widget.onComplete(profile);
  }

  // ── Contact editing ────────────────────────────────────────────────────
  void _addContact() {
    final name = _contactNameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _contacts.add(Contact(name: name, relationship: _contactRelationship));
      _contactNameCtrl.clear();
    });
  }

  void _removeContact(Contact c) => setState(() => _contacts.remove(c));

  void _toggleFlaw(String id) => setState(() {
    if (!_flaws.add(id)) _flaws.remove(id);
  });

  // ── Ref pose per step ──────────────────────────────────────────────────
  Mood get _mood => switch (_step) {
    0 => Mood.approve,
    1 => Mood.curious,
    2 => Mood.listen,
    3 => Mood.curious,
    _ => Mood.approve,
  };

  MouthShape get _mouth => switch (_step) {
    0 || 4 => MouthShape.smile,
    1 => MouthShape.o,
    _ => MouthShape.neutral,
  };

  String get _bubble => switch (_step) {
    0 =>
      'Hey — I’m your Referee. I keep things fair when talks get heated. '
          'Two minutes to set you up?',
    1 => 'First up — what should I call you?',
    2 =>
      'Who do you get into it with most? Add a few and I’ll know them by name.',
    3 =>
      'When things heat up, what do you slip into? Be honest — no judgment here.',
    _ => _name.isEmpty
        ? 'You’re all set. I’ve got your back. Let’s keep it fair.'
        : 'You’re all set, $_name. I’ve got your back. Let’s keep it fair.',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RefPalette.cream,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            RefereeGuide(mood: _mood, mouth: _mouth, scale: 0.52),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: RefSpeechBubble(text: _bubble, compact: true),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: SingleChildScrollView(
                  key: ValueKey(_step),
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
                  child: _body(),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: _step > 0
                ? IconButton(
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: RefPalette.ink,
                    iconSize: 22,
                  )
                : null,
          ),
          Expanded(
            child: RefProgressDots(count: _stepCount, index: _step),
          ),
          const SizedBox(width: 44),
        ],
      ),
    );
  }

  // ── Bodies ─────────────────────────────────────────────────────────────
  Widget _body() {
    switch (_step) {
      case 0:
        return _introBody();
      case 1:
        return _nameBody();
      case 2:
        return _peopleBody();
      case 3:
        return _flawsBody();
      default:
        return _doneBody();
    }
  }

  Widget _introBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('How this works'),
        const SizedBox(height: 14),
        _bullet('I listen while you and someone talk it out.'),
        _bullet('I track who’s holding the floor and flag cut-ins.'),
        _bullet('I never take sides — I just keep it fair.'),
      ],
    );
  }

  Widget _nameBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Your name'),
        const SizedBox(height: 14),
        RefTextField(
          controller: _nameCtrl,
          hint: 'e.g. Alex',
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (_name.isNotEmpty) _next();
          },
        ),
      ],
    );
  }

  Widget _peopleBody() {
    final canAdd = _contactNameCtrl.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Who do you argue with?'),
        const SizedBox(height: 6),
        Text(
          'Add as many as you like — type a name, pick how you know them, '
          'then tap +.',
          style: mulish(
            size: 13,
            color: RefPalette.ink.withValues(alpha: 0.55),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        // Name + an always-visible add button, side by side.
        Row(
          children: [
            Expanded(
              child: RefTextField(
                controller: _contactNameCtrl,
                hint: 'Their name',
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addContact(),
              ),
            ),
            const SizedBox(width: 10),
            _addButton(enabled: canAdd),
          ],
        ),
        const SizedBox(height: 14),
        _miniLabel('HOW YOU KNOW THEM'),
        const SizedBox(height: 9),
        // A single compact, horizontally-scrollable row of small selectors.
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kRelationships.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final r = kRelationships[i];
              return RefChip(
                label: r,
                dense: true,
                selected: _contactRelationship == r,
                accent: RefPalette.green,
                onTap: () => setState(() => _contactRelationship = r),
              );
            },
          ),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            _miniLabel('PEOPLE ADDED'),
            const SizedBox(width: 8),
            _countBadge(_contacts.length),
          ],
        ),
        const SizedBox(height: 12),
        if (_contacts.isEmpty)
          Text(
            'No one yet — add the people you talk things through with.',
            style: mulish(
              size: 13,
              color: RefPalette.ink.withValues(alpha: 0.45),
              height: 1.4,
            ),
          )
        else
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [for (final c in _contacts) _contactChip(c)],
          ),
      ],
    );
  }

  /// The inline add-contact button, sized to sit flush beside the name field.
  Widget _addButton({required bool enabled}) {
    return Material(
      color: enabled ? RefPalette.green : RefPalette.ink.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? _addContact : null,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            Icons.add_rounded,
            size: 26,
            color: enabled
                ? RefPalette.cream
                : RefPalette.ink.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }

  Widget _miniLabel(String text) => Text(
    text,
    style: mulish(
      size: 11,
      weight: FontWeight.w800,
      letterSpacing: 11 * 0.12,
      color: RefPalette.ink.withValues(alpha: 0.45),
    ),
  );

  Widget _countBadge(int count) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: count == 0
          ? RefPalette.ink.withValues(alpha: 0.08)
          : RefPalette.green.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '$count',
      style: mulish(
        size: 12,
        weight: FontWeight.w800,
        color: count == 0
            ? RefPalette.ink.withValues(alpha: 0.5)
            : RefPalette.olive,
      ),
    ),
  );

  Widget _flawsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Your watch-outs'),
        const SizedBox(height: 6),
        Text(
          'Pick any that sound like you. I’ll keep an eye out.',
          style: mulish(
            size: 13,
            color: RefPalette.ink.withValues(alpha: 0.55),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            for (final f in kFlaws)
              RefChip(
                label: f.label,
                selected: _flaws.contains(f.id),
                accent: RefPalette.red,
                onTap: () => _toggleFlaw(f.id),
              ),
          ],
        ),
      ],
    );
  }

  Widget _doneBody() {
    final line = _contacts.isEmpty && _flaws.isEmpty
        ? 'You can add people and watch-outs any time.'
        : 'I’ll remember ${_contacts.length} '
              '${_contacts.length == 1 ? 'person' : 'people'} and '
              '${_flaws.length} watch-out${_flaws.length == 1 ? '' : 's'}.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Ready when you are'),
        const SizedBox(height: 10),
        Text(
          line,
          style: mulish(
            size: 14,
            color: RefPalette.ink.withValues(alpha: 0.6),
            height: 1.5,
          ),
        ),
      ],
    );
  }

  // ── Footer ─────────────────────────────────────────────────────────────
  Widget _footer() {
    final (String primary, VoidCallback? onPrimary) = switch (_step) {
      0 => ('Let’s go', _next),
      1 => ('Continue', _name.isEmpty ? null : _next),
      2 => ('Continue', _next),
      3 => ('Continue', _next),
      _ => ('Enter the app', _next),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RefPrimaryButton(label: primary, onPressed: onPrimary),
          SizedBox(
            height: 40,
            child: Center(child: _skipAction()),
          ),
        ],
      ),
    );
  }

  Widget _skipAction() {
    switch (_step) {
      case 2:
        return RefTextAction(label: 'Skip for now', onPressed: _next);
      case 3:
        return RefTextAction(label: 'Can’t think of any', onPressed: _skipFlaws);
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Small building blocks ────────────────────────────────────────────────
  Widget _sectionTitle(String text) => Text(
    text,
    style: zilla(size: 18, weight: FontWeight.w700, color: RefPalette.ink),
  );

  Widget _bullet(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6, right: 12),
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: RefPalette.orange,
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: mulish(
              size: 14.5,
              color: RefPalette.ink.withValues(alpha: 0.75),
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _contactChip(Contact c) {
    return GestureDetector(
      onTap: () => _removeContact(c),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        decoration: BoxDecoration(
          color: RefPalette.green.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: RefPalette.green.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              c.name,
              style: mulish(
                size: 13.5,
                weight: FontWeight.w700,
                color: RefPalette.ink,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              c.relationship.toLowerCase(),
              style: mulish(
                size: 12.5,
                color: RefPalette.ink.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.close_rounded,
              size: 15,
              color: RefPalette.ink.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}
