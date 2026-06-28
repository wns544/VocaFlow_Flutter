import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_change_tracker.dart';
import 'kanji_lookup.dart';
import 'local_word_search.dart';
import 'models.dart';

class ActiveStudy {
  const ActiveStudy({
    required this.queueIds,
    this.queueBookIds = const [],
    required this.total,
    required this.memorized,
    required this.reviewed,
    required this.revealed,
    required this.sessionIndexes,
    this.bookId,
    this.lastWordId,
    this.lastState,
    this.undoHistory = const [],
    this.sessionSelections = const {},
    this.lastWordBookId,
    this.updatedAt,
  });

  final List<int> queueIds;
  final List<String> queueBookIds;
  final int total;
  final int memorized;
  final List<String> reviewed;
  final bool revealed;
  final String? bookId;
  final List<int> sessionIndexes;
  final int? lastWordId;
  final StudyState? lastState;
  final List<StudyDecision> undoHistory;
  final Map<String, List<int>> sessionSelections;
  final String? lastWordBookId;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
        'queueIds': queueIds,
        'queueBookIds': queueBookIds,
        'total': total,
        'memorized': memorized,
        'reviewed': reviewed,
        'revealed': revealed,
        'bookId': bookId,
        'sessionIndexes': sessionIndexes,
        'lastWordId': lastWordId,
        'lastState': lastState?.name,
        'undoHistory': undoHistory.map((item) => item.toJson()).toList(),
        'sessionSelections': sessionSelections,
        'lastWordBookId': lastWordBookId,
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  factory ActiveStudy.fromJson(Map<String, dynamic> json) => ActiveStudy(
        queueIds: (json['queueIds'] as List<dynamic>? ?? []).cast<int>(),
        queueBookIds:
            (json['queueBookIds'] as List<dynamic>? ?? []).cast<String>(),
        total: json['total'] as int? ?? 0,
        memorized: json['memorized'] as int? ?? 0,
        reviewed: (json['reviewed'] as List<dynamic>? ?? []).cast<String>(),
        revealed: json['revealed'] as bool? ?? false,
        bookId: json['bookId'] as String?,
        sessionIndexes:
            (json['sessionIndexes'] as List<dynamic>? ?? []).cast<int>(),
        lastWordId: json['lastWordId'] as int?,
        lastState: StudyState.values
            .where((state) => state.name == json['lastState'])
            .firstOrNull,
        undoHistory: (json['undoHistory'] as List<dynamic>? ?? [])
            .map((item) => StudyDecision.fromJson(item as Map<String, dynamic>))
            .toList(),
        sessionSelections:
            (json['sessionSelections'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(
            key,
            (value as List<dynamic>)
                .map((item) => (item as num).toInt())
                .toList(),
          ),
        ),
        lastWordBookId: json['lastWordBookId'] as String?,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.tryParse(json['updatedAt'] as String),
      );
}

class StudyDecision {
  const StudyDecision({
    required this.wordId,
    required this.previousState,
    required this.decision,
    this.bookId,
  });

  final int wordId;
  final StudyState previousState;
  final StudyState decision;
  final String? bookId;

  Map<String, dynamic> toJson() => {
        'wordId': wordId,
        'previousState': previousState.name,
        'decision': decision.name,
        'bookId': bookId,
      };

  factory StudyDecision.fromJson(Map<String, dynamic> json) => StudyDecision(
        wordId: json['wordId'] as int,
        previousState: StudyState.values.firstWhere(
          (state) => state.name == json['previousState'],
          orElse: () => StudyState.fresh,
        ),
        decision: StudyState.values.firstWhere(
          (state) => state.name == json['decision'],
          orElse: () => StudyState.fresh,
        ),
        bookId: json['bookId'] as String?,
      );
}

class VocaStore {
  VocaStore._(this._prefs);

  static const _booksKey = 'books';
  static const _quickBookKey = 'quickBook';
  static const _sessionSizeKey = 'sessionSize';
  static const _completedKey = 'completed';
  static const _studyDaysKey = 'studyDays';
  static const _targetNameKey = 'targetName';
  static const _targetDateKey = 'targetDate';
  static const _horizontalSwipeKey = 'horizontalSwipe';
  static const _reverseSwipeKey = 'reverseSwipe';
  static const _readingAboveTermKey = 'readingAboveTerm';
  static const _showExamplesKey = 'showExamples';
  static const _flipCardKey = 'flipCard';
  static const _activeStudyKey = 'activeStudy';
  static const _lastMainTabKey = 'lastMainTab';
  static const _japaneseFontKey = 'japaneseFont';
  static const _termFontSizeKey = 'termFontSize';
  static const _readingFontSizeKey = 'readingFontSize';
  static const _meaningFontSizeKey = 'meaningFontSize';
  static const _meaningFontWeightKey = 'meaningFontWeight';
  static const _meaningOpacityKey = 'meaningOpacity';
  static const _exampleFontSizeKey = 'exampleFontSize';
  static const _exampleMeaningFontSizeKey = 'exampleMeaningFontSize';
  static const _chatGptConversationUrlKey = 'chatGptConversationUrl';
  static const _readingMeaningMigrationKey = 'readingMeaningMigrationV1';

