import 'models.dart';

List<Word> parseWordsCsv(String content) {
  return parseWordImportCsv(content).words;
}

WordImportResult parseWordImportCsv(String content) {
  return parseWordImportRows(
      content.split(RegExp(r'\r?\n')).map(_parseLine).toList(growable: false));
}

List<Word> parseWordRows(List<List<String>> rows) {
  return parseWordImportRows(rows).words;
}

WordImportResult parseWordImportRows(List<List<String>> rows) {
  final headerIndex = rows.take(10).toList().indexWhere(
        (row) => _ColumnMapping.fromHeader(row) != null,
      );
  final mapping =
      headerIndex < 0 ? null : _ColumnMapping.fromHeader(rows[headerIndex]);
  final dataRows = headerIndex < 0 ? rows : rows.skip(headerIndex + 1);
  final words = <Word>[];
  final relations = <ImportedWordRelation>[];
  final cardIndexes = <(String, String, String, String, String, String), int>{};
  final relationKeys = <(int, String)>{};
  for (final columns in dataRows) {
    if (columns.length < 3) continue;
    final term = _valueAt(columns, mapping?.term ?? 0);
    if ({'term', 'word', '단어'}.contains(term.toLowerCase())) continue;
    // Headerless imports have a deliberate, fixed column order:
    // term / reading / meaning. Never remove blank cells or infer a column
    // swap from the text itself; doing either can turn a Korean meaning into a
    // pronunciation when the reading cell is blank.
    final meaning = _valueAt(columns, mapping?.meaning ?? 2);
    final rawReading = _valueAt(columns, mapping?.reading ?? 1);
    final reading = _readingOrTerm(rawReading, term);
    if (term.isEmpty || meaning.isEmpty) continue;
    final word = Word(
      term: term,
      meaning: meaning,
      reading: reading,
      example: _valueAt(columns, mapping?.example ?? 3),
      exampleMeaning: _valueAt(columns, mapping?.exampleMeaning ?? 4),
      explanation: _valueAt(columns, mapping?.explanation ?? 5),
    );
    // Preserve first occurrence order and distinct examples/explanations.
    final key = (
      term,
      reading,
      meaning,
      word.example,
      word.exampleMeaning,
      word.explanation
    );
    final sourceIndex = cardIndexes.putIfAbsent(key, () {
      words.add(word);
      return words.length - 1;
    });
    final relatedIndex = mapping?.relatedWords;
    if (relatedIndex != null) {
      for (final relatedTerm
          in _splitRelatedWords(_valueAt(columns, relatedIndex))) {
        if (!relationKeys.add((sourceIndex, relatedTerm))) continue;
        relations.add(ImportedWordRelation(
          sourceWordIndex: sourceIndex,
          targetTerm: relatedTerm,
        ));
      }
    }
  }
  return WordImportResult(words: words, relations: relations);
}

String _valueAt(List<String> columns, int index) =>
    index >= 0 && index < columns.length ? columns[index].trim() : '';

String _readingOrTerm(String rawReading, String term) {
  final reading = rawReading.trim();
  return reading.isEmpty || reading == 'ㆍ' ? term : reading;
}

class _ColumnMapping {
  const _ColumnMapping({
    required this.term,
    required this.meaning,
    required this.reading,
    required this.example,
    required this.exampleMeaning,
    required this.explanation,
    required this.relatedWords,
  });

  final int term;
  final int meaning;
  final int reading;
  final int example;
  final int exampleMeaning;
  final int explanation;
  final int? relatedWords;

  static _ColumnMapping? fromHeader(List<String> columns) {
    final normalized = columns.map(_normalizeHeader).toList();
    final term = _find(normalized, const {'term', 'word', '단어', '한자'});
    final meaning = _find(normalized, const {'meaning', '뜻', '의미', '해석'});
    final reading = _find(normalized, const {
      'reading',
      'pronunciation',
      '발음',
      '읽기',
      '요미가나',
      '후리가나',
      'furigana'
    });
    if (term < 0 || meaning < 0 || reading < 0) return null;
    return _ColumnMapping(
      term: term,
      meaning: meaning,
      reading: reading,
      example: _find(normalized, const {'example', '예문'}),
      exampleMeaning: _find(normalized,
          const {'examplemeaning', 'exampletranslation', '예문뜻', '예문해석'}),
      explanation: _find(normalized,
          const {'explanation', 'description', 'note', '설명', '설명문', '메모'}),
      relatedWords: _nullableFind(
          normalized, const {'relatedwords', 'relatedword', '관련단어', '관련'}),
    );
  }

  static int _find(List<String> columns, Set<String> candidates) =>
      columns.indexWhere(candidates.contains);

  static int? _nullableFind(List<String> columns, Set<String> candidates) {
    final index = _find(columns, candidates);
    return index < 0 ? null : index;
  }
}

String _normalizeHeader(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

List<String> _parseLine(String line) {
  final columns = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var index = 0; index < line.length; index++) {
    final character = line[index];
    if (character == '"') {
      if (quoted && index + 1 < line.length && line[index + 1] == '"') {
        current.write('"');
        index++;
      } else {
        quoted = !quoted;
      }
    } else if (character == ',' && !quoted) {
      columns.add(current.toString());
      current.clear();
    } else {
      current.write(character);
    }
  }
  columns.add(current.toString());
  return columns;
}

List<String> _splitRelatedWords(String value) => value
    .split(RegExp(r'[,;、，\n]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

class WordImportResult {
  const WordImportResult({
    required this.words,
    this.relations = const [],
  });

  final List<Word> words;
  final List<ImportedWordRelation> relations;
}

class ImportedWordRelation {
  const ImportedWordRelation({
    required this.sourceWordIndex,
    required this.targetTerm,
  });

  final int sourceWordIndex;
  final String targetTerm;
}
