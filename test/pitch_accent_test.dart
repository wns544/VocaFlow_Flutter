import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/pronunciation/bundled_pitch_dictionary.dart';
import 'package:vocaflow/pronunciation/kanjium_pitch_dictionary.dart';
import 'package:vocaflow/pronunciation/pitch_accent.dart';
import 'package:vocaflow/pronunciation/pitch_accent_line.dart';

void main() {
  group('normalizeJapaneseReading', () {
    test('compares katakana and hiragana without changing a card', () {
      expect(normalizeJapaneseReading('  キョウ  '), 'きょう');
      expect(normalizeJapaneseReading('ヴォイス'), 'ゔぉいす');
    });
  });

  group('splitJapaneseMorae', () {
    test('keeps contracted sounds and long marks in the correct morae', () {
      expect(splitJapaneseMorae('きょう'), ['きょ', 'う']);
      expect(splitJapaneseMorae('がっこう'), ['が', 'っ', 'こ', 'う']);
      expect(splitJapaneseMorae('ケーキ'), ['け', 'ー', 'き']);
    });

    test('does not guess for a phrase or invalid leading small kana', () {
      expect(splitJapaneseMorae('きょう は'), isNull);
      expect(splitJapaneseMorae('ゃま'), isNull);
    });
  });

  group('PitchAccentPattern', () {
    List<PitchLevel>? levelsOf(String reading, int accent) =>
        PitchAccentPattern.tryCreate(
          reading: reading,
          accentPosition: accent,
        )?.levels;

    test('models unaccented and all internal drop positions', () {
      expect(levelsOf('さけ', 0), [PitchLevel.low, PitchLevel.high]);
      expect(levelsOf('さけ', 1), [PitchLevel.high, PitchLevel.low]);
      expect(levelsOf('はし', 2), [PitchLevel.low, PitchLevel.high]);
      expect(levelsOf('あたらしい', 4), [
        PitchLevel.low,
        PitchLevel.high,
        PitchLevel.high,
        PitchLevel.high,
        PitchLevel.low,
      ]);
    });

    test('distinguishes an external drop from unaccented', () {
      final tailDrop = PitchAccentPattern.tryCreate(
        reading: 'はし',
        accentPosition: 2,
      )!;
      final unaccented = PitchAccentPattern.tryCreate(
        reading: 'さけ',
        accentPosition: 0,
      )!;
      expect(tailDrop.hasParticleOnlyDrop, isTrue);
      expect(tailDrop.internalDropAfterMora, isNull);
      expect(unaccented.isUnaccented, isTrue);
      expect(unaccented.hasParticleOnlyDrop, isFalse);
    });

    test('rejects impossible positions', () {
      expect(PitchAccentPattern.tryCreate(reading: 'はし', accentPosition: -1),
          isNull);
      expect(PitchAccentPattern.tryCreate(reading: 'はし', accentPosition: 3),
          isNull);
    });
  });

  group('KanjiumPitchDictionary', () {
    test('keeps spelling and reading together and exposes variants', () {
      final dictionary = KanjiumPitchDictionary.parse('''
酒\tさけ\t0
鮭\tさけ\t1
橋\tはし\t2,0
invalid line
''');

      expect(
          dictionary
              .lookup(term: '酒', reading: 'サケ')
              .map((candidate) => candidate.accentPosition),
          [0]);
      expect(
          dictionary
              .lookup(term: '鮭', reading: 'さけ')
              .map((candidate) => candidate.accentPosition),
          [1]);
      expect(
          dictionary
              .lookup(term: '橋', reading: 'はし')
              .map((candidate) => candidate.accentPosition),
          [2, 0]);
      expect(dictionary.lookup(term: '箸', reading: 'はし'), isEmpty);
      expect(dictionary.ignoredLineCount, 1);
    });

    test('rejects impossible positions rather than rendering a false line', () {
      final dictionary = KanjiumPitchDictionary.parse('''
酒\tさけ\t3
鮭\tさけ\t1
''');
      expect(dictionary.lookup(term: '酒', reading: 'さけ'), isEmpty);
      expect(dictionary.lookup(term: '鮭', reading: 'さけ'), hasLength(1));
      expect(dictionary.ignoredLineCount, 1);
    });
  });

  test('bundled Kanjium snapshot keeps exact spelling and reading matches',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dictionary = await BundledPitchDictionary.load();
    expect(
      dictionary
          .lookup(term: '酒', reading: 'さけ')
          .map((candidate) => candidate.accentPosition),
      [0],
    );
    expect(
      dictionary
          .lookup(term: '鮭', reading: 'さけ')
          .map((candidate) => candidate.accentPosition),
      [1],
    );
    expect(dictionary.lookup(term: '없는단어', reading: 'ない'), isEmpty);
  });

  testWidgets('pitch line labels morae and describes an internal drop',
      (tester) async {
    final pattern = PitchAccentPattern.tryCreate(
      reading: 'あたらしい',
      accentPosition: 4,
    )!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: PitchAccentLine(pattern: pattern))),
    ));

    expect(find.byKey(const ValueKey('pitch-accent-line')), findsOneWidget);
    expect(find.text('あ'), findsOneWidget);
    expect(find.text('し'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(PitchAccentLine)).label,
      '일본어 높낮이 4형, 4번째 박 뒤 낮아짐',
    );
  });
}
