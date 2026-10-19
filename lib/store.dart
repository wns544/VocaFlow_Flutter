import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_change_tracker.dart';
import 'card_sync.dart';
import 'kanji_lookup.dart';
import 'large_local_store.dart';
import 'local_word_search.dart';
import 'models.dart';
import 'sync_replica.dart';
import 'sync_auxiliary.dart';
import 'word_relations.dart';

part 'store_sync.dart';

String _encodeAccountSnapshot(Map<String, dynamic> state) => jsonEncode(state);

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
    this.seenWordIds = const [],
    this.roundNumber = 1,
    this.roundTotal = 0,
    this.roundCompleted = 0,
    this.roundUnknownIds = const [],
    this.roundUnknownBookIds = const [],
    this.sessionSelections = const {},
    this.lastWordBookId,
    this.startedAt,
    this.updatedAt,
    this.rangeStart,
    this.rangeEnd,
    this.sourceMode,
    this.rangeCourseSchema = VocaStore.rangeCourseSchemaVersion,
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
  final List<int> seenWordIds;
  final int roundNumber;
  final int roundTotal;
  final int roundCompleted;
  final List<int> roundUnknownIds;
  final List<String> roundUnknownBookIds;
  final Map<String, List<int>> sessionSelections;
  final String? lastWordBookId;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final int? rangeStart;
  final int? rangeEnd;
  final String? sourceMode;
  final int rangeCourseSchema;

  bool get isRangeCourse =>
      bookId != null && rangeStart != null && rangeEnd != null;

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
        'seenWordIds': seenWordIds,
        'roundNumber': roundNumber,
        'roundTotal': roundTotal,
        'roundCompleted': roundCompleted,
        'roundUnknownIds': roundUnknownIds,
        'roundUnknownBookIds': roundUnknownBookIds,
        'sessionSelections': sessionSelections,
        'lastWordBookId': lastWordBookId,
        'startedAt':
            (startedAt ?? updatedAt ?? DateTime.now()).toIso8601String(),
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
        'sourceMode': sourceMode,
        'rangeCourseSchema': rangeCourseSchema,
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
        seenWordIds: (json['seenWordIds'] as List<dynamic>? ?? [])
            .map((item) => (item as num).toInt())
            .toList(),
        roundNumber: (json['roundNumber'] as num?)?.toInt() ?? 1,
        roundTotal: (json['roundTotal'] as num?)?.toInt() ?? 0,
        roundCompleted: (json['roundCompleted'] as num?)?.toInt() ?? 0,
        roundUnknownIds: (json['roundUnknownIds'] as List<dynamic>? ?? [])
            .map((item) => (item as num).toInt())
            .toList(),
        roundUnknownBookIds:
            (json['roundUnknownBookIds'] as List<dynamic>? ?? [])
                .cast<String>(),
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
        startedAt: json['startedAt'] == null
            ? null
            : DateTime.tryParse(json['startedAt'] as String),
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.tryParse(json['updatedAt'] as String),
        rangeStart: (json['rangeStart'] as num?)?.toInt(),
        rangeEnd: (json['rangeEnd'] as num?)?.toInt(),
        sourceMode: json['sourceMode'] as String?,
        rangeCourseSchema: (json['rangeCourseSchema'] as num?)?.toInt() ?? 1,
      );
}

class StudyDecision {
  const StudyDecision({
    required this.wordId,
    required this.previousState,
    required this.decision,
    this.bookId,
    this.dismissedPositive,
    this.usedHorizontalSwipe,
  });

  final int wordId;
  final StudyState previousState;
  final StudyState decision;
  final String? bookId;
  final bool? dismissedPositive;
  final bool? usedHorizontalSwipe;

  Map<String, dynamic> toJson() => {
        'wordId': wordId,
        'previousState': previousState.name,
        'decision': decision.name,
        'bookId': bookId,
        'dismissedPositive': dismissedPositive,
        'usedHorizontalSwipe': usedHorizontalSwipe,
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
        dismissedPositive: json['dismissedPositive'] as bool?,
        usedHorizontalSwipe: json['usedHorizontalSwipe'] as bool?,
      );
}

class DailyStudyStats {
  const DailyStudyStats({
    this.studiedCards = 0,
    this.completedSessions = 0,
    this.correctCount = 0,
    this.wrongCount = 0,
  });

  final int studiedCards;
  final int completedSessions;
  final int correctCount;
  final int wrongCount;

  DailyStudyStats copyWith({
    int? studiedCards,
    int? completedSessions,
    int? correctCount,
    int? wrongCount,
  }) =>
      DailyStudyStats(
        studiedCards: studiedCards ?? this.studiedCards,
        completedSessions: completedSessions ?? this.completedSessions,
        correctCount: correctCount ?? this.correctCount,
        wrongCount: wrongCount ?? this.wrongCount,
      );

  Map<String, dynamic> toJson() => {
        'studiedCards': studiedCards,
        'completedSessions': completedSessions,
        'correctCount': correctCount,
        'wrongCount': wrongCount,
      };

  factory DailyStudyStats.fromJson(Map<String, dynamic> json) =>
      DailyStudyStats(
        studiedCards: (json['studiedCards'] as num?)?.toInt() ?? 0,
        completedSessions: (json['completedSessions'] as num?)?.toInt() ?? 0,
        correctCount: (json['correctCount'] as num?)?.toInt() ?? 0,
        wrongCount: (json['wrongCount'] as num?)?.toInt() ?? 0,
      );
}

class StudyEventLog {
  const StudyEventLog({
    required this.id,
    required this.date,
    required this.timestamp,
    required this.bookId,
    required this.wordId,
    required this.sessionIndexes,
    required this.decision,
    this.previousState,
    this.previousCorrectCount,
    this.previousWrongCount,
    this.previousLastStudiedAt,
    this.previousLastWrongAt,
  });

  final String id;
  final String date;
  final DateTime timestamp;
  final String? bookId;
  final int wordId;
  final List<int> sessionIndexes;
  final StudyState decision;
  final StudyState? previousState;
  final int? previousCorrectCount;
  final int? previousWrongCount;
  final DateTime? previousLastStudiedAt;
  final DateTime? previousLastWrongAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'timestamp': timestamp.toIso8601String(),
        'bookId': bookId,
        'wordId': wordId,
        'sessionIndexes': sessionIndexes,
        'decision': decision.name,
        'previousState': previousState?.name,
        'previousCorrectCount': previousCorrectCount,
        'previousWrongCount': previousWrongCount,
        'previousLastStudiedAt': previousLastStudiedAt?.toIso8601String(),
        'previousLastWrongAt': previousLastWrongAt?.toIso8601String(),
      };

  factory StudyEventLog.fromJson(Map<String, dynamic> json) => StudyEventLog(
        id: json['id'] as String? ?? '',
        date: json['date'] as String? ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        bookId: json['bookId'] as String?,
        wordId: (json['wordId'] as num?)?.toInt() ?? 0,
        sessionIndexes: (json['sessionIndexes'] as List<dynamic>? ?? [])
            .map((item) => (item as num).toInt())
            .toList(),
        decision: StudyState.values.firstWhere(
          (state) => state.name == json['decision'],
          orElse: () => StudyState.fresh,
        ),
        previousState: StudyState.values
            .where((state) => state.name == json['previousState'])
            .firstOrNull,
        previousCorrectCount: (json['previousCorrectCount'] as num?)?.toInt(),
        previousWrongCount: (json['previousWrongCount'] as num?)?.toInt(),
        previousLastStudiedAt:
            DateTime.tryParse(json['previousLastStudiedAt'] as String? ?? ''),
        previousLastWrongAt:
            DateTime.tryParse(json['previousLastWrongAt'] as String? ?? ''),
      );
}

enum DailyStudyStatus { none, low, medium, completed }

class VocaStore {
  VocaStore._(this._prefs);

  static const _booksKey = 'books';
  static const _accountStatePrefix = 'accountState.v1.';
  // The unscoped preferences are the live cache for this account while the
  // app is closed.  Remember who owns that cache so a restart never replaces
  // recent local settings with an older account snapshot.
  static const _lastActiveAccountKey = 'activeAccount.v1';
  static const _quickBookKey = 'quickBook';
  static const _sessionSizeKey = 'sessionSize';
  static const _completedKey = 'completed';
  static const _completedAtKey = 'completedAt';
  static const _coursePassesKey = 'rangeCoursePassesV2';
  static const _studyDaysKey = 'studyDays';
  static const _dailyStudyStatsKey = 'dailyStudyStats';
  static const _studyEventLogKey = 'studyEventLog';
  static const _targetNameKey = 'targetName';
  static const _targetDateKey = 'targetDate';
  static const _horizontalSwipeKey = 'horizontalSwipe';
  static const _reverseSwipeKey = 'reverseSwipe';
  static const _readingAboveTermKey = 'readingAboveTerm';
  static const _showExamplesKey = 'showExamples';
  static const _flipCardKey = 'flipCard';
  static const _autoPlayPronunciationKey = 'autoPlayPronunciation';
  static const _undoHapticsKey = 'undoHaptics';
  static const _activeStudyKey = 'activeStudy';
  static const _lastMainTabKey = 'lastMainTab';
  static const _mainTabMigrationKey = 'mainTabMigrationV2';
  static const _japaneseFontKey = 'japaneseFont';
  static const _termFontSizeKey = 'termFontSize';
  static const _readingFontSizeKey = 'readingFontSize';
  static const _meaningFontSizeKey = 'meaningFontSize';
  static const _meaningFontWeightKey = 'meaningFontWeight';
  static const _meaningOpacityKey = 'meaningOpacity';
  static const _exampleFontSizeKey = 'exampleFontSize';
  static const _exampleMeaningFontSizeKey = 'exampleMeaningFontSize';
  static const _chatGptConversationUrlKey = 'chatGptConversationUrl';
  static const _chatGptConversationUrlUpdatedAtKey =
      'chatGptConversationUrlUpdatedAt';
  static const _bookOrderUpdatedAtKey = 'bookOrderUpdatedAt';
  static const _openDictionaryInAppKey = 'openDictionaryInApp';
  static const _openDictionaryInAppUpdatedAtKey =
      'openDictionaryInAppUpdatedAt';
  static const _settingsVersionsKey = 'settings.v2.versions';
  static const _settingsBootstrapPrefix = 'settings.v3.bootstrap.';
  static const _chatGptWordPromptTemplateKey = 'chatGptWordPromptTemplate';
  static const _chatGptKanjiPromptTemplateKey = 'chatGptKanjiPromptTemplate';
  static const _readingMeaningMigrationKey = 'readingMeaningMigrationV1';
  static const _placeholderReadingMeaningMigrationKey =
      'readingMeaningMigrationV2';
  static const _verifiedTextCorrectionMigrationKey =
      'verifiedTextCorrectionMigrationV4';
  static const int rangeCourseSchemaVersion = 2;
  static const _rangeCourseMigrationKey = 'rangeCourseMigrationV4';
  static const studyEventLogMaxItems = 3000;
  static const studyEventLogMaxAge = Duration(days: 90);

  /// Preferences are deliberately separate from learning-state sync. Each key
  /// has its own version so two phones can merge unrelated changes safely.
  static const settingsPreferenceKeys = <String>[
    _quickBookKey,
    _sessionSizeKey,
    _targetNameKey,
    _targetDateKey,
    _horizontalSwipeKey,
    _reverseSwipeKey,
    _readingAboveTermKey,
    _showExamplesKey,
    _flipCardKey,
    _autoPlayPronunciationKey,
    _undoHapticsKey,
    _japaneseFontKey,
    _termFontSizeKey,
    _readingFontSizeKey,
    _meaningFontSizeKey,
    _exampleFontSizeKey,
    _exampleMeaningFontSizeKey,
    _meaningFontWeightKey,
    _meaningOpacityKey,
    _chatGptConversationUrlKey,
    _chatGptWordPromptTemplateKey,
    _chatGptKanjiPromptTemplateKey,
    _openDictionaryInAppKey,
  ];

  final SharedPreferences _prefs;
  String? _activeAccountId;
  late List<WordBook> books;
  late CloudChangeTracker cloudChanges;
  late CardChangeTracker cardChanges;
  late LocalWordSearchIndex wordSearch;
  Future<void> _localWrites = Future<void>.value();
  final Object _mutationZone = Object();
  String? _decisionEventPrefix;
  int _decisionEventSequence = 0;
  final ValueNotifier<int> cardContentRevision = ValueNotifier<int>(0);