  final SharedPreferences _prefs;
  late List<WordBook> books;
  late CloudChangeTracker cloudChanges;
  late LocalWordSearchIndex wordSearch;
  void Function()? onSessionCompleted;

  static Future<VocaStore> load() async {
    final store = VocaStore._(await SharedPreferences.getInstance());
    store.books = store._loadBooks();
    store.cloudChanges = await CloudChangeTracker.load();
    store.wordSearch = LocalWordSearchIndex(() => store.books);
    await store._repairSwappedJapaneseFields();
    return store;
  }

  WordBook get quickBook {
    final id = _prefs.getString(_quickBookKey) ?? 'default';
    return books.firstWhere((book) => book.id == id, orElse: () => books.first);
  }

  int get sessionSize => _prefs.getInt(_sessionSizeKey) ?? 10;
  int get lastMainTab => (_prefs.getInt(_lastMainTabKey) ?? 0).clamp(0, 2);
  bool get horizontalSwipe => _prefs.getBool(_horizontalSwipeKey) ?? false;
  bool get reverseSwipe => _prefs.getBool(_reverseSwipeKey) ?? false;
  bool get readingAboveTerm => _prefs.getBool(_readingAboveTermKey) ?? false;
  bool get showExamples => _prefs.getBool(_showExamplesKey) ?? true;
  bool get flipCard => _prefs.getBool(_flipCardKey) ?? false;
  String get japaneseFont => _prefs.getString(_japaneseFontKey) ?? 'system';
  double get termFontSize => _prefs.getDouble(_termFontSizeKey) ?? 32;
  double get readingFontSize => _prefs.getDouble(_readingFontSizeKey) ?? 14;
  double get meaningFontSize => _prefs.getDouble(_meaningFontSizeKey) ?? 22;
  int get meaningFontWeight => _prefs.getInt(_meaningFontWeightKey) ?? 500;
  double get meaningOpacity => _prefs.getDouble(_meaningOpacityKey) ?? .70;
  double get exampleFontSize => _prefs.getDouble(_exampleFontSizeKey) ?? 16;
  double get exampleMeaningFontSize =>
      _prefs.getDouble(_exampleMeaningFontSizeKey) ?? 14;
  String get chatGptConversationUrl =>
      _prefs.getString(_chatGptConversationUrlKey) ?? '';
  String get targetName => _prefs.getString(_targetNameKey) ?? '';
  DateTime? get targetDate {
    final value = _prefs.getString(_targetDateKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  static const _activeStudiesKey = 'activeStudies';

  Map<String, ActiveStudy> get activeStudies {
    final saved = _prefs.getString(_activeStudiesKey);
    if (saved == null) {
      final oldActive = _loadOldActiveStudy();
      if (oldActive != null) {
        final key = activeStudyKeyFor(
          bookId: oldActive.bookId,
          sessionIndexes: oldActive.sessionIndexes,
          sessionSelections: oldActive.sessionSelections,
        );
        return {key: oldActive};
      }
      return const {};
    }
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return decoded.map((key, value) {
        return MapEntry(
          key,
          ActiveStudy.fromJson(value as Map<String, dynamic>),
        );
      });
    } catch (_) {
      return const {};
    }
  }

  ActiveStudy? _loadOldActiveStudy() {
    final saved = _prefs.getString(_activeStudyKey);
    if (saved == null) return null;
    try {
      final active =
          ActiveStudy.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      return active.queueIds.isEmpty ? null : active;
    } catch (_) {
      return null;
    }
  }

  String activeStudyKeyFor({
    required String? bookId,
    required List<int> sessionIndexes,
    required Map<String, List<int>> sessionSelections,
  }) {
    if (sessionSelections.isNotEmpty) {
      final sortedKeys = sessionSelections.keys.toList()..sort();
      final parts = sortedKeys.map((k) {
        final vals = List<int>.from(sessionSelections[k]!)..sort();
        return '$k:$vals';
      });
      return parts.join(';');
    }
    final sortedIdx = sessionIndexes.toList()..sort();
    return '${bookId ?? "unknown"}:$sortedIdx';
  }

  ActiveStudy? getActiveStudyFor(String key) {
    final active = activeStudies[key];
    if (active == null || isActiveStudyCompleted(active)) return null;
    return active;
  }

  ActiveStudy? getActiveStudyForSession(String bookId, int sessionIndex) {
    final exactKey = activeStudyKeyFor(
      bookId: bookId,
      sessionIndexes: [sessionIndex],
      sessionSelections: const {},
    );
    final exact = getActiveStudyFor(exactKey);
    if (exact != null) return exact;

    ActiveStudy? latest;
    for (final active in activeStudies.values) {
      if (isActiveStudyCompleted(active)) continue;
      final selections = active.sessionSelections.isNotEmpty
          ? active.sessionSelections
          : active.bookId == null
              ? const <String, List<int>>{}
              : {active.bookId!: active.sessionIndexes};
      if (!(selections[bookId]?.contains(sessionIndex) ?? false)) continue;
      if (latest == null ||
          (active.updatedAt != null &&
              (latest.updatedAt == null ||
                  active.updatedAt!.isAfter(latest.updatedAt!)))) {
        latest = active;
      }
    }
    return latest;
  }

  Future<void> saveActiveStudyFor(String key, ActiveStudy active,
      {bool markCloudChange = true}) async {
    final studies = Map<String, ActiveStudy>.from(activeStudies);
    final updatedActive = ActiveStudy(
      queueIds: active.queueIds,
      queueBookIds: active.queueBookIds,
      total: active.total,
      memorized: active.memorized,
      reviewed: active.reviewed,
      revealed: active.revealed,
      sessionIndexes: active.sessionIndexes,
      bookId: active.bookId,
      lastWordId: active.lastWordId,
      lastState: active.lastState,
      undoHistory: active.undoHistory,
      sessionSelections: active.sessionSelections,
      lastWordBookId: active.lastWordBookId,
      updatedAt: DateTime.now(),
    );
    studies[key] = updatedActive;
    if (studies.length > 20) {
      final sortedKeys = studies.keys.toList()
        ..sort((a, b) {
          final timeA =
              studies[a]?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeB =
              studies[b]?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeA.compareTo(timeB);
        });
      while (studies.length > 20) {
        studies.remove(sortedKeys.removeAt(0));
      }
    }
    await _prefs.setString(
      _activeStudiesKey,
      jsonEncode(studies.map((k, v) => MapEntry(k, v.toJson()))),
    );
    if (markCloudChange) await cloudChanges.markProfile();
  }

  Future<void> clearActiveStudyFor(String key,
      {bool markCloudChange = true}) async {
    final studies = Map<String, ActiveStudy>.from(activeStudies);
    if (studies.containsKey(key)) {
      studies.remove(key);
      await _prefs.setString(
        _activeStudiesKey,
        jsonEncode(studies.map((k, v) => MapEntry(k, v.toJson()))),
      );
      if (markCloudChange) await cloudChanges.markProfile();
    }
  }

  Future<void> clearAllActiveStudies({bool markCloudChange = true}) async {
    await _prefs.remove(_activeStudiesKey);
    await _prefs.remove(_activeStudyKey);
    if (markCloudChange) await cloudChanges.markProfile();
  }

  ActiveStudy? get activeStudy {
    final studies = activeStudies;
    if (studies.isEmpty) return null;
    ActiveStudy? latest;
    for (final active in studies.values) {
      if (isActiveStudyCompleted(active)) continue;
      if (latest == null ||
          (active.updatedAt != null &&
              (latest.updatedAt == null ||
                  active.updatedAt!.isAfter(latest.updatedAt!)))) {
        latest = active;
      }
    }
    return latest;
  }

  bool isActiveStudyCompleted(ActiveStudy active,
      {Set<String>? completedOverride}) {
    final selections = active.sessionSelections.isNotEmpty
        ? active.sessionSelections
        : active.bookId == null || active.sessionIndexes.isEmpty
            ? const <String, List<int>>{}
            : {active.bookId!: active.sessionIndexes};
    if (selections.isEmpty) return false;
    final completed = completedOverride ??
        (_prefs.getStringList(_completedKey) ?? []).toSet();
    return selections.entries.every((entry) =>
        entry.value.isNotEmpty &&
        entry.value
            .every((index) => completed.contains('${entry.key}:$index')));
  }

  List<Word> resolveActiveWords(ActiveStudy active) {
    if (active.queueBookIds.length == active.queueIds.length) {
      return List.generate(active.queueIds.length, (index) {
        final bookId = active.queueBookIds[index];
        final wordId = active.queueIds[index];
        return books
            .where((book) => book.id == bookId)
            .expand((book) => book.words)
            .where((word) => word.id == wordId)
            .firstOrNull;
      }).whereType<Word>().toList();
    }
    final preferredBook = active.bookId == null
        ? null
        : books.where((book) => book.id == active.bookId).firstOrNull;
    final candidates = [
      if (preferredBook != null) ...preferredBook.words,
      for (final book in books)
        if (book.id != preferredBook?.id) ...book.words,
    ];
    final byId = {for (final word in candidates) word.id: word};
    return active.queueIds.map((id) => byId[id]).whereType<Word>().toList();
  }

  Future<void> saveActiveStudy(ActiveStudy active,
      {bool markCloudChange = true}) async {
    final key = activeStudyKeyFor(
      bookId: active.bookId,
      sessionIndexes: active.sessionIndexes,
      sessionSelections: active.sessionSelections,
    );
    await saveActiveStudyFor(key, active, markCloudChange: markCloudChange);
  }

  Future<void> clearActiveStudy({bool markCloudChange = true}) async {
    final current = activeStudy;
    if (current != null) {
      final key = activeStudyKeyFor(
        bookId: current.bookId,
        sessionIndexes: current.sessionIndexes,
        sessionSelections: current.sessionSelections,
      );
      await clearActiveStudyFor(key, markCloudChange: markCloudChange);
    }
  }

  Future<ActiveStudy?> restoreActiveStudyFromBackupJson(
      Map<String, dynamic> json) async {
    final backupCompleted = (json['completed'] as List<dynamic>? ?? const [])
        .cast<String>()
        .toSet();
    if (json.containsKey('activeStudies')) {
      final studiesData =
          json['activeStudies'] as Map<String, dynamic>? ?? const {};
      final studies = Map<String, ActiveStudy>.from(activeStudies);
      studiesData.forEach((k, v) {
        final active = _activeStudyFromBackupJson(v);
        if (active != null &&
            !isActiveStudyCompleted(active,
                completedOverride: backupCompleted) &&
            resolveActiveWords(active).length == active.queueIds.length) {
          studies[k] = active;
        }
      });
      await _prefs.setString(
        _activeStudiesKey,
        jsonEncode(studies.map((k, v) => MapEntry(k, v.toJson()))),
      );
      return activeStudy;
    }
    final active = _activeStudyFromBackupJson(json['activeStudy']);
    if (active == null ||
        isActiveStudyCompleted(active, completedOverride: backupCompleted) ||
        resolveActiveWords(active).length != active.queueIds.length) {
      return null;
    }
    await saveActiveStudy(active, markCloudChange: false);
    return active;
  }

  Future<void> setLastMainTab(int index) =>
      _prefs.setInt(_lastMainTabKey, index.clamp(0, 2));

  int get streak {
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet();
    var cursor = DateTime.now();
    var count = 0;
    while (days.contains(_dayKey(cursor))) {
      count++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return count;
  }

  int get dDay {
    final target = targetDate;
    if (target == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(target.year, target.month, target.day)
        .difference(today)
        .inDays;
  }

  int sessionCount(WordBook book) => book.sessions(sessionSize).length;

  int completedCount(WordBook book) {
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    return List.generate(sessionCount(book), (index) => '${book.id}:$index')
        .where(completed.contains)
        .length;
  }

  bool isSessionCompleted(String bookId, int sessionIndex) {
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    return completed.contains('$bookId:$sessionIndex');
  }

  int nextSessionIndex(WordBook book) {
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    for (var index = 0; index < sessionCount(book); index++) {
      if (!completed.contains('${book.id}:$index')) return index;
    }
    return 0;
  }

  List<Word> nextWords() {
    final book = quickBook;
    final sessions = book.sessions(sessionSize);
    if (sessions.isEmpty) return [];
    return List.of(sessions[nextSessionIndex(book)].words);
  }

  Future<void> selectQuickBook(String id) async {
    await _prefs.setString(_quickBookKey, id);
    await cloudChanges.markProfile();
  }

  Future<void> setSessionSize(int value) async {
    await _prefs.setInt(_sessionSizeKey, value.clamp(5, 100).toInt());
    await _prefs.remove(_completedKey);
    await clearActiveStudy();
    await cloudChanges.markProfile();
  }

  Future<void> setHorizontalSwipe(bool value) async {
    await _prefs.setBool(_horizontalSwipeKey, value);
    await cloudChanges.markProfile();
  }

  Future<void> setReverseSwipe(bool value) async {
    await _prefs.setBool(_reverseSwipeKey, value);
    await cloudChanges.markProfile();
  }

  Future<void> setReadingAboveTerm(bool value) async {
    await _prefs.setBool(_readingAboveTermKey, value);
    await cloudChanges.markProfile();
  }

  Future<void> setShowExamples(bool value) async {
    await _prefs.setBool(_showExamplesKey, value);
    await cloudChanges.markProfile();
  }

  Future<void> setFlipCard(bool value) async {
    await _prefs.setBool(_flipCardKey, value);
    await cloudChanges.markProfile();
  }

  Future<void> setJapaneseFont(String value) async {
    const allowed = {'system', 'notoSerifJP', 'sourceHanSerifJP'};
    await _prefs.setString(
        _japaneseFontKey, allowed.contains(value) ? value : 'system');
    await cloudChanges.markProfile();
  }

  Future<void> setCardFontSizes({
    required double term,
    required double reading,
    required double meaning,
    required double example,
    required double exampleMeaning,
  }) async {
    await Future.wait([
      _prefs.setDouble(_termFontSizeKey, term.clamp(20, 52).toDouble()),
      _prefs.setDouble(_readingFontSizeKey, reading.clamp(10, 28).toDouble()),
      _prefs.setDouble(_meaningFontSizeKey, meaning.clamp(14, 38).toDouble()),
      _prefs.setDouble(_exampleFontSizeKey, example.clamp(11, 28).toDouble()),
      _prefs.setDouble(
          _exampleMeaningFontSizeKey, exampleMeaning.clamp(10, 26).toDouble()),
    ]);
    await cloudChanges.markProfile();
  }

  Future<void> setMeaningStyle({
    required int fontWeight,
    required double opacity,
  }) async {
    final normalizedWeight =
        (((fontWeight.clamp(400, 700) / 100).round() * 100).clamp(400, 700))
            .toInt();
    await Future.wait([
      _prefs.setInt(_meaningFontWeightKey, normalizedWeight),
      _prefs.setDouble(_meaningOpacityKey, opacity.clamp(.45, 1).toDouble()),
    ]);
    await cloudChanges.markProfile();
  }

  Future<bool> setChatGptConversationUrl(String value) async {
    if (value.trim().isEmpty) {
      await _prefs.remove(_chatGptConversationUrlKey);
      return true;
    }
    final normalized = normalizeChatGptConversationUrl(value);
    if (normalized == null) return false;
    await _prefs.setString(_chatGptConversationUrlKey, normalized);
    return true;
  }

  Future<void> setTarget(String name, DateTime? date) async {
    await _prefs.setString(_targetNameKey, name.trim());
    if (date == null) {
      await _prefs.remove(_targetDateKey);
    } else {
      await _prefs.setString(_targetDateKey, date.toIso8601String());
    }
    await cloudChanges.markProfile();
  }

  Future<void> addBook(String name, List<Word> words) async {
    books.add(WordBook(
      id: _newBookId(),
      name: name.trim().isEmpty ? '가져온 단어장' : name.trim(),
      words: words,
    ));
    await _saveBooks();
    wordSearch.invalidate();
    final added = books.last;
    await cloudChanges.markBook(added.id);
    await cloudChanges.markWords(added.id, added.words.map((word) => word.id));
    await cloudChanges.markProfile();
  }

  Future<void> updateBook(WordBook updated) async {
    final index = books.indexWhere((book) => book.id == updated.id);
    if (index < 0) return;
    final previousWordIds = books[index].words.map((word) => word.id).toSet();
    final updatedWordIds = updated.words.map((word) => word.id).toSet();
    books[index] = updated;
    await _saveBooks();
    wordSearch.invalidate();
    await cloudChanges.markBook(updated.id);
    await cloudChanges.markWords(updated.id, updatedWordIds);
    for (final removedId in previousWordIds.difference(updatedWordIds)) {
      await cloudChanges.deleteWord(updated.id, removedId);
    }
  }

  Future<void> updateWord(Word updated) async {
    for (final book in books) {
      final index = book.words.indexWhere((word) => word.id == updated.id);
      if (index < 0) continue;
      book.words[index] = updated;
      await _saveBooks();
      wordSearch.invalidate();
      await cloudChanges.markWord(book.id, updated.id);
      return;
    }
  }

  Future<void> sortBooksByName() async {
    books.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await _saveBooks();
    wordSearch.invalidate();
    await cloudChanges.markProfile();
    for (final book in books) {
      await cloudChanges.markBook(book.id);
    }
  }

  Future<void> reorderBooks(int oldIndex, int newIndex) async {
    final book = books.removeAt(oldIndex);
    books.insert(newIndex, book);
    await _saveBooks();
    wordSearch.invalidate();
    await cloudChanges.markProfile();
    for (final reordered in books) {
      await cloudChanges.markBook(reordered.id);
    }
  }

  Future<void> completeSessions(String bookId, Iterable<int> indexes) async {
    final completedIndexes = indexes.toSet();
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    completed.addAll(completedIndexes.map((index) => '$bookId:$index'));
    await _prefs.setStringList(_completedKey, completed.toList());
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet()
      ..add(_dayKey(DateTime.now()));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await _clearActiveStudiesForSessions(bookId, completedIndexes);
    await cloudChanges.markProfile();
    onSessionCompleted?.call();
  }

  Future<void> deleteBook(String id) async {
    final wasSelected = quickBook.id == id;
    final deleted = books.where((book) => book.id == id).firstOrNull;
    final studiesToClear = activeStudies.entries
        .where((entry) => entry.value.bookId == id)
        .map((entry) => entry.key)
        .toList();
    for (final key in studiesToClear) {
      await clearActiveStudyFor(key);
    }
    books.removeWhere((book) => book.id == id && id != 'default');
    if (wasSelected) await selectQuickBook('default');
    await _saveBooks();
    wordSearch.invalidate();
    if (deleted != null && id != 'default') {
      await cloudChanges.deleteBook(id, deleted.words.map((word) => word.id));
    }
  }

  Future<void> mark(Word word, StudyState state) async {
    word.state = state;
    await _saveBooks();
    final book = books
        .where((candidate) => candidate.words.any((item) => item.id == word.id))
        .firstOrNull;
    if (book != null) await cloudChanges.markWord(book.id, word.id);
  }

  Future<void> completeCurrentSession() async {
    final completedIndex = nextSessionIndex(quickBook);
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    completed.add('${quickBook.id}:$completedIndex');
    await _prefs.setStringList(_completedKey, completed.toList());
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet()
      ..add(_dayKey(DateTime.now()));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await _clearActiveStudiesForSessions(quickBook.id, {completedIndex});
    await cloudChanges.markProfile();
    onSessionCompleted?.call();
  }

  Future<void> resetProgress() async {
    for (final book in books) {
      for (final word in book.words) {
        word.state = StudyState.fresh;
      }
    }
    await _prefs.remove(_completedKey);
    await _prefs.remove(_studyDaysKey);
    await clearAllActiveStudies();
    await _saveBooks();
    await cloudChanges.markProfile();
    for (final book in books) {
      await cloudChanges.markWords(book.id, book.words.map((word) => word.id));
    }
  }

  Map<String, dynamic> toBackupJson() => {
        'version': 1,
        'books': books.map((book) => book.toJson()).toList(),
        'quickBook': _prefs.getString(_quickBookKey) ?? 'default',
        'sessionSize': sessionSize,
        'completed': _prefs.getStringList(_completedKey) ?? <String>[],
        'studyDays': _prefs.getStringList(_studyDaysKey) ?? <String>[],
        'targetName': targetName,
        'targetDate': _prefs.getString(_targetDateKey),
        'horizontalSwipe': horizontalSwipe,
        'reverseSwipe': reverseSwipe,
        'readingAboveTerm': readingAboveTerm,
        'showExamples': showExamples,
        'flipCard': flipCard,
        'japaneseFont': japaneseFont,
        'cardFontSizes': {
          'term': termFontSize,
          'reading': readingFontSize,
          'meaning': meaningFontSize,
          'example': exampleFontSize,
          'exampleMeaning': exampleMeaningFontSize,
        },
        'cardMeaningStyle': {
          'fontWeight': meaningFontWeight,
          'opacity': meaningOpacity,
        },
        'chatGptConversationUrl': chatGptConversationUrl,
        'activeStudy': activeStudy?.toJson(),
        'activeStudies': activeStudies.map((k, v) => MapEntry(k, v.toJson())),
      };

  Future<void> replaceWithBackupJson(Map<String, dynamic> json) async {
    await _prefs.remove(_activeStudyKey);
    await _prefs.remove(_activeStudiesKey);
    final decodedBooks = (json['books'] as List<dynamic>? ?? [])
        .map((item) => WordBook.fromJson(item as Map<String, dynamic>))
        .toList();
    books = decodedBooks.isEmpty ? [_defaultBook()] : decodedBooks;
    await _saveBooks();
    wordSearch.invalidate();

    final quickBookId = json['quickBook'] as String? ?? 'default';
    await selectQuickBook(
      books.any((book) => book.id == quickBookId)
          ? quickBookId
          : books.first.id,
    );
    await _prefs.setInt(
      _sessionSizeKey,
      (json['sessionSize'] as int? ?? 10).clamp(5, 100).toInt(),
    );
    await _prefs.setStringList(
      _completedKey,
      (json['completed'] as List<dynamic>? ?? []).cast<String>(),
    );
    await _prefs.setStringList(
      _studyDaysKey,
      (json['studyDays'] as List<dynamic>? ?? []).cast<String>(),
    );
    await _prefs.setString(_targetNameKey, json['targetName'] as String? ?? '');
    await _prefs.setBool(
        _horizontalSwipeKey, json['horizontalSwipe'] as bool? ?? false);
    await _prefs.setBool(
        _reverseSwipeKey, json['reverseSwipe'] as bool? ?? false);
    await _prefs.setBool(
        _readingAboveTermKey, json['readingAboveTerm'] as bool? ?? false);
    await _prefs.setBool(
        _showExamplesKey, json['showExamples'] as bool? ?? true);
    await _prefs.setBool(_flipCardKey, json['flipCard'] as bool? ?? false);
    await setJapaneseFont(json['japaneseFont'] as String? ?? 'system');
    final fontSizes =
        json['cardFontSizes'] as Map<String, dynamic>? ?? const {};
    await setCardFontSizes(
      term: (fontSizes['term'] as num?)?.toDouble() ?? 32,
      reading: (fontSizes['reading'] as num?)?.toDouble() ?? 14,
      meaning: (fontSizes['meaning'] as num?)?.toDouble() ?? 22,
      example: (fontSizes['example'] as num?)?.toDouble() ?? 16,
      exampleMeaning: (fontSizes['exampleMeaning'] as num?)?.toDouble() ?? 14,
    );
    final meaningStyle =
        json['cardMeaningStyle'] as Map<String, dynamic>? ?? const {};
    await setMeaningStyle(
      fontWeight: (meaningStyle['fontWeight'] as num?)?.toInt() ?? 500,
      opacity: (meaningStyle['opacity'] as num?)?.toDouble() ?? .70,
    );
    await setChatGptConversationUrl(
      json['chatGptConversationUrl'] as String? ?? '',
    );
    final targetDate = json['targetDate'] as String?;
    if (targetDate == null || DateTime.tryParse(targetDate) == null) {
      await _prefs.remove(_targetDateKey);
    } else {
      await _prefs.setString(_targetDateKey, targetDate);
    }
    await restoreActiveStudyFromBackupJson(json);
  }

  ActiveStudy? _activeStudyFromBackupJson(dynamic value) {
    if (value is! Map) return null;
    try {
      final active = ActiveStudy.fromJson(Map<String, dynamic>.from(value));
      return active.queueIds.isEmpty ? null : active;
    } catch (_) {
      return null;
    }
  }

  List<WordBook> _loadBooks() {
    final saved = _prefs.getString(_booksKey);
    if (saved == null) return [_defaultBook()];
    try {
      final decoded = jsonDecode(saved) as List<dynamic>;
      final loaded = decoded
          .map((item) => WordBook.fromJson(item as Map<String, dynamic>))
          .toList();
      return loaded.isEmpty ? [_defaultBook()] : loaded;
    } catch (_) {
      return [_defaultBook()];
    }
  }

  Future<void> _saveBooks() => _prefs.setString(
        _booksKey,
        jsonEncode(books.map((book) => book.toJson()).toList()),
      );

  String _newBookId() {
    var id = DateTime.now().microsecondsSinceEpoch.toString();
    while (books.any((book) => book.id == id)) {
      id = (int.parse(id) + 1).toString();
    }
    return id;
  }

  Future<void> _clearActiveStudiesForSessions(
      String bookId, Set<int> sessionIndexes) async {
    if (sessionIndexes.isEmpty) return;
    final keysToClear = activeStudies.entries
        .where((entry) {
          final active = entry.value;
          final selected = active.sessionSelections.isNotEmpty
              ? active.sessionSelections[bookId]
              : active.bookId == bookId
                  ? active.sessionIndexes
                  : null;
          return selected != null &&
              selected.any((index) => sessionIndexes.contains(index));
        })
        .map((entry) => entry.key)
        .toList();
    for (final key in keysToClear) {
      await clearActiveStudyFor(key);
    }
  }

  Future<void> _repairSwappedJapaneseFields() async {
    if (_prefs.getBool(_readingMeaningMigrationKey) ?? false) return;
    final changedWords = <String, List<int>>{};
    for (final book in books) {
      for (var index = 0; index < book.words.length; index++) {
        final word = book.words[index];
        final readingHasHangul = RegExp(r'[가-힣]').hasMatch(word.reading);
        final meaningHasKana =
            RegExp(r'[\u3040-\u30ff]').hasMatch(word.meaning);
        if (!readingHasHangul || !meaningHasKana) continue;
        book.words[index] = word.copyWith(
          reading: word.meaning,
          meaning: word.reading,
        );
        changedWords.putIfAbsent(book.id, () => []).add(word.id);
      }
    }
    if (changedWords.isNotEmpty) {
      await _saveBooks();
      wordSearch.invalidate();
      for (final entry in changedWords.entries) {
        await cloudChanges.markWords(entry.key, entry.value);
      }
    }
    await _prefs.setBool(_readingMeaningMigrationKey, true);
  }

  static String _dayKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static WordBook _defaultBook() => WordBook(
        id: 'default',
        name: '기본 단어장',
        words: [
          Word(
              term: 'ephemeral',
              reading: '/ɪˈfem.ər.əl/',
              meaning: '덧없는, 순간적인',
              example: 'Fame is ephemeral, but character endures.',
              exampleMeaning: '명성은 덧없지만 인격은 지속된다.'),
          Word(
              term: 'resilience',
              reading: '/rɪˈzɪl.i.əns/',
              meaning: '회복력, 탄력성',
              example: 'Her resilience in adversity inspired many.',
              exampleMeaning: '역경에 맞선 그녀의 회복력은 많은 이를 감동시켰다.'),
          Word(
              term: 'ambiguous',
              reading: '/æmˈbɪɡ.ju.əs/',
              meaning: '모호한, 불분명한',
              example: 'The contract had an ambiguous clause.',
              exampleMeaning: '계약서에 모호한 조항이 있었다.'),
          Word(
              term: 'serendipity',
              reading: '/ˌser.ənˈdɪp.ɪ.ti/',
              meaning: '뜻밖의 행운',
              example: 'Meeting her was pure serendipity.',
              exampleMeaning: '그녀를 만난 것은 순전히 뜻밖의 행운이었다.',
              state: StudyState.memorized),
          Word(
              term: 'pragmatic',
              reading: '/præɡˈmæt.ɪk/',
              meaning: '실용적인, 실리적인',
              example: 'We need a pragmatic approach.',
              exampleMeaning: '우리는 실용적인 접근법이 필요하다.'),
          Word(
              term: 'eloquent',
              reading: '/ˈel.ə.kwənt/',
              meaning: '유창한, 웅변적인',
              example: 'She delivered an eloquent speech.',
              exampleMeaning: '그녀는 유창한 연설을 했다.'),
          Word(
              term: 'meticulous',
              reading: '/məˈtɪk.jʊ.ləs/',
              meaning: '세심한, 꼼꼼한',
              example: 'He is meticulous about every detail.',
              exampleMeaning: '그는 모든 세부 사항에 꼼꼼하다.',
              state: StudyState.review),
          Word(
              term: 'tenacious',
              reading: '/təˈneɪ.ʃəs/',
              meaning: '끈질긴, 집요한',
              example: 'Her tenacious spirit overcame all obstacles.',
              exampleMeaning: '그녀의 끈질긴 정신이 모든 장애물을 극복했다.'),
          Word(
              term: 'lucid',
              reading: '/ˈluː.sɪd/',
              meaning: '명료한, 명쾌한',
              example: 'His lucid explanation made everything clear.',
              exampleMeaning: '그의 명료한 설명이 모든 것을 분명하게 했다.'),
          Word(
              term: 'profound',
              reading: '/prəˈfaʊnd/',
              meaning: '심오한, 깊은',
              example: 'The book had a profound effect on her worldview.',
              exampleMeaning: '그 책은 그녀의 세계관에 심오한 영향을 미쳤다.'),
          Word(
              term: 'versatile',
              reading: '/ˈvɜː.sə.taɪl/',
              meaning: '다재다능한',
              example: 'She is a versatile musician.',
              exampleMeaning: '그녀는 다재다능한 음악가다.'),
          Word(
              term: 'diligent',
              reading: '/ˈdɪl.ɪ.dʒənt/',
              meaning: '부지런한, 근면한',
              example: 'Diligent students achieve great results.',
              exampleMeaning: '부지런한 학생들은 좋은 성과를 낸다.'),
          Word(
              term: 'candid',
              reading: '/ˈkæn.dɪd/',
              meaning: '솔직한',
              example: 'I appreciate your candid feedback.',
              exampleMeaning: '솔직한 피드백에 감사해요.'),
          Word(
              term: 'innate',
              reading: '/ɪˈneɪt/',
              meaning: '타고난, 선천적인',
              example: 'She has an innate talent for languages.',
              exampleMeaning: '그녀는 언어에 타고난 재능이 있다.'),
          Word(
              term: 'verbose',
              reading: '/vɜːˈboʊs/',
              meaning: '장황한, 말이 많은',
              example: 'His verbose speech bored the audience.',
              exampleMeaning: '그의 장황한 연설은 청중을 지루하게 했다.'),
        ],
      );
}
