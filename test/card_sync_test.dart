import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/card_sync.dart';

void main() {
  test('keeps a field-only card operation across a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    await tracker.activateAccount('user-a');
    final operation = await tracker.enqueue(
      bookId: 'book-a',
      wordId: 42,
      before: const {
        'term': '止める',
        'reading': 'とめる',
        'meaning': '멈추다',
        'example': '',
      },
      after: const {
        'term': '止める',
        'reading': 'とめる',
        'meaning': '그만두다',
        'example': '',
      },
    );

    expect(operation, isNotNull);
    expect(operation!.fields, {'meaning': '그만두다'});
    expect(operation.before, {'meaning': '멈추다'});

    final restarted = await CardChangeTracker.load();
    await restarted.activateAccount('user-a');
    expect(restarted.pending, hasLength(1));
    expect(restarted.pending.single.id, operation.id);
    await restarted.acknowledge(restarted.pending.single);
    expect(restarted.pending, isEmpty);
  });

  test('does not acknowledge a newer edit while an older request finishes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    await tracker.activateAccount('user-a');
    final first = await tracker.enqueue(
      bookId: 'book-a', wordId: 42,
      before: const {'meaning': '첫 뜻'}, after: const {'meaning': '둘 뜻'},
    );
    await tracker.enqueue(
      bookId: 'book-a', wordId: 42,
      before: const {'meaning': '둘 뜻'}, after: const {'meaning': '셋 뜻'},
    );
    await tracker.acknowledge(first!);
    expect(tracker.pending, hasLength(1));
    expect(tracker.pending.single.fields['meaning'], '셋 뜻');
  });
}
