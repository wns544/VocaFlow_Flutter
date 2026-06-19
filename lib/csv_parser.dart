import 'models.dart';

List<Word> parseWordsCsv(String content) {
  return parseWordRows(
      content.split(RegExp(r'\r?\n')).map(_parseLine).toList(growable: false));
}

List<Word> parseWordRows(List<List<String>> rows) {
  final words = <Word>[];
  for (final columns in rows) {
    if (columns.length < 3) continue;
    final term = columns[0].trim();
    if ({'term', 'word', '단어'}.contains(term.toLowerCase())) continue;
    final meaning = columns[1].trim();
    final reading = columns[2].trim();
    if (term.isEmpty || meaning.isEmpty || reading.isEmpty) continue;
    words.add(Word(
      term: term,
      meaning: meaning,
      reading: reading,
      example: columns.length > 3 ? columns[3].trim() : '',
      exampleMeaning: columns.length > 4 ? columns[4].trim() : '',
    ));
  }
  return words;
}

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
