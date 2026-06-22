import 'models.dart';

List<Word> parseWordsCsv(String content) {
  return parseWordRows(
      content.split(RegExp(r'\r?\n')).map(_parseLine).toList(growable: false));
}

List<Word> parseWordRows(List<List<String>> rows) {
  final headerIndex = rows.take(10).toList().indexWhere(
        (row) => _ColumnMapping.fromHeader(row) != null,
      );
  final mapping =
      headerIndex < 0 ? null : _ColumnMapping.fromHeader(rows[headerIndex]);
  final dataRows = headerIndex < 0 ? rows : rows.skip(headerIndex + 1);
  final words = <Word>[];
  for (final columns in dataRows) {
    if (columns.length < 3) continue;
    final term = _valueAt(columns, mapping?.term ?? 0);
    if ({'term', 'word', '단어'}.contains(term.toLowerCase())) continue;
    var meaning = _valueAt(columns, mapping?.meaning ?? 1);
    var reading = _valueAt(columns, mapping?.reading ?? 2);
    if (mapping == null &&
        _looksLikeReading(meaning) &&
        !_looksLikeReading(reading)) {
      final oldMeaning = meaning;
      meaning = reading;
      reading = oldMeaning;
    }
    if (term.isEmpty || meaning.isEmpty || reading.isEmpty) continue;
    words.add(Word(
      term: term,
      meaning: meaning,
      reading: reading,
      example: _valueAt(columns, mapping?.example ?? 3),
      exampleMeaning: _valueAt(columns, mapping?.exampleMeaning ?? 4),
    ));
  }
  return words;
}

String _valueAt(List<String> columns, int index) =>
    index >= 0 && index < columns.length ? columns[index].trim() : '';

bool _looksLikeReading(String value) {
  final trimmed = value.trim();
  if (RegExp(r'[\u3040-\u30ff]').hasMatch(trimmed)) return true;
  return RegExp(r'(^[/\[].*[/\]]$)|[ˈˌɐ-ʯ]').hasMatch(trimmed);
}

class _ColumnMapping {
  const _ColumnMapping({
    required this.term,
    required this.meaning,
    required this.reading,
    required this.example,
    required this.exampleMeaning,
  });

  final int term;
  final int meaning;
  final int reading;
  final int example;
  final int exampleMeaning;

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
    );
  }

  static int _find(List<String> columns, Set<String> candidates) =>
      columns.indexWhere(candidates.contains);
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
