import 'models.dart';

Map<String, dynamic> mergeBackupJson({
  required Map<String, dynamic> cloud,
  required Map<String, dynamic> local,
}) {
  final result = Map<String, dynamic>.from(cloud);
  final cloudBooks = _books(cloud['books']);
  final localBooks = _books(local['books']);
  final byId = {for (final book in cloudBooks) book.id: book};
  final usedNames = cloudBooks.map((book) => book.name).toSet();

  for (final localBook in localBooks) {
    final cloudBook = byId[localBook.id];
    if (cloudBook != null) {
      final cloudWordIds = cloudBook.words.map((word) => word.id).toSet();
      cloudBook.words.addAll(localBook.words
          .where((word) => !cloudWordIds.contains(word.id))
          .map((word) => Word.fromJson(word.toJson())));
      continue;
    }

    final copy = WordBook.fromJson(localBook.toJson());
    if (usedNames.contains(copy.name)) {
      copy.name = _deviceName(copy.name, usedNames);
    }
    usedNames.add(copy.name);
    cloudBooks.add(copy);
    byId[copy.id] = copy;
  }

  result['books'] = cloudBooks.map((book) => book.toJson()).toList();
  result['completed'] = _union(cloud['completed'], local['completed']);
  result['studyDays'] = _union(cloud['studyDays'], local['studyDays']);
  return result;
}

List<WordBook> _books(dynamic value) => (value as List<dynamic>? ?? [])
    .map((item) => WordBook.fromJson(
        Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
    .toList();

List<String> _union(dynamic cloud, dynamic local) => {
      ...(cloud as List<dynamic>? ?? []).cast<String>(),
      ...(local as List<dynamic>? ?? []).cast<String>(),
    }.toList();

String _deviceName(String name, Set<String> usedNames) {
  final base = '$name (이 기기)';
  if (!usedNames.contains(base)) return base;
  var number = 2;
  while (usedNames.contains('$base $number')) {
    number++;
  }
  return '$base $number';
}
