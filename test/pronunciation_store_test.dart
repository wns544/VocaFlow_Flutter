import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/pronunciation/pronunciation_store.dart';

void main() {
  test('selection is separate, persistent, and invalidated by card changes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final ref = PronunciationCardRef.fromCard(
        bookId: 'book', wordId: 3, term: '酒', reading: 'さけ', meaning: '술');
    final store = PronunciationSelectionStore();
    await store.load();
    await store.select(ref, '酒:さけ:0');
    expect(store.forCard(ref)?.candidateId, '酒:さけ:0');

    final restored = PronunciationSelectionStore();
    await restored.load();
    expect(restored.forCard(ref)?.candidateId, '酒:さけ:0');
    final changed = PronunciationCardRef.fromCard(
        bookId: 'book', wordId: 3, term: '酒', reading: 'さけ', meaning: '연회');
    expect(restored.forCard(changed), isNull);
  });

  test('damaged local selection data does not prevent loading', () async {
    SharedPreferences.setMockInitialValues({
      'pronunciationSelections.v1': '{not valid JSON',
    });
    final store = PronunciationSelectionStore();
    await store.load();
    expect(
      store.forCard(PronunciationCardRef.fromCard(
        bookId: 'book',
        wordId: 1,
        term: '雨',
        reading: 'あめ',
        meaning: '비',
      )),
      isNull,
    );
  });

  test('transfer imports only new exact card selections', () async {
    SharedPreferences.setMockInitialValues({});
    final source = PronunciationSelectionStore();
    await source.load();
    final reference = PronunciationCardRef.fromCard(
      bookId: 'book', wordId: 3, term: '酒', reading: 'さけ', meaning: '술');
    await source.select(reference, '酒\u0000さけ\u00000');
    final transfer = source.exportTransferJson();

    SharedPreferences.setMockInitialValues({});
    final target = PronunciationSelectionStore();
    await target.load();
    expect(await target.importTransferJson(transfer), 1);
    expect(target.forCard(reference)?.candidateId, '酒\u0000さけ\u00000');

    await target.select(reference, '酒\u0000さけ\u00001');
    expect(await target.importTransferJson(transfer), 0);
    expect(target.forCard(reference)?.candidateId, '酒\u0000さけ\u00001');
  });
}
