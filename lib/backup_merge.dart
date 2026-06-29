import 'models.dart';

Map<String, dynamic> mergeBackupJson({
  required Map<String, dynamic> cloud,
  required Map<String, dynamic> local,
}) {
  final result = Map<String, dynamic>.from(cloud);
  final cloudBooks = _books(cloud['books']);
  final localBooks = _books(local['books']);
  final sessionSize =
      (local['sessionSize'] as int?) ?? (cloud['sessionSize'] as int?) ?? 10;
  final resetMarkers = _mergeDateMap(
    _dateMap(cloud['resetMarkers']),
    _dateMap(local['resetMarkers']),
  );
  final byId = {for (final book in cloudBooks) book.id: book};
  final usedNames = cloudBooks.map((book) => book.name).toSet();

  for (final localBook in localBooks) {
    final cloudBook = byId[localBook.id];
    if (cloudBook != null) {
      final cloudWordsById = {
        for (var index = 0; index < cloudBook.words.length; index++)
          cloudBook.words[index].id: index
      };
      for (var index = 0; index < localBook.words.length; index++) {
        final localWord = localBook.words[index];
        final cloudIndex = cloudWordsById[localWord.id];
        if (cloudIndex == null) {
          cloudBook.words.add(Word.fromJson(localWord.toJson()));
        } else {
          cloudBook.words[cloudIndex] = _mergeWord(
            cloudBook.words[cloudIndex],
            localWord,
            bookId: cloudBook.id,
            wordIndex: cloudIndex,
            sessionSize: sessionSize,
            resetMarkers: resetMarkers,
          );
        }
      }
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
  final completedAt = _mergeDateMap(
    _dateMap(cloud['completedAt']),
    _dateMap(local['completedAt']),
  );
  final completed = _union(cloud['completed'], local['completed'])
      .where(
          (key) => !_resetAfterSessionKey(key, resetMarkers, completedAt[key]))
      .toList();
  result['completed'] = completed;
  result['completedAt'] = {
    for (final key in completed)
      if (completedAt[key] != null) key: completedAt[key]!.toIso8601String()
  };
  result['studyDays'] = _union(cloud['studyDays'], local['studyDays']);
  result['dailyStudyStats'] =
      _mergeDailyStudyStats(cloud['dailyStudyStats'], local['dailyStudyStats']);
  result['studyEventLog'] =
      _mergeStudyEventLogs(cloud['studyEventLog'], local['studyEventLog']);

  final mergedStudies = <String, dynamic>{};
  final cloudStudies =
      cloud['activeStudies'] as Map<dynamic, dynamic>? ?? const {};
  final localStudies =
      local['activeStudies'] as Map<dynamic, dynamic>? ?? const {};
  final allKeys = {...cloudStudies.keys, ...localStudies.keys};

  for (final key in allKeys) {
    final chosen = _chooseActiveStudy(
      cloudStudies[key],
      localStudies[key],
      resetMarkers,
    );
    if (chosen != null) {
      mergedStudies[key.toString()] = chosen;
    }
  }
  result['activeStudies'] = mergedStudies;
  result['resetMarkers'] = resetMarkers.map(
    (key, value) => MapEntry(key, value.toIso8601String()),
  );

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

Map<String, DateTime> _dateMap(dynamic value) =>
    (value as Map<dynamic, dynamic>? ?? const {}).map((key, raw) {
      final parsed = raw is String ? DateTime.tryParse(raw) : null;
      return MapEntry(
        key.toString(),
        parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    });

Map<String, DateTime> _mergeDateMap(
  Map<String, DateTime> left,
  Map<String, DateTime> right,
) {
  final result = <String, DateTime>{...left};
  for (final entry in right.entries) {
    final current = result[entry.key];
    if (current == null || entry.value.isAfter(current)) {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

Map<String, dynamic> _mergeDailyStudyStats(dynamic cloud, dynamic local) {
  final cloudStats = cloud as Map<dynamic, dynamic>? ?? const {};
  final localStats = local as Map<dynamic, dynamic>? ?? const {};
  final result = <String, dynamic>{};
  for (final key in {...cloudStats.keys, ...localStats.keys}) {
    final cloudValue = _statsMap(cloudStats[key]);
    final localValue = _statsMap(localStats[key]);
    result[key.toString()] = {
      'studiedCards':
          _maxInt(cloudValue['studiedCards'], localValue['studiedCards']),
      'completedSessions': _maxInt(
          cloudValue['completedSessions'], localValue['completedSessions']),
      'correctCount':
          _maxInt(cloudValue['correctCount'], localValue['correctCount']),
      'wrongCount': _maxInt(cloudValue['wrongCount'], localValue['wrongCount']),
    };
  }
  return result;
}

Map<String, dynamic> _statsMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

int _maxInt(dynamic left, dynamic right) {
  final a = (left as num?)?.toInt() ?? 0;
  final b = (right as num?)?.toInt() ?? 0;
  return a > b ? a : b;
}

List<dynamic> _mergeStudyEventLogs(dynamic cloud, dynamic local) {
  final events = <String, Map<String, dynamic>>{};
  for (final raw in [
    ...(cloud as List<dynamic>? ?? const []),
    ...(local as List<dynamic>? ?? const []),
  ]) {
    if (raw is! Map) continue;
    final event = Map<String, dynamic>.from(raw);
    final id = event['id'] as String?;
    if (id == null || id.isEmpty) continue;
    final existing = events[id];
    if (existing == null || _eventTime(event).isAfter(_eventTime(existing))) {
      events[id] = event;
    }
  }
  final referenceTime = events.values.map(_eventTime).fold<DateTime?>(null,
      (latest, time) => latest == null || time.isAfter(latest) ? time : latest);
  final cutoff =
      (referenceTime ?? DateTime.now()).subtract(const Duration(days: 90));
  final result = events.values
      .where((event) => !_eventTime(event).isBefore(cutoff))
      .toList()
    ..sort((a, b) => _eventTime(b).compareTo(_eventTime(a)));
  return result.take(3000).toList();
}

DateTime _eventTime(Map<String, dynamic> event) =>
    DateTime.tryParse(event['timestamp'] as String? ?? '') ??
    DateTime.fromMillisecondsSinceEpoch(0);

Word _mergeWord(
  Word cloud,
  Word local, {
  required String bookId,
  required int wordIndex,
  required int sessionSize,
  required Map<String, DateTime> resetMarkers,
}) {
  final lastStudiedAt = _latestDate(cloud.lastStudiedAt, local.lastStudiedAt);
  final lastWrongAt = _latestDate(cloud.lastWrongAt, local.lastWrongAt);
  final state = _higherState(cloud.state, local.state);
  final merged = cloud.copyWith(
    state: state,
    correctCount: cloud.correctCount > local.correctCount
        ? cloud.correctCount
        : local.correctCount,
    wrongCount: cloud.wrongCount > local.wrongCount
        ? cloud.wrongCount
        : local.wrongCount,
    lastStudiedAt: lastStudiedAt,
    lastWrongAt: lastWrongAt,
  );
  if (_resetAfterWord(
    bookId: bookId,
    sessionIndex: wordIndex ~/ sessionSize,
    resetMarkers: resetMarkers,
    lastStudiedAt: lastStudiedAt,
  )) {
    return merged.copyWith(
      state: StudyState.fresh,
      correctCount: 0,
      wrongCount: 0,
      clearStudyStats: true,
    );
  }
  return merged;
}

StudyState _higherState(StudyState left, StudyState right) =>
    _stateRank(left) >= _stateRank(right) ? left : right;

int _stateRank(StudyState state) => switch (state) {
      StudyState.fresh => 0,
      StudyState.review => 1,
      StudyState.memorized => 2,
    };

DateTime? _latestDate(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isAfter(right) ? left : right;
}

Map<String, dynamic>? _chooseActiveStudy(
  dynamic cloud,
  dynamic local,
  Map<String, DateTime> resetMarkers,
) {
  final cloudMap = cloud is Map ? Map<String, dynamic>.from(cloud) : null;
  final localMap = local is Map ? Map<String, dynamic>.from(local) : null;
  final candidates = [cloudMap, localMap]
      .whereType<Map<String, dynamic>>()
      .where((active) => !_resetAfterActive(active, resetMarkers))
      .toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final memorizedCompare = ((b['memorized'] as num?)?.toInt() ?? 0)
        .compareTo((a['memorized'] as num?)?.toInt() ?? 0);
    if (memorizedCompare != 0) return memorizedCompare;
    final aQueue = (a['queueIds'] as List?)?.length ?? 999999;
    final bQueue = (b['queueIds'] as List?)?.length ?? 999999;
    final queueCompare = aQueue.compareTo(bQueue);
    if (queueCompare != 0) return queueCompare;
    final aTime = _activeUpdatedAt(a);
    final bTime = _activeUpdatedAt(b);
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  });
  return candidates.first;
}

DateTime? _activeUpdatedAt(Map<String, dynamic> active) {
  final value = active['updatedAt'];
  return value is String ? DateTime.tryParse(value) : null;
}

bool _resetAfterActive(
  Map<String, dynamic> active,
  Map<String, DateTime> resetMarkers,
) {
  final updatedAt = _activeUpdatedAt(active);
  final selections = _activeSelections(active);
  if (selections.isEmpty) {
    final allReset = resetMarkers['all'];
    return allReset != null &&
        (updatedAt == null || allReset.isAfter(updatedAt));
  }
  return selections.entries.any((entry) => entry.value.any((index) {
        final reset = _latestResetForSession(entry.key, index, resetMarkers);
        return reset != null && (updatedAt == null || reset.isAfter(updatedAt));
      }));
}

Map<String, List<int>> _activeSelections(Map<String, dynamic> active) {
  final rawSelections = active['sessionSelections'];
  if (rawSelections is Map) {
    return rawSelections.map((key, value) => MapEntry(
          key.toString(),
          (value as List<dynamic>? ?? const [])
              .map((item) => (item as num).toInt())
              .toList(),
        ));
  }
  final bookId = active['bookId'] as String?;
  final indexes = (active['sessionIndexes'] as List<dynamic>? ?? const [])
      .map((item) => (item as num).toInt())
      .toList();
  return bookId == null ? const {} : {bookId: indexes};
}

bool _resetAfterSessionKey(
  String sessionKey,
  Map<String, DateTime> resetMarkers,
  DateTime? completedAt,
) {
  final parts = sessionKey.split(':');
  if (parts.length != 2) return false;
  final index = int.tryParse(parts[1]);
  if (index == null) return false;
  final reset = _latestResetForSession(parts[0], index, resetMarkers);
  return reset != null && (completedAt == null || reset.isAfter(completedAt));
}

bool _resetAfterWord({
  required String bookId,
  required int sessionIndex,
  required Map<String, DateTime> resetMarkers,
  required DateTime? lastStudiedAt,
}) {
  final reset = _latestResetForSession(bookId, sessionIndex, resetMarkers);
  return reset != null &&
      (lastStudiedAt == null || reset.isAfter(lastStudiedAt));
}

DateTime? _latestResetForSession(
  String bookId,
  int sessionIndex,
  Map<String, DateTime> resetMarkers,
) {
  DateTime? latest;
  for (final key in ['all', 'book:$bookId', 'session:$bookId:$sessionIndex']) {
    final value = resetMarkers[key];
    if (value != null && (latest == null || value.isAfter(latest))) {
      latest = value;
    }
  }
  return latest;
}

String _deviceName(String name, Set<String> usedNames) {
  final base = '$name (이 기기)';
  if (!usedNames.contains(base)) return base;
  var number = 2;
  while (usedNames.contains('$base $number')) {
    number++;
  }
  return '$base $number';
}
