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
  
  final mergedStudies = <String, dynamic>{};
  final cloudStudies = cloud['activeStudies'] as Map<dynamic, dynamic>? ?? const {};
  final localStudies = local['activeStudies'] as Map<dynamic, dynamic>? ?? const {};
  final allKeys = {...cloudStudies.keys, ...localStudies.keys};
  
  for (final key in allKeys) {
    final cloudVal = cloudStudies[key];
    final localVal = localStudies[key];
    if (cloudVal != null && localVal != null) {
      final timeCloud = cloudVal['updatedAt'] != null
          ? DateTime.tryParse(cloudVal['updatedAt'] as String)
          : null;
      final timeLocal = localVal['updatedAt'] != null
          ? DateTime.tryParse(localVal['updatedAt'] as String)
          : null;
      if (timeCloud != null && timeLocal != null) {
        if (timeCloud.isAfter(timeLocal)) {
          mergedStudies[key.toString()] = cloudVal;
        } else {
          mergedStudies[key.toString()] = localVal;
        }
      } else {
        final cloudQueueLen = (cloudVal['queueIds'] as List?)?.length ?? 9999;
        final localQueueLen = (localVal['queueIds'] as List?)?.length ?? 9999;
        if (cloudQueueLen <= localQueueLen) {
          mergedStudies[key.toString()] = cloudVal;
        } else {
          mergedStudies[key.toString()] = localVal;
        }
      }
    } else {
      mergedStudies[key.toString()] = cloudVal ?? localVal;
    }
  }
  result['activeStudies'] = mergedStudies;

  dynamic fallbackActive;
  DateTime? latestTime;
  mergedStudies.forEach((k, v) {
    if (v is Map) {
      final timeStr = v['updatedAt'] as String?;
      final time = timeStr == null ? null : DateTime.tryParse(timeStr);
      if (fallbackActive == null ||
          (time != null && (latestTime == null || time.isAfter(latestTime!)))) {
        fallbackActive = v;
        latestTime = time;
      }
    }
  });
  result['activeStudy'] =
      fallbackActive ?? cloud['activeStudy'] ?? local['activeStudy'];
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
