/// Relationship labels offered when adding a contact during onboarding.
const List<String> kRelationships = [
  'Partner',
  'Spouse',
  'Ex',
  'Friend',
  'Family',
  'Parent',
  'Sibling',
  'Colleague',
  'Boss',
  'Roommate',
  'Other',
];

/// A self-identified argument tendency the user can flag during onboarding.
///
/// [id] is the stable value stored on the profile; [label] is what the user
/// reads. Keeping them separate means we can reword copy without invalidating
/// saved profiles.
class Flaw {
  const Flaw(this.id, this.label);

  final String id;
  final String label;
}

/// The selectable "what do you slip into when things heat up?" options.
const List<Flaw> kFlaws = [
  Flaw('anger', 'I get angry fast'),
  Flaw('dismissive', 'I get dismissive'),
  Flaw('interrupt', 'I talk over people'),
  Flaw('withdraw', 'I go quiet / shut down'),
  Flaw('defensive', 'I get defensive'),
  Flaw('past', 'I drag up the past'),
  Flaw('right', 'I need to be right'),
  Flaw('loud', 'I raise my voice'),
  Flaw('sarcasm', 'I get sarcastic'),
  Flaw('personal', 'I make it personal'),
  Flaw('blame', 'I jump to blame'),
  Flaw('stonewall', 'I stonewall / walk off'),
];
