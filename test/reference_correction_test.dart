import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/reference_correction.dart';

Map<String, dynamic> card(
        {String meaning = 'old',
        int revision = 0,
        bool owned = true,
        bool deleted = false,
        bool protected = false,
        int id = 42}) =>
    {
      'bookId': 'book',
      'wordId': id,
      'fields': {'meaning': meaning},
      'fieldRevisions': {'meaning': revision},
      'deleted': deleted,
      'referenceOwnedFields': owned ? ['meaning'] : [],
      'protectedFields': protected ? ['meaning'] : [],
    };

void main() {
  Map<String, dynamic> plan(
          Map<String, dynamic> base, Map<String, dynamic> current,
          {int proposedId = 42}) =>
      planReferenceCorrections(baseline: [
        base
      ], current: [
        current
      ], proposed: [
        {
          'bookId': 'book',
          'wordId': proposedId,
          'fields': {'meaning': 'corrected'}
        }
      ]);
  test(
      'only explicitly reference-owned never-edited matching fields are candidates',
      () {
    final result = plan(card(), card());
    expect(result['eligible'], hasLength(1));
    expect(result['held'], isEmpty);
    expect(result['firestoreWrites'], 0);
    expect(result['createsOrDeletes'], 0);
  });
  test('imported custom meaning at revision0 is never assumed safe', () {
    expect(plan(card(owned: false), card())['held'].single['reason'],
        'unknown-provenance');
    expect(plan(card(protected: true), card())['held'].single['reason'],
        'protected-custom-field');
  });
  test('edited then restored-to-original text still counts as a user edit', () {
    expect(plan(card(), card(revision: 2))['held'].single['reason'],
        'previously-edited-field');
    expect(plan(card(), card(meaning: 'custom'))['held'].single['reason'],
        'current-value-diverged');
  });
  test(
      'missing and deleted cards are held, not recreated or matched by spelling',
      () {
    expect(plan(card(), card(deleted: true))['held'].single['reason'],
        'deleted-card');
    expect(plan(card(), card(), proposedId: 43)['held'].single['reason'],
        'missing-baseline-or-current');
  });
  test('duplicates, learning fields and non-string corrections fail closed',
      () {
    expect(
        () => planReferenceCorrections(
            baseline: [card(), card()], current: [], proposed: []),
        throwsFormatException);
    for (final fields in [
      {'state': 'memorized'},
      {'meaning': 7}
    ]) {
      expect(
          () => planReferenceCorrections(baseline: [
                card()
              ], current: [
                card()
              ], proposed: [
                {'bookId': 'book', 'wordId': 42, 'fields': fields}
              ]),
          throwsFormatException);
    }
  });
  test('a correction plan does not mutate its input snapshots', () {
    final original = card();
    final current = card();
    plan(original, current);
    expect(original['fields']['meaning'], 'old');
    expect(current['fieldRevisions']['meaning'], 0);
  });
}