  /// A single local writer prevents a remote merge from interleaving with a
  /// decision's read/modify/write steps. Nested store helpers remain reentrant.
  Future<T> runLocalMutation<T>(Future<T> Function() action) {
    if (Zone.current[_mutationZone] == true) return action();
    final task = _localWrites
        .then((_) => runZoned(action, zoneValues: {_mutationZone: true}));
    _localWrites =
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  Word? resolveCard(String bookId, int wordId) => books
      .where((book) => book.id == bookId)
      .expand((book) => book.words)
      .where((word) => word.id == wordId)
      .firstOrNull;

  void _overlayPendingCardFields(Word word, String bookId) {
    final fields = cardChanges.pendingFields(bookId, word.id);
    if (fields.containsKey('term')) word.term = fields['term'] as String;
    if (fields.containsKey('reading'))
      word.reading = fields['reading'] as String;
    if (fields.containsKey('meaning'))
      word.meaning = fields['meaning'] as String;
    if (fields.containsKey('example'))
      word.example = fields['example'] as String;
    if (fields.containsKey('exampleMeaning'))
      word.exampleMeaning = fields['exampleMeaning'] as String;
    if (fields.containsKey('explanation'))
      word.explanation = fields['explanation'] as String;
  }

  void Function()? onSessionCompleted;

  /// Installed by the account-sync coordinator. It records a restoration
  /// point before a user edit or deletion changes this book locally.
  Future<void> Function(String bookId, String reason)? onBeforeBookMutation;
  Map<String, DailyStudyStats>? _dailyStudyStatsCache;
  List<StudyEventLog>? _studyEventLogCache;
  Map<String, ActiveStudy>? _activeStudiesCache;
  Map<String, DateTime>? _activeStudyTombstonesCache;
  Map<String, DateTime>? _completedAtCache;
  Map<String, DateTime>? _resetMarkersCache;
  SyncReplica? _replica;
  Future<void> _syncWork = Future<void>.value();
  Future<void> Function()? beforeRemoteApply;
  bool _applyingReplica = false;

  /// Increments only after a complete dedicated learning-state merge.
  /// Study routes listen to it so they never keep showing a stale queue.
  final ValueNotifier<int> learningStateRevision = ValueNotifier<int>(0);

  static Future<VocaStore> load() async {
    final store = VocaStore._(await SharedPreferences.getInstance());
    store.books = store._loadBooks();
    store.cloudChanges = await CloudChangeTracker.load();
    store.cardChanges = await CardChangeTracker.load();
    final savedOwner = store._prefs.getString(_lastActiveAccountKey);
    if (savedOwner != null) {
      await store.cloudChanges.activateAccount(savedOwner);
      await store.cardChanges.activateAccount(savedOwner);
    }
    // The coordinator already owns the cloud-change callback. Card edits use
    // the same scheduler but a completely separate durable outbox.
    store.cardChanges.onChanged = () => store.cloudChanges.onChanged?.call();
    await store._migrateOpenDictionaryInAppSetting();
    await store._migrateMainTab();
    store.wordSearch = LocalWordSearchIndex(() => store.books);
    for (final book in store.books) {
      for (final word in book.words) {
        store._overlayPendingCardFields(word, book.id);
      }
    }
    if (store.cardChanges.isDirty) await store._saveBooks();
    await store._migrateRangeCourses();
    await store._repairSwappedJapaneseFields();
    await store._repairPlaceholderReadingMeaningFields();
    await store._applyVerifiedTextCorrections();
    await store._recoverLocalDecision();
    await store._loadSyncReplica();
    // A learning-state change must be cheap: card decisions and card flips
    // happen on the UI path.  The replica captures the current local state
    // immediately before an upload in syncV2Snapshot instead.  Capturing it
    // here serialized every word in every book on each interaction.
    SyncAuxiliary.onChanged = store.cloudChanges.markLearningState;
    return store;
  }

  Future<void> _migrateMainTab() async {
    if (_prefs.getBool(_mainTabMigrationKey) ?? false) return;
    final old = _prefs.getInt(_lastMainTabKey);
    if (old != null && old > 0) {
      await _prefs.setInt(
          _lastMainTabKey,
          old == 1
              ? 2
              : old == 2
                  ? 3
                  : old);
    }
    await _prefs.setBool(_mainTabMigrationKey, true);
  }

  Future<void> _migrateRangeCourses() async {
    if (_prefs.getBool(_rangeCourseMigrationKey) ?? false) return;
    final studies = Map<String, ActiveStudy>.from(activeStudies);
    studies.removeWhere((_, active) => active.isRangeCourse);
    await _saveActiveStudies(studies);
    await _prefs.remove(_activeStudyKey);
    await _prefs.setBool(_rangeCourseMigrationKey, true);
    await cloudChanges.markProfile();
  }

  WordBook get quickBook {
    final id = _prefs.getString(_quickBookKey) ?? 'default';
    return books.firstWhere((book) => book.id == id, orElse: () => books.first);
  }

  int get sessionSize => _prefs.getInt(_sessionSizeKey) ?? 10;
  int get lastMainTab {
    final value = _prefs.getInt(_lastMainTabKey) ?? 0;
    return value.clamp(0, 3);
  }

  bool get horizontalSwipe => _prefs.getBool(_horizontalSwipeKey) ?? false;
  bool get reverseSwipe => _prefs.getBool(_reverseSwipeKey) ?? false;
  bool get undoHaptics => _prefs.getBool(_undoHapticsKey) ?? false;
  bool get readingAboveTerm => _prefs.getBool(_readingAboveTermKey) ?? false;
  bool get showExamples => _prefs.getBool(_showExamplesKey) ?? true;
  bool get flipCard => _prefs.getBool(_flipCardKey) ?? false;
  bool get autoPlayPronunciation =>
      _prefs.getBool(_autoPlayPronunciationKey) ?? true;
  String get japaneseFont => _prefs.getString(_japaneseFontKey) ?? 'system';
  double _doublePreference(String key, double fallback) {
    final value = _prefs.get(key);
    return value is num ? value.toDouble() : fallback;
  }

  double get termFontSize => _doublePreference(_termFontSizeKey, 32);
  double get readingFontSize => _doublePreference(_readingFontSizeKey, 14);
  double get meaningFontSize => _doublePreference(_meaningFontSizeKey, 22);
  int get meaningFontWeight => _prefs.getInt(_meaningFontWeightKey) ?? 500;
  double get meaningOpacity => _doublePreference(_meaningOpacityKey, .70);
  double get exampleFontSize => _doublePreference(_exampleFontSizeKey, 16);
  double get exampleMeaningFontSize =>
      _doublePreference(_exampleMeaningFontSizeKey, 14);
  String get chatGptConversationUrl =>
      _prefs.getString(_chatGptConversationUrlKey) ?? '';
  String get chatGptWordPromptTemplate =>
      _prefs.getString(_chatGptWordPromptTemplateKey) ?? '';
  String get chatGptKanjiPromptTemplate =>
      _prefs.getString(_chatGptKanjiPromptTemplateKey) ?? '';

  Future<void> setChatGptPromptTemplates(String word, String kanji) async {
    final changed = <String>[];
    final normalizedWord = word.trim();
    final normalizedKanji = kanji.trim();
    if (chatGptWordPromptTemplate != normalizedWord) {
      await _prefs.setString(_chatGptWordPromptTemplateKey, normalizedWord);
      changed.add(_chatGptWordPromptTemplateKey);
    }
    if (chatGptKanjiPromptTemplate != normalizedKanji) {
      await _prefs.setString(_chatGptKanjiPromptTemplateKey, normalizedKanji);
      changed.add(_chatGptKanjiPromptTemplateKey);
    }
    await _markSettingsChanged(changed);
  }

  bool get openDictionaryInApp =>
      _prefs.getBool(_openDictionaryInAppKey) ?? false;

  DateTime? get openDictionaryInAppUpdatedAt {
    final raw = _prefs.getString(_openDictionaryInAppUpdatedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Map<String, dynamic>? get openDictionaryInAppSettingJson {
    final updatedAt = openDictionaryInAppUpdatedAt;
    if (updatedAt == null) return null;
    return {
      'value': openDictionaryInApp,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  String get targetName => _prefs.getString(_targetNameKey) ?? '';
  DateTime? get targetDate {
    final value = _prefs.getString(_targetDateKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  Map<String, DailyStudyStats> get dailyStudyStats {
    final cached = _dailyStudyStatsCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_dailyStudyStatsKey);
    if (saved == null) return _dailyStudyStatsCache = const {};
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return _dailyStudyStatsCache = decoded.map((key, value) => MapEntry(
            key,
            DailyStudyStats.fromJson(
                Map<String, dynamic>.from(value as Map<dynamic, dynamic>)),
          ));
    } catch (_) {
      return _dailyStudyStatsCache = const {};
    }
  }

  List<StudyEventLog> get studyEventLog {
    final cached = _studyEventLogCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_studyEventLogKey);
    if (saved == null) return _studyEventLogCache = const [];
    try {
      final decoded = jsonDecode(saved) as List<dynamic>;
      return _studyEventLogCache = decoded
          .map((item) => StudyEventLog.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .where((event) => event.id.isNotEmpty)
          .toList();
    } catch (_) {
      return _studyEventLogCache = const [];
    }
  }

  DailyStudyStatus dailyStudyStatus(String dayKey) {
    final stats = dailyStudyStats[dayKey];
    if (stats == null ||
        stats.studiedCards <= 0 && stats.completedSessions <= 0) {
      return DailyStudyStatus.none;
    }
    if (stats.completedSessions > 0) return DailyStudyStatus.completed;
    if (stats.studiedCards >= 10) return DailyStudyStatus.medium;
    return DailyStudyStatus.low;
  }

  List<String> recentDayKeys({int count = 7, DateTime? now}) {
    final today = now ?? DateTime.now();
    return List.generate(
      count,
      (index) => _dayKey(today.subtract(Duration(days: count - index - 1))),
    );
  }

  static const _activeStudiesKey = 'activeStudies';
  static const _activeStudyTombstonesKey = 'activeStudyTombstones';
  static const _resetMarkersKey = 'resetMarkers';

  Map<String, ActiveStudy> get activeStudies {
    final cached = _activeStudiesCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_activeStudiesKey);
    if (saved == null) {
      final oldActive = _loadOldActiveStudy();
      if (oldActive != null) {
        final key = activeStudyKeyFor(
          bookId: oldActive.bookId,
          sessionIndexes: oldActive.sessionIndexes,
          sessionSelections: oldActive.sessionSelections,
        );
        return _activeStudiesCache = {key: oldActive};
      }
      return _activeStudiesCache = const {};
    }
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return _activeStudiesCache = decoded.map((key, value) {
        return MapEntry(
          key,
          ActiveStudy.fromJson(value as Map<String, dynamic>),
        );
      });
    } catch (_) {
      return _activeStudiesCache = const {};
    }
  }

  Map<String, DateTime> get resetMarkers {
    final cached = _resetMarkersCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_resetMarkersKey);
    if (saved == null) return _resetMarkersCache = const {};
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return _resetMarkersCache = decoded.map((key, value) => MapEntry(
            key,
            DateTime.tryParse(value as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ));
    } catch (_) {
      return _resetMarkersCache = const {};
    }
  }

  Map<String, DateTime> get activeStudyTombstones {
    final cached = _activeStudyTombstonesCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_activeStudyTombstonesKey);
    if (saved == null) return _activeStudyTombstonesCache = const {};
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return _activeStudyTombstonesCache = decoded.map((key, value) => MapEntry(
            key,
            DateTime.tryParse(value as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ));
    } catch (_) {
      return _activeStudyTombstonesCache = const {};
    }
  }

  Map<String, DateTime> get completedAt {
    final cached = _completedAtCache;
    if (cached != null) return cached;
    final saved = _prefs.getString(_completedAtKey);
    if (saved == null) return _completedAtCache = const {};
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return _completedAtCache = decoded.map((key, value) => MapEntry(
            key,
            DateTime.tryParse(value as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ));
    } catch (_) {
      return _completedAtCache = const {};
    }
  }

  /// Completion badges on book and course lists are learning state too. Keep
  /// them beside every recovery checkpoint so a rollback cannot leave a book
  /// looking completed after its card decisions were restored.
  Map<String, Object?> _completionRecoverySnapshot() => {
        'completedSessionKeys':
            List<String>.from(_prefs.getStringList(_completedKey) ?? const [])
              ..sort(),
        'completedAt': completedAt.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
        'rangeCoursePasses': coursePasses,
        'dailyStudyStats': dailyStudyStats.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  Future<void> _recordCompletionRecoveryCheckpoint({
    required String reason,
    String? bookId,
    List<int> sessionIndexes = const [],
    int? rangeStart,
    int? rangeEnd,
  }) =>
      cloudChanges
          .recordDiagnostic('study_completion_recovery_checkpoint', data: {
        'reason': reason,
        'bookId': bookId,
        'sessionIndexes': sessionIndexes,
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
        'completion': _completionRecoverySnapshot(),
      });

  Future<void> _saveCompletedAt(Map<String, DateTime> values) {
    _completedAtCache = Map<String, DateTime>.from(values);
    return _prefs.setString(
      _completedAtKey,
      jsonEncode(values.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      )),
    );
  }

  Future<void> _saveDailyStudyStats(Map<String, DailyStudyStats> stats) {
    _dailyStudyStatsCache = Map<String, DailyStudyStats>.from(stats);
    return _prefs.setString(
      _dailyStudyStatsKey,
      jsonEncode(stats.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> _saveStudyEventLog(List<StudyEventLog> events) {
    _studyEventLogCache = List<StudyEventLog>.of(events);
    return _prefs.setString(
      _studyEventLogKey,
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
  }

  List<StudyEventLog> _prunedStudyEventLog(List<StudyEventLog> events,
      {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(studyEventLogMaxAge);
    final deduped = <String, StudyEventLog>{};
    for (final event in events) {
      if (event.timestamp.isBefore(cutoff)) continue;
      deduped[event.id] = event;
    }
    final result = deduped.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result.take(studyEventLogMaxItems).toList();
  }

  Future<void> _recordStudyAttempt({
    required Word word,
    required StudyState decision,
    required String? bookId,
    required List<int> sessionIndexes,
    required DateTime now,
    required StudyState previousState,
    required int previousCorrectCount,
    required int previousWrongCount,
    required DateTime? previousLastStudiedAt,
    required DateTime? previousLastWrongAt,
    String? operationId,
  }) async {
    final day = _dayKey(now);
    final stats = Map<String, DailyStudyStats>.from(dailyStudyStats);
    final current = stats[day] ?? const DailyStudyStats();
    stats[day] = current.copyWith(
      studiedCards: current.studiedCards + 1,
      correctCount:
          current.correctCount + (decision == StudyState.memorized ? 1 : 0),
      wrongCount: current.wrongCount + (decision == StudyState.review ? 1 : 0),
    );
    await _saveDailyStudyStats(stats);

    final event = StudyEventLog(
      id: operationId ??
          '${now.microsecondsSinceEpoch}:${bookId ?? 'unknown'}:${word.id}:${decision.name}',
      date: day,
      timestamp: now,
      bookId: bookId,
      wordId: word.id,
      sessionIndexes: sessionIndexes,
      decision: decision,
      previousState: previousState,
      previousCorrectCount: previousCorrectCount,
      previousWrongCount: previousWrongCount,
      previousLastStudiedAt: previousLastStudiedAt,
      previousLastWrongAt: previousLastWrongAt,
    );
    await _saveStudyEventLog(
        _prunedStudyEventLog([event, ...studyEventLog], now: now));
    await _appendSyncEvent(
        day,
        {
          'studiedCards': 1,
          'correctCount': decision == StudyState.memorized ? 1 : 0,
          'wrongCount': decision == StudyState.review ? 1 : 0,
        },
        bookId: bookId,
        wordId: word.id,
        eventId: operationId);
  }

  Future<void> _recordCompletedSessions(
      DateTime now, int completedSessionCount) async {
    if (completedSessionCount <= 0) return;
    final day = _dayKey(now);
    final stats = Map<String, DailyStudyStats>.from(dailyStudyStats);
    final current = stats[day] ?? const DailyStudyStats();
    stats[day] = current.copyWith(
      completedSessions: current.completedSessions + completedSessionCount,
    );
    await _saveDailyStudyStats(stats);
    await _appendSyncEvent(day, {'completedSessions': completedSessionCount});
  }

  Future<void> _saveResetMarkers(Map<String, DateTime> markers) {
    _resetMarkersCache = Map<String, DateTime>.from(markers);
    return _prefs.setString(
      _resetMarkersKey,
      jsonEncode(markers.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      )),
    );
  }

  Future<void> _saveActiveStudyTombstones(Map<String, DateTime> tombstones) {
    final sortedEntries = tombstones.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final pruned = Map<String, DateTime>.fromEntries(sortedEntries.take(100));
    _activeStudyTombstonesCache = pruned;
    return _prefs.setString(
      _activeStudyTombstonesKey,
      jsonEncode(pruned.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      )),
    );
  }

  Future<void> _markActiveStudyTombstone(String key) async {
    final tombstones = Map<String, DateTime>.from(activeStudyTombstones);
    tombstones[key] = DateTime.now();
    await _saveActiveStudyTombstones(tombstones);
  }

  Future<void> _markReset(String key) async {
    final markers = Map<String, DateTime>.from(resetMarkers);
    markers[key] = DateTime.now();
    await _saveResetMarkers(markers);
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

  String currentCourseKey(String bookId) => '$bookId:current';

  String activeStudyKey(ActiveStudy active) {
    if (active.isRangeCourse && active.bookId != null) {
      return currentCourseKey(active.bookId!);
    }
    return activeStudyKeyFor(
      bookId: active.bookId,
      sessionIndexes: active.sessionIndexes,
      sessionSelections: active.sessionSelections,
    );
  }

  bool _activeStudyDeletedAfter(String key, ActiveStudy active) {
    final deletedAt = activeStudyTombstones[key];
    final startedAt = active.startedAt ?? active.updatedAt;
    return deletedAt != null &&
        (startedAt == null || deletedAt.isAfter(startedAt));
  }

  ActiveStudy? activeCourseForBook(String bookId) {
    final active = activeStudies[currentCourseKey(bookId)];
    if (active == null || !active.isRangeCourse) return null;
    if (active.rangeCourseSchema < rangeCourseSchemaVersion ||
        resolveActiveWords(active).isEmpty) {
      return null;
    }
    return active;
  }

  List<Word> wordsForRange(String bookId, int rangeStart, int rangeEnd) {
    final book = books.where((item) => item.id == bookId).firstOrNull;
    if (book == null) return const [];
    final start = rangeStart.clamp(0, book.words.length).toInt();
    final end = rangeEnd.clamp(start, book.words.length).toInt();
    return book.words.sublist(start, end);
  }

  List<Word> unmemorizedWordsForRange(
          String bookId, int rangeStart, int rangeEnd) =>
      wordsForRange(bookId, rangeStart, rangeEnd)
          .where((word) => word.state != StudyState.memorized)
          .toList();

  bool isRangeFullyMemorized(String bookId, int rangeStart, int rangeEnd) {
    final words = wordsForRange(bookId, rangeStart, rangeEnd);
    return words.isNotEmpty &&
        words.every((word) => word.state == StudyState.memorized);
  }

  Future<ActiveStudy?> reopenIncompleteRangeCourse(
      String bookId, int rangeStart, int rangeEnd) async {
    final key = '$bookId:$rangeStart:$rangeEnd';
    final passes = Map<String, int>.from(coursePasses);
    if ((passes[key] ?? 0) <= 0) return null;
    final words = wordsForRange(bookId, rangeStart, rangeEnd);
    if (words.isEmpty) return null;

    passes.remove(key);
    await _prefs.setString(_coursePassesKey, jsonEncode(passes));
    final active = ActiveStudy(
      queueIds: words.map((word) => word.id).toList(),
      queueBookIds: List.filled(words.length, bookId),
      total: words.length,
      memorized: 0,
      sessionIndexes: const [],
      reviewed: const [],
      revealed: false,
      bookId: bookId,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      sourceMode: 'cumulative',
      rangeCourseSchema: rangeCourseSchemaVersion,
      updatedAt: DateTime.now(),
    );
    await saveActiveStudyFor(currentCourseKey(bookId), active,
        markCloudChange: false);
    await cloudChanges.markProfile();
    return activeCourseForBook(bookId);
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

  Future<ActiveStudy?> saveActiveStudyFor(String key, ActiveStudy active,
          {bool markCloudChange = true, DateTime? expectedUpdatedAt}) =>
      runLocalMutation(() => _saveActiveStudyFor(key, active,
          markCloudChange: markCloudChange,
          expectedUpdatedAt: expectedUpdatedAt));

  Future<ActiveStudy?> _saveActiveStudyFor(String key, ActiveStudy active,
      {bool markCloudChange = true, DateTime? expectedUpdatedAt}) async {
    final studies = Map<String, ActiveStudy>.from(activeStudies);
    final resolvedKey = active.isRangeCourse && active.bookId != null
        ? currentCourseKey(active.bookId!)
        : key;
    if (active.isRangeCourse && active.bookId != null) {
      studies.removeWhere((studyKey, study) =>
          study.bookId == active.bookId && study.isRangeCourse);
    }
    final previousActive = activeStudies[resolvedKey];
    if (expectedUpdatedAt != null &&
        previousActive?.updatedAt != null &&
        previousActive!.updatedAt!.isAfter(expectedUpdatedAt)) {
      unawaited(cloudChanges
          .recordDiagnostic('active_study_save_rejected_stale', data: {
        'studyKey': resolvedKey,
        'expectedUpdatedAt': expectedUpdatedAt.toIso8601String(),
        'storedUpdatedAt': previousActive.updatedAt!.toIso8601String(),
        'memorizedAttempted': active.memorized,
        'memorizedStored': previousActive.memorized,
      }));
      return null;
    }
    Map<String, dynamic> progress(ActiveStudy study) {
      final raw = study.toJson();
      return {
        for (final key in [
          'queueIds',
          'queueBookIds',
          'total',
          'memorized',
          'reviewed',
          'sessionIndexes',
          'bookId',
          'seenWordIds',
          'roundNumber',
          'roundTotal',
          'roundCompleted',
          'roundUnknownIds',
          'roundUnknownBookIds',
          'sessionSelections',
          'rangeStart',
          'rangeEnd',
          'sourceMode'
        ])
          key: raw[key]
      };
    }

    if (previousActive != null &&
        SyncReplica.canonical(progress(previousActive)) ==
            SyncReplica.canonical(progress(active))) {
      // Pausing, flipping, or leaving a restored route is a local view save,
      // not a new learning action. Never give stale progress a fresh clock.
      final view = ActiveStudy.fromJson(
          {...previousActive.toJson(), 'revealed': active.revealed});
      studies[resolvedKey] = view;
      await _saveActiveStudies(studies);
      return view;
    }
    final startedAt = active.startedAt ??
        previousActive?.startedAt ??
        previousActive?.updatedAt ??
        DateTime.now();
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
      seenWordIds: List.of(active.seenWordIds),
      roundNumber: active.roundNumber,
      roundTotal: active.roundTotal,
      roundCompleted: active.roundCompleted,
      roundUnknownIds: List.of(active.roundUnknownIds),
      roundUnknownBookIds: List.of(active.roundUnknownBookIds),
      sessionSelections: active.sessionSelections,
      lastWordBookId: active.lastWordBookId,
      startedAt: startedAt,
      rangeStart: active.rangeStart,
      rangeEnd: active.rangeEnd,
      sourceMode: active.sourceMode,
      rangeCourseSchema: active.rangeCourseSchema,
      updatedAt: DateTime.now(),
    );
    studies[resolvedKey] = updatedActive;
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
    await _saveActiveStudies(studies);
    final tombstones = Map<String, DateTime>.from(activeStudyTombstones);
    if (tombstones.remove(resolvedKey) != null) {
      await _saveActiveStudyTombstones(tombstones);
    }
    if (markCloudChange) await cloudChanges.markLearningState();
    // Keep full queue and decision context in the device-local append-only
    // journal. This is recovery evidence only; vocabulary card documents are
    // never written or extended for this feature.
    await cloudChanges.recordDiagnostic('study_recovery_checkpoint', data: {
      'studyKey': resolvedKey,
      'activeStudy': updatedActive.toJson(),
      'completion': _completionRecoverySnapshot(),
    });
    return updatedActive;
  }

  Future<void> _saveActiveStudies(Map<String, ActiveStudy> studies) {
    _activeStudiesCache = Map<String, ActiveStudy>.from(studies);
    return _prefs.setString(
      _activeStudiesKey,
      jsonEncode(studies.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<void> clearActiveStudyFor(String key,
      {bool markCloudChange = true}) async {
    final studies = Map<String, ActiveStudy>.from(activeStudies);
    if (studies.containsKey(key)) {
      studies.remove(key);
      await _saveActiveStudies(studies);
      await _markActiveStudyTombstone(key);
      if (markCloudChange) await cloudChanges.markLearningState();
    }
  }

  Future<void> clearActiveCourseForBook(String bookId,
          {bool markCloudChange = true}) =>
      clearActiveStudyFor(currentCourseKey(bookId),
          markCloudChange: markCloudChange);

  Future<void> clearAllActiveStudies({bool markCloudChange = true}) async {
    final tombstones = Map<String, DateTime>.from(activeStudyTombstones);
    final now = DateTime.now();
    for (final key in activeStudies.keys) {
      tombstones[key] = now;
    }
    _activeStudiesCache = const {};
    await _prefs.remove(_activeStudiesKey);
    await _prefs.remove(_activeStudyKey);
    await _saveActiveStudyTombstones(tombstones);
    if (markCloudChange) await cloudChanges.markLearningState();
  }

  ActiveStudy? get activeStudy {
    final studies = activeStudies;
    if (studies.isEmpty) return null;
    ActiveStudy? latest;
    for (final active in studies.values) {
      if (isActiveStudyCompleted(active)) continue;
      if (active.queueIds.isEmpty ||
          resolveActiveWords(active).length != active.queueIds.length ||
          (active.isRangeCourse &&
              active.rangeCourseSchema < rangeCourseSchemaVersion)) continue;
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
      final key = activeStudyKey(current);
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
            !_activeStudyDeletedAfter(k, active) &&
            !isActiveStudyCompleted(active,
                completedOverride: backupCompleted) &&
            resolveActiveWords(active).length == active.queueIds.length) {
          studies[k] = active;
        }
      });
      await _saveActiveStudies(studies);
      return activeStudy;
    }
    final active = _activeStudyFromBackupJson(json['activeStudy']);
    if (active == null ||
        _activeStudyDeletedAfter(activeStudyKey(active), active) ||
        isActiveStudyCompleted(active, completedOverride: backupCompleted) ||
        resolveActiveWords(active).length != active.queueIds.length) {
      return null;
    }
    await saveActiveStudy(active, markCloudChange: false);
    return active;
  }

  Future<void> setLastMainTab(int index) =>
      _prefs.setInt(_lastMainTabKey, index.clamp(0, 3));

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

  Map<String, int> get coursePasses {
    final raw = _prefs.getString(_coursePassesKey);
    if (raw == null) return const {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toInt()),
      );
    } catch (_) {
      return const {};
    }
  }

  int coursePassesFor(String bookId, int start, int end) =>
      coursePasses['$bookId:$start:$end'] ?? 0;

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

  Map<String, Map<String, dynamic>> _settingsVersions() {
    final raw = _prefs.getString(_settingsVersionsKey);
    if (raw == null) return {};
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map)
            entry.key: Map<String, dynamic>.from(entry.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  int _compareSettingsVersion(Map<String, dynamic> a, Map<String, dynamic> b) {
    final clock = ((a['updatedAtMicros'] as num?)?.toInt() ?? 0)
        .compareTo((b['updatedAtMicros'] as num?)?.toInt() ?? 0);
    return clock != 0
        ? clock
        : '${a['deviceId'] ?? ''}'.compareTo('${b['deviceId'] ?? ''}');
  }

  Future<void> _markSettingsChanged(Iterable<String> keys) async {
    final changed = keys.toSet().where(settingsPreferenceKeys.contains).toSet();
    if (changed.isEmpty) return;
    final versions = _settingsVersions();
    final deviceId = await cloudChanges.deviceId();
    var clock = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final key in changed) {
      final previous =
          (versions[key]?['updatedAtMicros'] as num?)?.toInt() ?? 0;
      clock = clock > previous ? clock : previous + 1;
      versions[key] = {'updatedAtMicros': clock, 'deviceId': deviceId};
    }
    await _prefs.setString(_settingsVersionsKey, jsonEncode(versions));
    await cloudChanges.markSettings(changed);
  }

  Map<String, Map<String, dynamic>> settingsEntries(Iterable<String> keys) {
    final versions = _settingsVersions();
    return {
      for (final key in keys)
        if (settingsPreferenceKeys.contains(key) && versions[key] != null)
          key: {
            'value': _prefs.get(key),
            ...versions[key]!,
          },
    };
  }

  /// Returns only fields that have not been edited since [entries] was
  /// captured for an in-flight upload.
  Set<String> unchangedSettingsKeys(
    Map<String, Map<String, dynamic>> entries,
  ) {
    final versions = _settingsVersions();
    return {
      for (final entry in entries.entries)
        if (versions[entry.key] != null &&
            _compareSettingsVersion(versions[entry.key]!, entry.value) == 0)
          entry.key,
    };
  }

  /// Gives a pre-1.0.37 installation's explicitly stored local preferences a
  /// version once, so an old profile cannot replace the user's current phone
  /// settings during the first dedicated-settings sync.
  Future<void> _bootstrapLegacySettingsForAccount(String uid) async {
    final marker = '$_settingsBootstrapPrefix$uid';
    if (_prefs.getBool(marker) ?? false) return;
    final versions = _settingsVersions();
    final legacyLocalKeys = settingsPreferenceKeys.where(
      (key) => _prefs.containsKey(key) && !versions.containsKey(key),
    );
    await _markSettingsChanged(legacyLocalKeys);
    await _prefs.setBool(marker, true);
  }

  /// Applies only cloud entries newer than this phone's per-setting version.
  /// This never queues another upload, preventing a download loop.
  Future<void> applySettingsEntries(
    Map<String, dynamic> entries, {
    Map<String, Map<String, dynamic>>? expectedVersions,
  }) async {
    final versions = _settingsVersions();
    var changedVersions = false;
    for (final entry in entries.entries) {
      if (!settingsPreferenceKeys.contains(entry.key) || entry.value is! Map) {
        continue;
      }
      final remote = Map<String, dynamic>.from(entry.value as Map);
      final remoteVersion = {
        'updatedAtMicros': (remote['updatedAtMicros'] as num?)?.toInt() ?? 0,
        'deviceId': remote['deviceId']?.toString() ?? '',
      };
      final localVersion = versions[entry.key];
      final expectedVersion = expectedVersions?[entry.key];
      // The user changed this exact field while a cloud request was active.
      // Leave the newer local edit untouched; it remains in the upload queue.
      if (expectedVersion != null &&
          (localVersion == null ||
              _compareSettingsVersion(localVersion, expectedVersion) != 0)) {
        continue;
      }
      if (localVersion != null &&
          _compareSettingsVersion(remoteVersion, localVersion) <= 0) {
        continue;
      }
      await _setSharedPreference(entry.key, remote['value']);
      versions[entry.key] = remoteVersion;
      changedVersions = true;
    }
    if (changedVersions) {
      await _prefs.setString(_settingsVersionsKey, jsonEncode(versions));
    }
  }

  Future<void> selectQuickBook(String id) async {
    await _prefs.setString(_quickBookKey, id);
    await _markSettingsChanged([_quickBookKey]);
  }

  Future<void> setSessionSize(int value) async {
    await _rememberCompletedMembership();
    await _prefs.setInt(_sessionSizeKey, value.clamp(5, 100).toInt());
    await _projectCompletedMembership();
    await clearAllActiveStudies(markCloudChange: false);
    await _markSettingsChanged([_sessionSizeKey]);
  }

  Future<void> setHorizontalSwipe(bool value) async {
    await _prefs.setBool(_horizontalSwipeKey, value);
    await _markSettingsChanged([_horizontalSwipeKey]);
  }

  Future<void> setReverseSwipe(bool value) async {
    await _prefs.setBool(_reverseSwipeKey, value);
    await _markSettingsChanged([_reverseSwipeKey]);
  }

  Future<void> setReadingAboveTerm(bool value) async {
    await _prefs.setBool(_readingAboveTermKey, value);
    await _markSettingsChanged([_readingAboveTermKey]);
  }

  Future<void> setShowExamples(bool value) async {
    await _prefs.setBool(_showExamplesKey, value);
    await _markSettingsChanged([_showExamplesKey]);
  }

  Future<void> setFlipCard(bool value) async {
    await _prefs.setBool(_flipCardKey, value);
    await _markSettingsChanged([_flipCardKey]);
  }

  Future<void> setAutoPlayPronunciation(bool value) async {
    await _prefs.setBool(_autoPlayPronunciationKey, value);
    await _markSettingsChanged([_autoPlayPronunciationKey]);
  }

  Future<void> setUndoHaptics(bool value) async {
    await _prefs.setBool(_undoHapticsKey, value);
    await _markSettingsChanged([_undoHapticsKey]);
  }

  Future<void> setJapaneseFont(String value) async {
    const allowed = {'system', 'notoSerifJP', 'sourceHanSerifJP'};
    await _prefs.setString(
        _japaneseFontKey, allowed.contains(value) ? value : 'system');
    await _markSettingsChanged([_japaneseFontKey]);
  }

  Future<void> setCardFontSizes({
    required double term,
    required double reading,
    required double meaning,
    required double example,
    required double exampleMeaning,
  }) async {
    final next = <String, double>{
      _termFontSizeKey: term.clamp(20, 52).toDouble(),
      _readingFontSizeKey: reading.clamp(10, 28).toDouble(),
      _meaningFontSizeKey: meaning.clamp(14, 38).toDouble(),
      _exampleFontSizeKey: example.clamp(11, 28).toDouble(),
      _exampleMeaningFontSizeKey: exampleMeaning.clamp(10, 26).toDouble(),
    };
    final changed = next.entries
        .where(
            (entry) => _doublePreference(entry.key, double.nan) != entry.value)
        .toList();
    await Future.wait(
        changed.map((entry) => _prefs.setDouble(entry.key, entry.value)));
    await _markSettingsChanged(changed.map((entry) => entry.key));
  }

  Future<void> setMeaningStyle({
    required int fontWeight,
    required double opacity,
  }) async {
    final normalizedWeight =
        (((fontWeight.clamp(400, 700) / 100).round() * 100).clamp(400, 700))
            .toInt();
    final normalizedOpacity = opacity.clamp(.45, 1).toDouble();
    final changed = <String>[];
    if (meaningFontWeight != normalizedWeight) {
      await _prefs.setInt(_meaningFontWeightKey, normalizedWeight);
      changed.add(_meaningFontWeightKey);
    }
    if (meaningOpacity != normalizedOpacity) {
      await _prefs.setDouble(_meaningOpacityKey, normalizedOpacity);
      changed.add(_meaningOpacityKey);
    }
    await _markSettingsChanged(changed);
  }

  Future<bool> setChatGptConversationUrl(String value) async {
    final normalized =
        value.trim().isEmpty ? '' : normalizeChatGptConversationUrl(value);
    if (normalized == null) return false;
    final previous = DateTime.tryParse(
        _prefs.getString(_chatGptConversationUrlUpdatedAtKey) ?? '');
    final now = DateTime.now().toUtc();
    final updated = previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(microseconds: 1))
        : now;
    await Future.wait([
      _prefs.setString(_chatGptConversationUrlKey, normalized),
      _prefs.setString(
          _chatGptConversationUrlUpdatedAtKey, updated.toIso8601String()),
    ]);
    await _markSettingsChanged([_chatGptConversationUrlKey]);
    return true;
  }

  Future<void> setOpenDictionaryInApp(bool value) async {
    final updatedAt = DateTime.now().toUtc();
    await Future.wait([
      _prefs.setBool(_openDictionaryInAppKey, value),
      _prefs.setString(
        _openDictionaryInAppUpdatedAtKey,
        updatedAt.toIso8601String(),
      ),
    ]);
    await _markSettingsChanged([_openDictionaryInAppKey]);
  }

  Future<void> applyOpenDictionaryInAppSettingFromCloud(
    Map<String, dynamic> setting,
  ) async {
    final value = setting['value'];
    final updatedAtRaw = setting['updatedAt'];
    if (value is! bool || updatedAtRaw is! String) return;
    final remoteUpdatedAt = DateTime.tryParse(updatedAtRaw)?.toUtc();
    if (remoteUpdatedAt == null) return;
    final localUpdatedAt = openDictionaryInAppUpdatedAt;
    if (localUpdatedAt != null && !remoteUpdatedAt.isAfter(localUpdatedAt)) {
      return;
    }
    await Future.wait([
      _prefs.setBool(_openDictionaryInAppKey, value),
      _prefs.setString(
        _openDictionaryInAppUpdatedAtKey,
        remoteUpdatedAt.toIso8601String(),
      ),
    ]);
  }

  Future<void> _migrateOpenDictionaryInAppSetting() async {
    if (!openDictionaryInApp || openDictionaryInAppUpdatedAt != null) return;
    await _prefs.setString(
      _openDictionaryInAppUpdatedAtKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> setTarget(String name, DateTime? date) async {
    await _prefs.setString(_targetNameKey, name.trim());
    if (date == null) {
      await _prefs.remove(_targetDateKey);
    } else {
      await _prefs.setString(_targetDateKey, date.toIso8601String());
    }
    await _markSettingsChanged([_targetNameKey, _targetDateKey]);
  }

  Future<WordBook> addBook(String name, List<Word> words) async {
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
    await _markBookOrderChanged();
    return added;
  }

  /// Keeps each signed-in account's book library in its own local cache. The
  /// first account adopts the pre-account legacy library once; another account
  /// never inherits it. Progress itself remains account-scoped in Firebase's
  /// dedicated learningState documents.
  Future<void> activateAccount(String uid) =>
      runLocalMutation(() => _activateAccount(uid));

  Future<void> _activateAccount(String uid) async {
    if (_activeAccountId == uid) return;
    // Persist everything that determines what a user can resume on this
    // device before switching to a different account's local cache.
    if (_activeAccountId != null) await _saveAccountState(_activeAccountId!);
    final key = '$_accountStatePrefix$uid';
    final saved = await readLargeLocalValue(_prefs, key);
    final previousOwner = _prefs.getString(_lastActiveAccountKey);
    // On an ordinary restart, the root preferences are already this
    // account's newest local state.  Restoring `accountState` here used to
    // overwrite freshly changed font and swipe settings with an old snapshot.
    // A missing owner is a legacy installation; keep its live cache as well.
    final keepLiveCache = _activeAccountId == null &&
        (previousOwner == null || previousOwner == uid);
    if (keepLiveCache) {
      _activeAccountId = uid;
      await _saveAccountState(uid);
    } else if (saved != null) {
      await _restoreAccountState(saved);
    } else {
      if (_activeAccountId != null) {
        await _clearAccountScopedState();
        books = [_defaultBook()];
        _activeAccountId = uid;
        await _saveBooks();
      }
      await _saveAccountState(uid);
    }
    _activeAccountId = uid;
    await _prefs.setString(_lastActiveAccountKey, uid);
    await cloudChanges.activateAccount(uid);
    await cardChanges.activateAccount(uid);
    await _bootstrapLegacySettingsForAccount(uid);
    // A checkpoint is a recovery fallback, never a replacement for the live
    // preferences from the just-finished learning session on this device.
    if (!keepLiveCache && saved == null) await _restoreSyncCheckpoint(uid);
    for (final book in books) {
      for (final word in book.words) {
        _overlayPendingCardFields(word, book.id);
      }
    }
    await _recoverLocalDecision();
    await _loadSyncReplica();
    await wordRelations.reload();
    wordSearch.invalidate();
  }

  static const _accountScopedKeys = <String>[
    _booksKey,
    _quickBookKey,
    _sessionSizeKey,
    _completedKey,
    _completedAtKey,
    _coursePassesKey,
    _studyDaysKey,
    _dailyStudyStatsKey,
    _studyEventLogKey,
    _activeStudyKey,
    _activeStudiesKey,
    _activeStudyTombstonesKey,
    _resetMarkersKey,
    _bookOrderUpdatedAtKey,
    _syncReplicaKey,
    _syncDailyBaseKey,
    _syncEventsKey,
    _syncCompletedKey,
    ...settingsPreferenceKeys,
    _settingsVersionsKey,
    'wordRelations.v1',
    'pronunciationSelections.v1',
  ];

  Future<void> _saveAccountState(String uid) async {
    final state = <String, dynamic>{};
    for (final key in _accountScopedKeys) {
      final value = _prefs.get(key);
      if (value != null) state[key] = value;
    }
    // The in-memory books can be newer than the last preference write when a
    // caller is midway through a change.
    state[_booksKey] = _encodeBooks();
    final encoded = await compute(_encodeAccountSnapshot, state);
    await writeLargeLocalValue(
      _prefs,
      '$_accountStatePrefix$uid',
      encoded,
    );
  }

  Future<void> _restoreAccountState(String encoded) async {
    final raw = jsonDecode(encoded);
    if (raw is! Map) return;
    await _clearAccountScopedState();
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (!_accountScopedKeys.contains(key)) continue;
      final value = entry.value;
      if (value is String) {
        await _prefs.setString(key, value);
      } else if (value is bool) {
        await _prefs.setBool(key, value);
      } else if (value is int) {
        await _prefs.setInt(key, value);
      } else if (value is double) {
        await _prefs.setDouble(key, value);
      } else if (value is List) {
        await _prefs.setStringList(
            key, value.map((item) => item.toString()).toList());
      }
    }
    books = _loadBooks();
    _dailyStudyStatsCache = null;
    _studyEventLogCache = null;
    _activeStudiesCache = null;
    _activeStudyTombstonesCache = null;
    _completedAtCache = null;
    _resetMarkersCache = null;
  }

  Future<void> _clearAccountScopedState() async {
    for (final key in _accountScopedKeys) {
      await _prefs.remove(key);
    }
    _dailyStudyStatsCache = null;
    _studyEventLogCache = null;
    _activeStudiesCache = null;
    _activeStudyTombstonesCache = null;
    _completedAtCache = null;
    _resetMarkersCache = null;
  }

  Future<void> updateBook(WordBook updated) async {
    final index = books.indexWhere((book) => book.id == updated.id);
    if (index < 0) return;
    await onBeforeBookMutation?.call(updated.id, 'edit');
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

  /// Persists a card locally first, then queues only its changed text fields.
  /// New callers should always pass [bookId]; retaining the narrow fallback
  /// keeps old deep links usable while refusing ambiguous duplicate IDs.
  Future<CardChange?> updateWord(Word updated, {required String bookId}) =>
      runLocalMutation(() => _updateWord(updated, bookId: bookId));

  Future<CardChange?> _updateWord(Word updated,
      {required String bookId}) async {
    final matches = books.where((book) =>
        book.id == bookId && book.words.any((word) => word.id == updated.id));
    for (final book in matches) {
      final index = book.words.indexWhere((word) => word.id == updated.id);
      if (index < 0) continue;
      await onBeforeBookMutation?.call(book.id, 'edit');
      final previous = book.words[index];
      final favoriteChanged = previous.isFavorite != updated.isFavorite;
      if (previous.isFavorite != updated.isFavorite &&
          previous.favoriteUpdatedAt == updated.favoriteUpdatedAt) {
        updated.favoriteUpdatedAt = DateTime.now().toUtc();
      }
      final change = await cardChanges.enqueue(
        bookId: book.id,
        wordId: updated.id,
        before: _cardTextFields(previous),
        after: _cardTextFields(updated),
        notify: false,
      );
      // The durable operation is written first. A crash before _saveBooks is
      // repaired by the pending-field overlay on the next launch.
      previous.term = updated.term;
      previous.reading = updated.reading;
      previous.meaning = updated.meaning;
      previous.example = updated.example;
      previous.exampleMeaning = updated.exampleMeaning;
      previous.explanation = updated.explanation;
      previous.isFavorite = updated.isFavorite;
      previous.favoriteUpdatedAt = updated.favoriteUpdatedAt;
      await _saveBooks();
      wordSearch.invalidate();
      if (favoriteChanged) await cloudChanges.markLearningState();
      cardContentRevision.value++;
      cardChanges.notifyChanged();
      return change;
    }
    throw StateError('수정할 카드를 찾지 못했습니다: $bookId/${updated.id}');
  }

  Map<String, dynamic> _cardTextFields(Word word) => {
        'term': word.term,
        'reading': word.reading,
        'meaning': word.meaning,
        'example': word.example,
        'exampleMeaning': word.exampleMeaning,
        'explanation': word.explanation,
      };

  Future<void> setWordFavorite(Word word, bool value, {String? bookId}) async {
    final now = DateTime.now().toUtc();
    for (final book in books) {
      if (bookId != null && book.id != bookId) continue;
      final index =
          book.words.indexWhere((candidate) => candidate.id == word.id);
      if (index < 0) continue;
      final updated = book.words[index];
      updated.isFavorite = value;
      updated.favoriteUpdatedAt = now;
      await _saveBooks();
      wordSearch.invalidate();
      await cloudChanges.markLearningState();
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
    await _markBookOrderChanged();
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
    await _markBookOrderChanged();
  }

  Future<void> completeSessions(String bookId, Iterable<int> indexes) async {
    final completedIndexes = indexes.toSet();
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    completed.addAll(completedIndexes.map((index) => '$bookId:$index'));
    await _prefs.setStringList(_completedKey, completed.toList());
    await _rememberCompletedMembership();
    final completedTimes = Map<String, DateTime>.from(completedAt);
    final now = DateTime.now();
    for (final index in completedIndexes) {
      completedTimes['$bookId:$index'] = now;
    }
    await _saveCompletedAt(completedTimes);
    await _recordCompletedSessions(now, completedIndexes.length);
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet()
      ..add(_dayKey(DateTime.now()));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await _clearActiveStudiesForSessions(bookId, completedIndexes);
    await _recordCompletionRecoveryCheckpoint(
      reason: 'sessions_completed',
      bookId: bookId,
      sessionIndexes: completedIndexes.toList()..sort(),
    );
    // Completion changes the session badges and daily-study indicator. These
    // belong to learningState; marking only the legacy profile queue meant a
    // multi-session completion could remain local while card attempts synced.
    await cloudChanges.markLearningState();
    onSessionCompleted?.call();
  }

  Future<bool> completeRangeCourse(
      String bookId, int rangeStart, int rangeEnd) async {
    final passes = Map<String, int>.from(coursePasses);
    final key = '$bookId:$rangeStart:$rangeEnd';
    passes[key] = (passes[key] ?? 0) + 1;
    await _prefs.setString(_coursePassesKey, jsonEncode(passes));
    final now = DateTime.now();
    await _recordCompletedSessions(now, 1);
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet()
      ..add(_dayKey(now));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await clearActiveCourseForBook(bookId, markCloudChange: false);
    await _recordCompletionRecoveryCheckpoint(
      reason: 'range_course_completed',
      bookId: bookId,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
    await cloudChanges.markLearningState();
    onSessionCompleted?.call();
    return true;
  }

  Future<void> deleteBook(String id) async {
    if (id != 'default' && books.any((book) => book.id == id)) {
      await onBeforeBookMutation?.call(id, 'delete');
    }
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
      await _markBookOrderChanged();
    }
  }

  Future<void> _markBookOrderChanged() async {
    final previous =
        DateTime.tryParse(_prefs.getString(_bookOrderUpdatedAtKey) ?? '');
    final now = DateTime.now().toUtc();
    final updated = previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(microseconds: 1))
        : now;
    await _prefs.setString(_bookOrderUpdatedAtKey, updated.toIso8601String());
    final account = _activeAccountId;
    if (account != null) await _saveAccountState(account);
    await cloudChanges.markLearningState();
  }

  /// Captures exactly the selected book's content and the learning-state keys
  /// that belong to it. This is intentionally not a whole-account backup: a
  /// later restore cannot reset another book's progress.
  Map<String, dynamic> createBookRestorePayload(
    String bookId, {
    List<Map<String, dynamic>> relations = const [],
  }) {
    final book = books.where((item) => item.id == bookId).firstOrNull;
    if (book == null) throw StateError('복원할 단어장을 찾을 수 없습니다.');
    final state = toLearningStateJson();
    bool keyForBook(String key) => key.contains(bookId);
    // A multi-book study queue belongs to more than one library. Restoring it
    // wholesale would reset another book, so only a dedicated single-book
    // study is part of this book-scoped recovery payload.
    final active = Map<String, dynamic>.from(
        state['activeStudies'] as Map? ?? const {})
      ..removeWhere(
          (_, value) => value is! Map || value['bookId']?.toString() != bookId);
    return {
      'schema': 1,
      'book': book.toJson(),
      'learning': {
        'wordStates': {
          bookId: (state['wordStates'] as Map? ?? const {})[bookId]
        },
        'completed': (state['completed'] as List? ?? const [])
            .where((value) => value.toString().startsWith('$bookId:'))
            .toList(),
        'completedAt': _mapEntriesForBook(state['completedAt'], keyForBook),
        'rangeCoursePasses':
            _mapEntriesForBook(state['rangeCoursePasses'], keyForBook),
        'activeStudies': active,
        'activeStudyTombstones':
            _mapEntriesForBook(state['activeStudyTombstones'], keyForBook),
        'resetMarkers': _mapEntriesForBook(state['resetMarkers'], keyForBook),
        'studyEventLog': (state['studyEventLog'] as List? ?? const [])
            .where((value) => value is Map && value['bookId'] == bookId)
            .toList(),
      },
      'relations': relations,
    };
  }

  Map<String, dynamic> _mapEntriesForBook(
      dynamic raw, bool Function(String key) include) {
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value))
      ..removeWhere((key, _) => !include(key));
  }

  bool _activeValueReferencesBook(dynamic raw, String bookId) {
    if (raw is! Map) return false;
    if (raw['bookId'] == bookId) return true;
    final selections = raw['sessionSelections'];
    return selections is Map && selections.containsKey(bookId);
  }

  /// Replaces only the archived book and its book-scoped learning state. The
  /// original ID is retained, so sessions, favorites and relations still point
  /// to the same cards after recovery.
  Future<void> restoreBookFromPayload(Map<String, dynamic> payload) async {
    final rawBook = payload['book'];
    if (rawBook is! Map) throw StateError('복원 기록에 단어장 정보가 없습니다.');
    final restored = WordBook.fromJson(Map<String, dynamic>.from(rawBook));
    if (restored.id == 'default') throw StateError('기본 단어장은 복원할 수 없습니다.');
    final index = books.indexWhere((book) => book.id == restored.id);
    if (index < 0) {
      books.add(restored);
    } else {
      books[index] = restored;
    }
    final learning =
        Map<String, dynamic>.from(payload['learning'] as Map? ?? const {});
    final id = restored.id;
    final completed = (_prefs.getStringList(_completedKey) ?? <String>[])
        .where((key) => !key.startsWith('$id:'))
        .toSet()
      ..addAll((learning['completed'] as List? ?? const [])
          .map((item) => item.toString()));
    final completedTimes = Map<String, DateTime>.from(completedAt)
      ..removeWhere((key, _) => key.contains(id));
    completedTimes.addAll(_datesFromMap(learning['completedAt']));
    final passes = Map<String, int>.from(coursePasses)
      ..removeWhere((key, _) => key.contains(id));
    passes.addAll(_intsFromMap(learning['rangeCoursePasses']));
    final active = Map<String, ActiveStudy>.from(activeStudies)
      ..removeWhere(
          (_, value) => _activeValueReferencesBook(value.toJson(), id));
    final archiveActive = learning['activeStudies'];
    if (archiveActive is Map) {
      archiveActive.forEach((key, value) {
        if (value is Map)
          active[key.toString()] =
              ActiveStudy.fromJson(Map<String, dynamic>.from(value));
      });
    }
    final tombstones = Map<String, DateTime>.from(activeStudyTombstones)
      ..removeWhere((key, _) => key.contains(id));
    tombstones.addAll(_datesFromMap(learning['activeStudyTombstones']));
    final markers = Map<String, DateTime>.from(resetMarkers)
      ..removeWhere((key, _) => key.contains(id));
    markers.addAll(_datesFromMap(learning['resetMarkers']));
    final events = studyEventLog.where((event) => event.bookId != id).toList();
    final eventIds = events.map((event) => event.id).toSet();
    for (final raw in learning['studyEventLog'] as List? ?? const []) {
      if (raw is! Map) continue;
      final event = StudyEventLog.fromJson(Map<String, dynamic>.from(raw));
      if (eventIds.add(event.id)) events.add(event);
    }
    await _saveBooks();
    wordSearch.invalidate();
    await _prefs.setStringList(_completedKey, completed.toList());
    await _saveCompletedAt(completedTimes);
    await _prefs.setString(_coursePassesKey, jsonEncode(passes));
    await _saveActiveStudies(active);
    await _saveActiveStudyTombstones(tombstones);
    await _saveResetMarkers(markers);
    await _saveStudyEventLog(_prunedStudyEventLog(events));
    await cloudChanges.markBook(id);
    await cloudChanges.markWords(id, restored.words.map((word) => word.id));
    await cloudChanges.markLearningState();
    learningStateRevision.value++;
  }

  Map<String, DateTime> _datesFromMap(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, DateTime>{};
    raw.forEach((key, value) {
      final date = value is String ? DateTime.tryParse(value) : null;
      if (date != null) result[key.toString()] = date;
    });
    return result;
  }

  Map<String, int> _intsFromMap(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, int>{};
    raw.forEach((key, value) {
      if (value is num) result[key.toString()] = value.toInt();
    });
    return result;
  }

  /// Content-only data for the managedBooks sync channel. Study state is
  /// deliberately excluded and continues to live in learningState.
  Map<String, dynamic> toManagedBookJson(WordBook book) => {
        'id': book.id,
        'name': book.name,
        'isFavorite': book.isFavorite,
        'sessionOverrides': book.sessionOverrides.map(
          (key, value) => MapEntry(key.toString(), value.toJson()),
        ),
        'words': book.words
            .map((word) => {
                  'id': word.id,
                  'term': word.term,
                  'meaning': word.meaning,
                  'reading': word.reading,
                  'example': word.example,
                  'exampleMeaning': word.exampleMeaning,
                  'explanation': word.explanation,
                  'isFavorite': word.isFavorite,
                  'favoriteUpdatedAt':
                      word.favoriteUpdatedAt?.toIso8601String(),
                })
            .toList(),
      };

  /// Merges card content without replacing local study progress. The dedicated
  /// learningState merge restores authoritative progress immediately after this.
  Future<int> mergeManagedBooks(
    Iterable<Map<String, dynamic>> remote, {
    Set<String> locallyDirtyBookIds = const <String>{},
  }) async {
    var changed = 0;
    final remotelyDeleted = <String>[];
    for (final document in remote) {
      final id = document['id']?.toString();
      if (id == null || id == 'default' || locallyDirtyBookIds.contains(id)) {
        continue;
      }
      if (document['deleted'] == true) {
        remotelyDeleted.add(id);
        continue;
      }
      final content = document['content'];
      if (content is! Map) continue;
      final decoded = WordBook.fromJson(Map<String, dynamic>.from(content));
      if (decoded.id == 'default') continue;
      final index = books.indexWhere((book) => book.id == decoded.id);
      if (index < 0) {
        books.add(decoded);
        changed++;
        continue;
      }
      final local = books[index];
      final states = <int, Word>{for (final word in local.words) word.id: word};
      for (final word in decoded.words) {
        final old = states[word.id];
        if (old == null) continue;
        word.state = old.state;
        word.correctCount = old.correctCount;
        word.wrongCount = old.wrongCount;
        word.lastStudiedAt = old.lastStudiedAt;
        word.lastWrongAt = old.lastWrongAt;
      }
      books[index] = decoded;
      changed++;
    }
    if (remotelyDeleted.isNotEmpty) {
      changed += await _applyRemoteBookDeletions(remotelyDeleted);
    }
    if (changed > 0) {
      await _saveBooks();
      wordSearch.invalidate();
    }
    return changed;
  }

  /// Applies the new per-card source without touching study counters, current
  /// card side, session position, or active-study queues.  The parent keeps
  /// ordering while every card document supplies only card content.
  Future<int> mergeCardBooks(Iterable<CardBookSnapshot> remote) =>
      runLocalMutation(() => _mergeCardBooks(remote));

  Future<int> _mergeCardBooks(Iterable<CardBookSnapshot> remote) async {
    // Capture genuine edits before adding server-owned content. A newly
    // downloaded card's default state is not a new learning action.
    await _captureSyncReplica();
    var changed = 0;
    for (final snapshot in remote) {
      final bookData = snapshot.book;
      final id = bookData['id']?.toString() ?? '';
      if (id.isEmpty || id == 'default') continue;
      final cardById = <int, Map<String, dynamic>>{
        for (final card in snapshot.cards)
          if ((card['id'] as num?)?.toInt() != null)
            (card['id'] as num).toInt(): card,
      };
      final order = (bookData['wordOrder'] as List? ?? const [])
          .whereType<num>()
          .map((value) => value.toInt())
          .toList();
      final orderedCards = order.isEmpty
          ? (cardById.keys.toList()..sort())
          : order.where(cardById.containsKey).toList();
      final index = books.indexWhere((book) => book.id == id);
      final oldStates = index < 0
          ? const <int, Word>{}
          : <int, Word>{for (final word in books[index].words) word.id: word};
      final words = <Word>[];
      for (final wordId in orderedCards) {
        final card = cardById[wordId]!;
        final old = oldStates[wordId];
        final word = Word(
          id: wordId,
          term: card['term']?.toString() ?? '',
          reading: card['reading']?.toString() ?? '',
          meaning: card['meaning']?.toString() ?? '',
          example: card['example']?.toString() ?? '',
          exampleMeaning: card['exampleMeaning']?.toString() ?? '',
          explanation: card['explanation']?.toString() ?? '',
          isFavorite: card['isFavorite'] == true,
          favoriteUpdatedAt: old?.favoriteUpdatedAt,
        );
        if (old != null) {
          word.state = old.state;
          word.correctCount = old.correctCount;
          word.wrongCount = old.wrongCount;
          word.lastStudiedAt = old.lastStudiedAt;
          word.lastWrongAt = old.lastWrongAt;
          word.isFavorite = old.isFavorite;
        }
        if (old == null) _restoreDownloadedCardLearning(word, id);
        _overlayPendingCardFields(word, id);
        // Keep a live route's references attached to the canonical card.
        if (old != null) {
          old.term = word.term;
          old.reading = word.reading;
          old.meaning = word.meaning;
          old.example = word.example;
          old.exampleMeaning = word.exampleMeaning;
          old.explanation = word.explanation;
        }
        words.add(old ?? word);
      }
      final overrides = <int, SessionOverride>{};
      final rawOverrides = bookData['sessionOverrides'];
      if (rawOverrides is Map) {
        rawOverrides.forEach((key, value) {
          final parsed = int.tryParse(key.toString());
          if (parsed != null && value is Map) {
            overrides[parsed] = SessionOverride.fromJson(
              Map<String, dynamic>.from(value),
            );
          }
        });
      }
      final decoded = WordBook(
        id: id,
        name: bookData['name']?.toString() ?? '단어장',
        isFavorite: bookData['isFavorite'] == true,
        words: words,
        sessionOverrides: overrides,
      );
      if (index < 0) {
        books.add(decoded);
      } else {
        books[index] = decoded;
      }
      changed++;
    }
    if (changed > 0) {
      await _saveBooks();
      // Seed previously unseen cards at clock zero, and accept the hydrated
      // view without re-authoring existing server learning records.
      _replica?.seed(_syncValues());
      await _captureSyncReplica();
      wordSearch.invalidate();
      cardContentRevision.value++;
    }
    return changed;
  }

  /// Incremental changes from another device.  They never enter the local
  /// outgoing queue, so simply opening a second phone cannot echo a server
  /// update back as a new user edit.
  Future<int> applyCardBookChanges(
    String bookId,
    Iterable<CardBookChange> changes,
  ) =>
      runLocalMutation(() => _applyCardBookChanges(bookId, changes));

  Future<int> _applyCardBookChanges(
      String bookId, Iterable<CardBookChange> changes) async {
    final bookIndex = books.indexWhere((book) => book.id == bookId);
    if (bookIndex < 0) return 0;
    final book = books[bookIndex];
    var applied = 0;
    for (final change in changes) {
      final index = book.words.indexWhere((word) => word.id == change.wordId);
      if (index < 0) continue;
      final old = book.words[index];
      final data = change.fields;
      if (data.containsKey('term')) old.term = data['term'].toString();
      if (data.containsKey('reading')) old.reading = data['reading'].toString();
      if (data.containsKey('meaning')) old.meaning = data['meaning'].toString();
      if (data.containsKey('example')) old.example = data['example'].toString();
      if (data.containsKey('exampleMeaning'))
        old.exampleMeaning = data['exampleMeaning'].toString();
      if (data.containsKey('explanation'))
        old.explanation = data['explanation'].toString();
      _overlayPendingCardFields(old, bookId);
      applied++;
    }
    if (applied > 0) {
      await _saveBooks();
      wordSearch.invalidate();
      cardContentRevision.value++;
    }
    return applied;
  }

  /// Applies an account-level tombstone without putting a competing write back
  /// into the book-content queue. The active study is tombstoned as well, so a
  /// deleted book cannot reopen from an old local queue.
  Future<int> _applyRemoteBookDeletions(Iterable<String> ids) async {
    var removed = 0;
    for (final id in ids.toSet()) {
      if (id == 'default' || !books.any((book) => book.id == id)) continue;
      final wasSelected = quickBook.id == id;
      final studyKeys = activeStudies.entries
          .where((entry) => entry.value.bookId == id)
          .map((entry) => entry.key)
          .toList();
      for (final key in studyKeys) {
        await clearActiveStudyFor(key, markCloudChange: false);
      }
      books.removeWhere((book) => book.id == id);
      if (wasSelected) await selectQuickBook('default');
      removed++;
    }
    if (removed > 0) await cloudChanges.markLearningState();
    return removed;
  }

  Future<void> mark(
    Word word,
    StudyState state, {
    bool recordAttempt = true,
    String? bookId,
    List<int> sessionIndexes = const [],
    String? decisionId,
    ActiveStudy? activeStudy,
  }) =>
      runLocalMutation(() async {
        if (_prefs.containsKey(_localDecisionKey))
          await _recoverLocalDecision();
        try {
          await _mark(word, state,
              recordAttempt: recordAttempt,
              bookId: bookId,
              sessionIndexes: sessionIndexes,
              decisionId: decisionId,
              activeStudy: activeStudy);
        } finally {
          _decisionEventPrefix = null;
        }
      });

  Future<void> _mark(Word word, StudyState state,
      {bool recordAttempt = true,
      String? bookId,
      List<int> sessionIndexes = const [],
      String? decisionId,
      ActiveStudy? activeStudy,
      DateTime? decisionTime}) async {
    final candidates = books
        .where((book) =>
            (bookId == null || book.id == bookId) &&
            book.words.any((item) => item.id == word.id))
        .toList();
    if (candidates.length != 1) throw StateError('학습할 카드를 정확히 찾을 수 없습니다.');
    bookId = candidates.single.id;
    word = resolveCard(bookId, word.id)!;
    final now = decisionTime ?? DateTime.now();
    decisionId ??= '${now.microsecondsSinceEpoch}:$bookId:${word.id}';
    final receiptKey =
        'localDecisionReceipts.${_activeAccountId ?? _prefs.getString(_lastActiveAccountKey) ?? 'local'}';
    final receipts = _prefs.getStringList(receiptKey) ?? [];
    if (recordAttempt && receipts.contains(decisionId)) return;
    final journalKey = _localDecisionKey;
    final attemptId = '${await cloudChanges.deviceId()}:$decisionId';
    _decisionEventPrefix = recordAttempt ? attemptId : null;
    _decisionEventSequence = 0;
    if (recordAttempt) {
      final before = <String, dynamic>{
        for (final key in [
          _studyDaysKey,
          _activeStudiesKey,
          _activeStudyKey,
          _activeStudyTombstonesKey,
          _completedKey,
          _completedAtKey,
          _coursePassesKey,
          _syncCompletedKey,
          receiptKey
        ])
          key: _prefs.get(key),
      };
      final journal = {
        'bookId': bookId,
        'word': word.toJson(),
        'state': state.name,
        'id': decisionId,
        'at': now.toIso8601String(),
        'sessions': sessionIndexes,
        'active': activeStudy?.toJson(),
        'before': before,
        'attempt': {
          'id': attemptId,
          'day': _dayKey(now),
          'dailyBefore': dailyStudyStats[_dayKey(now)]?.toJson(),
        }
      };
      if (!await _prefs.setString(journalKey, jsonEncode(journal))) {
        throw StateError('학습 판정을 기기에 보관하지 못했습니다.');
      }
    }
    final beforeState = word.state;
    final beforeCorrect = word.correctCount;
    final beforeWrong = word.wrongCount;
    final beforeLastStudiedAt = word.lastStudiedAt;
    final beforeLastWrongAt = word.lastWrongAt;
    final recoveryId = decisionId;
    if (recordAttempt) {
      // Write the inverse data before mutating the word. If the process dies
      // during this decision, this record is enough to restore the card.
      await cloudChanges.recordDiagnostic('study_decision_prepared', data: {
        'recoveryId': recoveryId,
        'bookId': bookId,
        'wordId': word.id,
        'term': word.term,
        'reading': word.reading,
        'decision': state.name,
        'beforeState': beforeState.name,
        'beforeCorrectCount': beforeCorrect,
        'beforeWrongCount': beforeWrong,
        'beforeLastStudiedAt': beforeLastStudiedAt?.toIso8601String(),
        'beforeLastWrongAt': beforeLastWrongAt?.toIso8601String(),
        'sessionIndexes': sessionIndexes,
      });
    }
    word.state = state;
    if (recordAttempt) {
      word.lastStudiedAt = now;
      if (state == StudyState.memorized) {
        word.correctCount++;
      } else if (state == StudyState.review) {
        word.wrongCount++;
        word.lastWrongAt = now;
      }
      await _recordStudyAttempt(
        word: word,
        decision: state,
        bookId: bookId,
        sessionIndexes: sessionIndexes,
        now: now,
        previousState: beforeState,
        previousCorrectCount: beforeCorrect,
        previousWrongCount: beforeWrong,
        previousLastStudiedAt: beforeLastStudiedAt,
        previousLastWrongAt: beforeLastWrongAt,
        operationId: attemptId,
      );
    }
    await _saveBooks();
    if (recordAttempt && activeStudy != null) {
      await saveActiveStudyFor(activeStudyKey(activeStudy), activeStudy,
          markCloudChange: false);
      if (activeStudy.queueIds.isEmpty &&
          activeStudy.memorized >= activeStudy.total) {
        if (activeStudy.isRangeCourse && activeStudy.bookId != null) {
          await completeRangeCourse(activeStudy.bookId!,
              activeStudy.rangeStart!, activeStudy.rangeEnd!);
        } else if (activeStudy.sessionSelections.isNotEmpty) {
          for (final selection in activeStudy.sessionSelections.entries) {
            await completeSessions(selection.key, selection.value);
          }
        } else if (activeStudy.bookId != null &&
            activeStudy.sessionIndexes.isNotEmpty) {
          await completeSessions(
              activeStudy.bookId!, activeStudy.sessionIndexes);
        } else {
          await completeCurrentSession();
        }
        await clearActiveStudyFor(activeStudyKey(activeStudy));
      }
    }
    if (recordAttempt) {
      await cloudChanges.markLearningState();
      await cloudChanges.recordDiagnostic('card_decision_committed', data: {
        'recoveryId': recoveryId,
        'bookId': bookId,
        'wordId': word.id,
        'term': word.term,
        'reading': word.reading,
        'decision': state.name,
        'beforeState': beforeState.name,
        'afterState': word.state.name,
        'beforeCorrectCount': beforeCorrect,
        'afterCorrectCount': word.correctCount,
        'beforeWrongCount': beforeWrong,
        'afterWrongCount': word.wrongCount,
        'sessionIndexes': sessionIndexes,
      });
      await _prefs.setStringList(
          receiptKey,
          [...receipts, decisionId]
              .reversed
              .take(256)
              .toList()
              .reversed
              .toList());
      await _prefs.remove(journalKey);
    }
  }

  String get _localDecisionKey =>
      'learning.localDecision.${_activeAccountId ?? _prefs.getString(_lastActiveAccountKey) ?? 'local'}';

  Future<void> _recoverLocalDecision() async {
    final encoded = _prefs.getString(_localDecisionKey);
    if (encoded == null) return;
    final request = Map<String, dynamic>.from(jsonDecode(encoded));
    final bookId = request['bookId'] as String;
    final beforeWord =
        Word.fromJson(Map<String, dynamic>.from(request['word']));
    final canonical = resolveCard(bookId, beforeWord.id);
    if (canonical == null) throw StateError('미완료 학습 기록의 카드를 찾을 수 없습니다.');
    final before = Map<String, dynamic>.from(request['before']);
    for (final entry in before.entries) {
      await _setSharedPreference(entry.key, entry.value);
    }
    canonical.state = beforeWord.state;
    canonical.correctCount = beforeWord.correctCount;
    canonical.wrongCount = beforeWord.wrongCount;
    canonical.lastStudiedAt = beforeWord.lastStudiedAt;
    canonical.lastWrongAt = beforeWord.lastWrongAt;
    _dailyStudyStatsCache = null;
    _studyEventLogCache = null;
    _activeStudiesCache = null;
    _activeStudyTombstonesCache = null;
    _completedAtCache = null;
    final attempt = request['attempt'];
    if (attempt is Map) {
      final day = attempt['day'] as String;
      final stats = Map<String, DailyStudyStats>.from(dailyStudyStats);
      if (attempt['dailyBefore'] == null) {
        stats.remove(day);
      } else {
        stats[day] = DailyStudyStats.fromJson(
            Map<String, dynamic>.from(attempt['dailyBefore']));
      }
      await _saveDailyStudyStats(stats);
      await _saveStudyEventLog(
          studyEventLog.where((entry) => entry.id != attempt['id']).toList());
      final events = _readSyncMap(_syncEventsKey)
        ..removeWhere((key, value) =>
            key == attempt['id'] || key.startsWith('${attempt['id']}:side:'));
      await _prefs.setString(_syncEventsKey, jsonEncode(events));
    }
    try {
      await _mark(
          canonical, StudyState.values.byName(request['state'] as String),
          bookId: bookId,
          decisionId: request['id'] as String,
          decisionTime: DateTime.parse(request['at'] as String),
          sessionIndexes: (request['sessions'] as List).cast<int>(),
          activeStudy: request['active'] == null
              ? null
              : ActiveStudy.fromJson(
                  Map<String, dynamic>.from(request['active'])));
    } finally {
      _decisionEventPrefix = null;
    }
  }

  Future<void> recoverLocalDecision() =>
      runLocalMutation(_recoverLocalDecision);

  Future<void> completeCurrentSession() async {
    final completedIndex = nextSessionIndex(quickBook);
    final completed = (_prefs.getStringList(_completedKey) ?? []).toSet();
    final completedKey = '${quickBook.id}:$completedIndex';
    completed.add(completedKey);
    await _prefs.setStringList(_completedKey, completed.toList());
    await _rememberCompletedMembership();
    final completedTimes = Map<String, DateTime>.from(completedAt);
    final now = DateTime.now();
    completedTimes[completedKey] = now;
    await _saveCompletedAt(completedTimes);
    await _recordCompletedSessions(now, 1);
    final days = (_prefs.getStringList(_studyDaysKey) ?? []).toSet()
      ..add(_dayKey(DateTime.now()));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await _clearActiveStudiesForSessions(quickBook.id, {completedIndex});
    await _recordCompletionRecoveryCheckpoint(
      reason: 'current_session_completed',
      bookId: quickBook.id,
      sessionIndexes: [completedIndex],
    );
    await cloudChanges.markLearningState();
    unawaited(cloudChanges.recordDiagnostic('session_completed', data: {
      'bookId': quickBook.id,
      'sessionIndex': completedIndex,
      'completedCount': completed.length,
    }));
    onSessionCompleted?.call();
  }

  Future<void> resetProgress() async {
    await _markReset('all');
    await _prefs.remove(_syncCompletedKey);
    for (final book in books) {
      for (final word in book.words) {
        word.state = StudyState.fresh;
        word.correctCount = 0;
        word.wrongCount = 0;
        word.lastStudiedAt = null;
        word.lastWrongAt = null;
      }
    }
    await _prefs.remove(_completedKey);
    _completedAtCache = const {};
    _dailyStudyStatsCache = const {};
    _studyEventLogCache = const [];
    await _prefs.remove(_completedAtKey);
    await _prefs.remove(_studyDaysKey);
    await _prefs.remove(_dailyStudyStatsKey);
    await _prefs.remove(_studyEventLogKey);
    await _prefs.remove(_coursePassesKey);
    await _prefs.remove(_syncDailyBaseKey);
    await _prefs.remove(_syncEventsKey);
    await clearAllActiveStudies(markCloudChange: false);
    await _saveBooks();
    await cloudChanges.markLearningState();
  }

  /// A card-content-free snapshot. Only learning metadata is sent to the
  /// dedicated learningState collection; Firebase words remain read-only.
  Map<String, dynamic> toLearningStateJson() => {
        'bookOrder': {
          'ids': books.map((book) => book.id).toList(),
          'updatedAt': _prefs.getString(_bookOrderUpdatedAtKey),
        },
        'schema': 1,
        'wordStates': {
          for (final book in books)
            book.id: {
              for (final word in book.words)
                word.id.toString(): {
                  'state': word.state.name,
                  'correctCount': word.correctCount,
                  'wrongCount': word.wrongCount,
                  'lastStudiedAt': word.lastStudiedAt?.toIso8601String(),
                  'lastWrongAt': word.lastWrongAt?.toIso8601String(),
                },
            },
        },
        'completed': _prefs.getStringList(_completedKey) ?? <String>[],
        'completedAt': completedAt.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
        'rangeCoursePasses': coursePasses,
        'studyDays': _prefs.getStringList(_studyDaysKey) ?? <String>[],
        'dailyStudyStats': dailyStudyStats.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'studyEventLog': _prunedStudyEventLog(studyEventLog)
            .map((event) => event.toJson())
            .toList(),
        'activeStudies':
            activeStudies.map((key, value) => MapEntry(key, value.toJson())),
        'activeStudyTombstones': activeStudyTombstones.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
        'resetMarkers': resetMarkers.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
      };

  /// Applies the union of this phone's and every other phone's dedicated
  /// learning snapshots. No word text field is read from or written to here.
  Future<void> applyLearningStateSnapshots(
      Iterable<Map<String, dynamic>> snapshots) async {
    if (snapshots.any(
        (snapshot) => snapshot['schema'] == 2 && snapshot['records'] is Map)) {
      await applySyncV2(snapshots.where((snapshot) => snapshot['schema'] == 2));
      return;
    }
    final remoteSnapshotCount = snapshots.length;
    final all = [toLearningStateJson(), ...snapshots];
    var bookOrderDate =
        DateTime.tryParse(_prefs.getString(_bookOrderUpdatedAtKey) ?? '');
    List<String>? newestBookOrder;
    for (final snapshot in snapshots) {
      final order = snapshot['bookOrder'];
      if (order is! Map || order['ids'] is! List) continue;
      final date = DateTime.tryParse(order['updatedAt']?.toString() ?? '');
      if (date == null ||
          (bookOrderDate != null && !date.isAfter(bookOrderDate))) {
        continue;
      }
      newestBookOrder = (order['ids'] as List)
          .map((id) => id.toString())
          .toList(growable: false);
      bookOrderDate = date;
    }
    if (newestBookOrder != null) {
      final byId = {for (final book in books) book.id: book};
      final reordered = <WordBook>[];
      for (final id in newestBookOrder) {
        final book = byId.remove(id);
        if (book != null) reordered.add(book);
      }
      // Keep offline-only books visible after the known remote order.
      reordered.addAll(books.where((book) => byId.containsKey(book.id)));
      if (!listEquals(books.map((book) => book.id).toList(),
          reordered.map((book) => book.id).toList())) {
        books = reordered;
      }
      await _prefs.setString(
          _bookOrderUpdatedAtKey, bookOrderDate!.toUtc().toIso8601String());
    }
    final reset = <String, DateTime>{};
    final tombstones = <String, DateTime>{};
    final completed = <String>{};
    final completedTimes = <String, DateTime>{};
    final passes = <String, int>{};
    final days = <String>{};
    final stats = <String, DailyStudyStats>{};
    final events = <String, StudyEventLog>{};
    final activeCandidates = <String, List<Map<String, dynamic>>>{};

    DateTime? asDate(dynamic raw) =>
        raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    void latestInto(Map<String, DateTime> target, dynamic raw) {
      if (raw is! Map) return;
      raw.forEach((key, value) {
        final date = asDate(value);
        final old = target[key.toString()];
        if (date != null && (old == null || date.isAfter(old)))
          target[key.toString()] = date;
      });
    }

    for (final snapshot in all) {
      latestInto(reset, snapshot['resetMarkers']);
      latestInto(tombstones, snapshot['activeStudyTombstones']);
      completed.addAll((snapshot['completed'] as List<dynamic>? ?? const [])
          .map((item) => item.toString()));
      latestInto(completedTimes, snapshot['completedAt']);
      final rawPasses = snapshot['rangeCoursePasses'];
      if (rawPasses is Map)
        rawPasses.forEach((key, value) {
          final count = (value as num?)?.toInt() ?? 0;
          if (count > (passes[key.toString()] ?? 0))
            passes[key.toString()] = count;
        });
      days.addAll((snapshot['studyDays'] as List<dynamic>? ?? const [])
          .map((item) => item.toString()));
      final rawStats = snapshot['dailyStudyStats'];
      if (rawStats is Map)
        rawStats.forEach((key, value) {
          if (value is! Map) return;
          final incoming =
              DailyStudyStats.fromJson(Map<String, dynamic>.from(value));
          final current = stats[key.toString()] ?? const DailyStudyStats();
          stats[key.toString()] = DailyStudyStats(
            studiedCards: current.studiedCards > incoming.studiedCards
                ? current.studiedCards
                : incoming.studiedCards,
            completedSessions:
                current.completedSessions > incoming.completedSessions
                    ? current.completedSessions
                    : incoming.completedSessions,
            correctCount: current.correctCount > incoming.correctCount
                ? current.correctCount
                : incoming.correctCount,
            wrongCount: current.wrongCount > incoming.wrongCount
                ? current.wrongCount
                : incoming.wrongCount,
          );
        });
      for (final raw
          in snapshot['studyEventLog'] as List<dynamic>? ?? const []) {
        if (raw is! Map) continue;
        final event = StudyEventLog.fromJson(Map<String, dynamic>.from(raw));
        final old = events[event.id];
        if (old == null || event.timestamp.isAfter(old.timestamp))
          events[event.id] = event;
      }
      final rawActive = snapshot['activeStudies'];
      if (rawActive is Map)
        rawActive.forEach((key, value) {
          if (value is Map)
            activeCandidates
                .putIfAbsent(key.toString(), () => [])
                .add(Map<String, dynamic>.from(value));
        });
    }

    for (final snapshot in all) {
      final rawBooks = snapshot['wordStates'];
      if (rawBooks is! Map) continue;
      for (final book in books) {
        final rawWords = rawBooks[book.id];
        if (rawWords is! Map) continue;
        for (final word in book.words) {
          final raw = rawWords[word.id.toString()];
          if (raw is! Map) continue;
          final state = StudyState.values.firstWhere(
              (item) => item.name == raw['state'],
              orElse: () => StudyState.fresh);
          if (_studyStateRank(state) > _studyStateRank(word.state))
            word.state = state;
          word.correctCount =
              word.correctCount > ((raw['correctCount'] as num?)?.toInt() ?? 0)
                  ? word.correctCount
                  : ((raw['correctCount'] as num?)?.toInt() ?? 0);
          word.wrongCount =
              word.wrongCount > ((raw['wrongCount'] as num?)?.toInt() ?? 0)
                  ? word.wrongCount
                  : ((raw['wrongCount'] as num?)?.toInt() ?? 0);
          final studied = asDate(raw['lastStudiedAt']);
          if (studied != null &&
              (word.lastStudiedAt == null ||
                  studied.isAfter(word.lastStudiedAt!)))
            word.lastStudiedAt = studied;
          final wrong = asDate(raw['lastWrongAt']);
          if (wrong != null &&
              (word.lastWrongAt == null || wrong.isAfter(word.lastWrongAt!)))
            word.lastWrongAt = wrong;
        }
      }
    }

    final chosenStudies = <String, ActiveStudy>{};
    activeCandidates.forEach((key, values) {
      values.sort((a, b) {
        // A newer session or undo must not lose to older, higher progress.
        final at =
            asDate(a['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt =
            asDate(b['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final recency = bt.compareTo(at);
        if (recency != 0) return recency;
        final memorized = ((b['memorized'] as num?)?.toInt() ?? 0)
            .compareTo((a['memorized'] as num?)?.toInt() ?? 0);
        if (memorized != 0) return memorized;
        final queue = ((a['queueIds'] as List?)?.length ?? 999999)
            .compareTo((b['queueIds'] as List?)?.length ?? 999999);
        if (queue != 0) return queue;
        return jsonEncode(a).compareTo(jsonEncode(b));
      });
      final chosen = ActiveStudy.fromJson(values.first);
      final deletedAt = tombstones[key];
      final startedAt = chosen.startedAt ?? chosen.updatedAt;
      if (deletedAt == null ||
          startedAt == null ||
          !deletedAt.isAfter(startedAt)) {
        chosenStudies[key] = chosen;
      }
    });

    await _saveBooks();
    wordSearch.invalidate();
    await _prefs.setStringList(_completedKey, completed.toList());
    await _saveCompletedAt(completedTimes);
    await _prefs.setString(_coursePassesKey, jsonEncode(passes));
    await _prefs.setStringList(_studyDaysKey, days.toList());
    await _saveDailyStudyStats(stats);
    await _saveStudyEventLog(_prunedStudyEventLog(events.values.toList()));
    await _saveActiveStudies(chosenStudies);
    await _saveActiveStudyTombstones(tombstones);
    await _saveResetMarkers(reset);
    learningStateRevision.value++;
    unawaited(cloudChanges.recordDiagnostic('learning_state_merged', data: {
      'remoteSnapshotCount': remoteSnapshotCount,
      'completedSessionCount': completed.length,
      'activeStudyCount': chosenStudies.length,
      'activeStudyKeys': chosenStudies.keys.toList(),
      'studyDayCount': days.length,
      'eventCount': events.length,
    }));
  }

  int _studyStateRank(StudyState state) => switch (state) {
        StudyState.fresh => 0,
        StudyState.review => 1,
        StudyState.memorized => 2,
      };
  Map<String, dynamic> toBackupJson() => {
        'version': 4,
        'rangeCourseSchema': rangeCourseSchemaVersion,
        'rangeCoursePasses': coursePasses,
        'books': books.map((book) => book.toJson()).toList(),
        'quickBook': _prefs.getString(_quickBookKey) ?? 'default',
        'sessionSize': sessionSize,
        'completed': _prefs.getStringList(_completedKey) ?? <String>[],
        'completedAt': completedAt.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
        'studyDays': _prefs.getStringList(_studyDaysKey) ?? <String>[],
        'dailyStudyStats': dailyStudyStats.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        'studyEventLog': _prunedStudyEventLog(studyEventLog)
            .map((event) => event.toJson())
            .toList(),
        'targetName': targetName,
        'targetDate': _prefs.getString(_targetDateKey),
        'horizontalSwipe': horizontalSwipe,
        'reverseSwipe': reverseSwipe,
        'readingAboveTerm': readingAboveTerm,
        'showExamples': showExamples,
        'flipCard': flipCard,
        'autoPlayPronunciation': autoPlayPronunciation,
        'undoHaptics': undoHaptics,
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
        'openDictionaryInAppSetting': openDictionaryInAppSettingJson,
        'activeStudy': activeStudy?.toJson(),
        'activeStudies': activeStudies.map((k, v) => MapEntry(k, v.toJson())),
        'activeStudyTombstones': activeStudyTombstones.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
        'resetMarkers': resetMarkers.map(
          (key, value) => MapEntry(key, value.toIso8601String()),
        ),
      };

  Future<void> replaceWithBackupJson(Map<String, dynamic> json) async {
    _activeStudiesCache = const {};
    _activeStudyTombstonesCache = const {};
    await _prefs.remove(_activeStudyKey);
    await _prefs.remove(_activeStudiesKey);
    await _prefs.remove(_activeStudyTombstonesKey);
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
    await _prefs.setString(
      _coursePassesKey,
      jsonEncode(
          json['rangeCoursePasses'] as Map<String, dynamic>? ?? const {}),
    );
    await _saveCompletedAt(
      (json['completedAt'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          DateTime.tryParse(value as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ),
    );
    await _prefs.setStringList(
      _studyDaysKey,
      (json['studyDays'] as List<dynamic>? ?? []).cast<String>(),
    );
    await _saveDailyStudyStats(
      (json['dailyStudyStats'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          DailyStudyStats.fromJson(
              Map<String, dynamic>.from(value as Map<dynamic, dynamic>)),
        ),
      ),
    );
    await _saveStudyEventLog(_prunedStudyEventLog(
      (json['studyEventLog'] as List<dynamic>? ?? const [])
          .map((item) => StudyEventLog.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .toList(),
    ));
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
    await _prefs.setBool(_autoPlayPronunciationKey,
        json['autoPlayPronunciation'] as bool? ?? true);
    await _prefs.setBool(
        _undoHapticsKey, json['undoHaptics'] as bool? ?? false);
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

    await _saveResetMarkers(
      (json['resetMarkers'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          DateTime.tryParse(value as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ),
    );
    await _saveActiveStudyTombstones(
      (json['activeStudyTombstones'] as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          DateTime.tryParse(value as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ),
    );
    final targetDate = json['targetDate'] as String?;
    if (targetDate == null || DateTime.tryParse(targetDate) == null) {
      await _prefs.remove(_targetDateKey);
    } else {
      await _prefs.setString(_targetDateKey, targetDate);
    }
    final dictionarySetting = json['openDictionaryInAppSetting'];
    if (dictionarySetting is Map) {
      await applyOpenDictionaryInAppSettingFromCloud(
        Map<String, dynamic>.from(dictionarySetting),
      );
    }
    await restoreActiveStudyFromBackupJson(json);
  }

  ActiveStudy? _activeStudyFromBackupJson(dynamic value) {
    if (value is! Map) return null;
    try {
      final active = ActiveStudy.fromJson(Map<String, dynamic>.from(value));
      if (active.isRangeCourse &&
          active.rangeCourseSchema < rangeCourseSchemaVersion) {
        return null;
      }
      return active.queueIds.isEmpty ? null : active;
    } catch (_) {
      return null;
    }
  }

  List<WordBook> _loadBooks() {
    final saved = _prefs.getString(_booksKey);
    return _decodeBooks(saved);
  }

  List<WordBook> _decodeBooks(String? saved) {
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

  String _encodeBooks() =>
      jsonEncode(books.map((book) => book.toJson()).toList());

  Future<void> _saveBooks() async {
    final encoded = _encodeBooks();
    if (!await _prefs.setString(_booksKey, encoded)) {
      throw StateError('기기에 단어장과 학습 상태를 저장하지 못했습니다.');
    }
    // The root preference is already the durable, live account state.  Its
    // account snapshot is refreshed before an account switch and before a
    // cloud sync checkpoint; doing it for every card decision created a full
    // 2,500-word JSON snapshot on the interaction path.
  }

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

  /// Repairs an older import bug where rows without a dedicated Japanese
  /// reading were stored as `meaning: ㆍ, reading: <Korean meaning>`.
  ///
  /// The import contract uses the Japanese term itself as the reading in this
  /// case.  Keep the word ID and every learning field intact so study history,
  /// session progress, and cloud merge identities are preserved.
  Future<void> _repairPlaceholderReadingMeaningFields() async {
    if (_prefs.getBool(_placeholderReadingMeaningMigrationKey) ?? false) {
      return;
    }
    final changedWords = <String, List<int>>{};
    final japaneseText = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');
    final hangulText = RegExp(r'[가-힣]');
    for (final book in books) {
      for (var index = 0; index < book.words.length; index++) {
        final word = book.words[index];
        if (word.meaning.trim() != 'ㆍ' ||
            !hangulText.hasMatch(word.reading) ||
            !japaneseText.hasMatch(word.term)) {
          continue;
        }
        book.words[index] = word.copyWith(
          reading: word.term,
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
    await _prefs.setBool(_placeholderReadingMeaningMigrationKey, true);
  }

  /// Applies only individually source-verified N1 corrections. A correction
  /// that changes Japanese spelling or reading preserves a learner's meaning
  /// notes verbatim: once the known erroneous term/reading pair is present,
  /// only that objectively wrong Japanese field is normalized. Meaning edits
  /// still require the complete original card text.
  Future<void> _applyVerifiedTextCorrections() async {
    if (_prefs.getBool(_verifiedTextCorrectionMigrationKey) ?? false) return;
    const repairs = <Map<String, String>>[
      {
        'term': '跡地',
        'reading': 'あとち',
        'meaning': '철거부지, 잔해',
        'newMeaning': '이전 터, 철거지'
      },
      {
        'term': '表向き',
        'reading': 'おもてむき',
        'meaning': '표면화함',
        'newMeaning': '겉으로는, 표면상'
      },
      {
        'term': '自ら',
        'reading': 'みずから',
        'meaning': '자기',
        'newMeaning': '스스로, 몸소'
      },
      {
        'term': '巡り',
        'reading': 'めぐり',
        'meaning': '한바퀴 돎, 여기저기 돌름, 순례',
        'newMeaning': '돌아다님, 순환'
      },
      {
        'term': '(改訂)版',
        'reading': '(かいてい)はん',
        'meaning': '(개정)판',
        'newReading': '(かいてい)ばん'
      },
      {
        'term': '気掛かり',
        'reading': 'きかかり',
        'meaning': '걱정, 마음에 걸림',
        'newReading': 'きがかり'
      },
      {
        'term': '食い止める',
        'reading': 'くいやめる',
        'meaning': '저지하다',
        'newReading': 'くいとめる'
      },
      {
        'term': '煙たい',
        'reading': 'けむたい',
        'meaning': '냄다, 맵고 싸하다',
        'newMeaning': '맵고 싸하다, (대하기) 어렵다'
      },
      {
        'term': '(情報)網',
        'reading': '(じょうほう)あみ',
        'meaning': '(정보)망',
        'newReading': '(じょうほう)もう'
      },
      {
        'term': '尻急',
        'reading': 'しりきゅう',
        'meaning': '응급',
        'newTerm': '応急',
        'newReading': 'おうきゅう'
      },
      {
        'term': '猛(反対)',
        'reading': 'たけし(はんたい)',
        'meaning': '맹(반대)',
        'newReading': 'もう(はんたい)'
      },
      {
        'term': '楽観的',
        'reading': 'らくかんてき',
        'meaning': '낙관적',
        'newReading': 'らっかんてき'
      },
      {
        'term': '[歴史]上',
        'reading': '[れきし]うえ',
        'meaning': '(역사상)',
        'newReading': '[れきし]じょう'
      },
      {
        'term': '目ずと',
        'reading': 'めずと',
        'meaning': '자연스레',
        'newTerm': '自ずと',
        'newReading': 'おのずと'
      },
      {
        'term': '今までになく新しい',
        'reading': 'いままでになくあたらしい',
        'meaning': '지금까지 없이 새로운',
        'newMeaning': '지금까지 없을 만큼 새로운'
      },
      {
        'term': '口数が少ない',
        'reading': 'くちすうがすくない',
        'meaning': '말수가 적은',
        'newReading': 'くちかずがすくない'
      },
      {
        'term': '気掛かり',
        'reading': 'きかかり',
        'meaning': '걱정',
        'newReading': 'きがかり'
      },
      {
        'term': 'つかの間',
        'reading': 'つかのかん',
        'meaning': '잠깐 동안, 순간',
        'newReading': 'つかのま'
      },
      {
        'term': '脈略',
        'reading': 'みゃくりゃく',
        'meaning': '맥락',
        'newReading': 'みゃくらく'
      },
      {
        'term': 'くまなく',
        'reading': 'くまなく',
        'meaning': '분명히, 뚜렷하게, 빠짐없이',
        'newMeaning': '구석구석, 빠짐없이'
      },
      {
        'term': '～だって',
        'reading': '～だって',
        'meaning': '①~도, ~라도, ~조차도 ②~도 또한 ③~라던대 ④(아무리)~해도, ~하더라도',
        'newMeaning': '①~도, ~라도, ~조차도 ②~도 또한 ③~라던데 ④(아무리)~해도, ~하더라도'
      },
    ];
    final changedWords = <String, List<int>>{};
    for (final book in books) {
      for (var index = 0; index < book.words.length; index++) {
        final word = book.words[index];
        final repair = repairs.where((candidate) {
          if (candidate['term'] != word.term ||
              candidate['reading'] != word.reading) {
            return false;
          }
          final formOnlyCorrection = candidate['newMeaning'] == null &&
              (candidate['newTerm'] != null || candidate['newReading'] != null);
          if (formOnlyCorrection) return true;
          final expectedMeaning = candidate['meaning'];
          return expectedMeaning == null || expectedMeaning == word.meaning;
        }).firstOrNull;
        if (repair == null) continue;
        book.words[index] = word.copyWith(
          term: repair['newTerm'],
          reading: repair['newReading'],
          meaning: repair['newMeaning'],
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
    await _prefs.setBool(_verifiedTextCorrectionMigrationKey, true);
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
