import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/pronunciation/pronunciation_match.dart';
import 'package:vocaflow/pronunciation/pronunciation_pack.dart';
import 'package:vocaflow/pronunciation/pronunciation_pack_store.dart';
import 'package:vocaflow/pronunciation/pronunciation_resolver.dart';
import 'package:vocaflow/pronunciation/pronunciation_store.dart';

class _PackStore extends PronunciationPackStore {
  _PackStore(this.packs);
  final List<InstalledPronunciationPack> packs;

  @override
  Future<List<InstalledPronunciationPack>> list() async => packs;
}

void main() {
  final entries = [
    const PronunciationPackEntry(
        term: '橋', reading: 'はし', accentPosition: 2, audioPath: 'audio/a.wav'),
    const PronunciationPackEntry(
        term: '橋', reading: 'はし', accentPosition: 1, audioPath: 'audio/b.wav'),
  ];
  final resolver = PronunciationResolver(_PackStore([
    InstalledPronunciationPack(
        'C:/pronunciation/test',
        PronunciationPackManifest(packId: 'test-pack', entries: entries)),
  ]));

  test('ambiguous pack candidates need an explicit card-local choice', () async {
    SharedPreferences.setMockInitialValues({});
    final selections = PronunciationSelectionStore();
    await selections.load();
    final reference = PronunciationCardRef.fromCard(
      bookId: 'book-a',
      wordId: 7,
      term: '橋',
      reading: 'はし',
      meaning: '다리',
    );
    final unresolved = await resolvePronunciationMatch(
      resolver: resolver,
      term: '橋',
      reading: 'はし',
      selections: selections,
      reference: reference,
    );
    expect(unresolved.requiresSelection, isTrue);
    expect(unresolved.active, isNull);

    await selections.select(reference, entries.last.candidateId);
    final resolved = await resolvePronunciationMatch(
      resolver: resolver,
      term: '橋',
      reading: 'はし',
      selections: selections,
      reference: reference,
    );
    expect(resolved.active?.entry.accentPosition, 1);
  });

  test('a selection is ignored when its card meaning changes', () async {
    SharedPreferences.setMockInitialValues({});
    final selections = PronunciationSelectionStore();
    await selections.load();
    final saved = PronunciationCardRef.fromCard(
      bookId: 'book-a', wordId: 7, term: '橋', reading: 'はし', meaning: '다리');
    await selections.select(saved, entries.first.candidateId);
    final changed = PronunciationCardRef.fromCard(
      bookId: 'book-a', wordId: 7, term: '橋', reading: 'はし', meaning: '젓가락');
    final match = await resolvePronunciationMatch(
      resolver: resolver,
      term: '橋',
      reading: 'はし',
      selections: selections,
      reference: changed,
    );
    expect(match.requiresSelection, isTrue);
    expect(match.active, isNull);
  });
}
