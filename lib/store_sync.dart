part of 'store.dart';

const _syncReplicaKey = 'sync.v2.replica';
const _syncDailyBaseKey = 'sync.v2.dailyBaseline';
const _syncEventsKey = 'sync.v2.events';
const _syncCompletedKey = 'sync.v2.completedMembership';
const _sharedPreferenceKeys = <String>[
  'quickBook',
  'sessionSize',
  'targetName',
  'targetDate',
  'horizontalSwipe',
  'reverseSwipe',
  'readingAboveTerm',
  'showExamples',
  'flipCard',
  'autoPlayPronunciation',
  'undoHaptics',
  'japaneseFont',
  'termFontSize',
  'readingFontSize',
  'meaningFontSize',
  'exampleFontSize',
  'exampleMeaningFontSize',
  'meaningFontWeight',
  'meaningOpacity',
  'chatGptConversationUrl',
  'chatGptWordPromptTemplate',
  'chatGptKanjiPromptTemplate',
  'openDictionaryInApp',
  'chatGptConversationUrlUpdatedAt',
  'chatGptPromptsUpdatedAt',
  'openDictionaryInAppUpdatedAt',
];

extension VocaStoreSync on VocaStore {
  bool get legacySyncImported =>
      _prefs.getBool('sync.v2.imported.${_activeAccountId ?? 'local'}') == true;

  Future<void> _restoreSyncCheckpoint(String uid) async {
    final saved = _prefs.getString('sync.v2.checkpoint.$uid');
    if (saved == null) return;
    final checkpoint = Map<String, dynamic>.from(jsonDecode(saved));
    final state = Map<String, dynamic>.from(checkpoint['state']);
    for (final key in VocaStore._accountScopedKeys) {
      final value = state[key];
      if (value is List) {
        await _prefs.setStringList(key, value.cast<String>());
      } else {
        await _setSharedPreference(key, value);
      }
    }
    await _prefs.setString(
        '${VocaStore._accountStatePrefix}$uid', jsonEncode(state));
    _activeAccountId = uid;
  }

  Map<String, dynamic> _readSyncMap(String key) {
    final raw = _prefs.getString(key);
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  String _membership(String bookId, Iterable<int> wordIds) =>
      jsonEncode([bookId, wordIds.toList()..sort()]);

  Future<void> _rememberCompletedMembership() async {
    final memberships = _readSyncMap(_syncCompletedKey);
    for (final book in books) {
      for (final session in book.sessions(sessionSize)) {
        if ((_prefs.getStringList(VocaStore._completedKey) ?? [])
            .contains('${book.id}:${session.index}')) {
          memberships[_membership(book.id, session.words.map((w) => w.id))] =
              true;
        }
      }
    }
    await _prefs.setString(_syncCompletedKey, jsonEncode(memberships));
  }

  Future<void> _projectCompletedMembership() async {
    final memberships = _readSyncMap(_syncCompletedKey);
    await _prefs.setStringList(VocaStore._completedKey, [
      for (final book in books)
        for (final session in book.sessions(sessionSize))
          if (memberships[
                  _membership(book.id, session.words.map((w) => w.id))] ==
              true)
            '${book.id}:${session.index}',
    ]);
  }

  Future<void> _loadSyncReplica() async {
    final replica = SyncReplica(await cloudChanges.deviceId());
    final saved = _prefs.getString(_syncReplicaKey);
    final hadSavedReplica = saved != null;
    if (hadSavedReplica) {
      replica.merge(Map<String, dynamic>.from(jsonDecode(saved)));
      replica.acceptView(replica.values);
    }
    if (_prefs.getString(_syncDailyBaseKey) == null) {
      await _prefs.setString(_syncDailyBaseKey,
          jsonEncode(dailyStudyStats.map((k, v) => MapEntry(k, v.toJson()))));
    }
    await _rememberCompletedMembership();
    _replica = replica;
    if (hadSavedReplica) {
      // A card may have been saved locally just before interruption. Recover
      // that difference without needing a disk write for every card tap.
      replica.capture(_syncValues());
    } else {
      replica.seed(_syncValues());
    }
    // A pre-migration snapshot is immutable and scoped to the adopted account.
    final backupKey = 'sync.v2.beforeMigration.${_activeAccountId ?? 'local'}';
    if (!_prefs.containsKey(backupKey)) {
      await _prefs.setString(backupKey, jsonEncode(toBackupJson()));
    }
    await _prefs.setString(_syncReplicaKey, jsonEncode(replica.toJson()));
  }

  Map<String, dynamic> _wordState(Word word) => {
        'state': word.state.name,
        'correctCount': word.correctCount,
        'wrongCount': word.wrongCount,
        'lastStudiedAt': word.lastStudiedAt?.toIso8601String(),
        'lastWrongAt': word.lastWrongAt?.toIso8601String(),
      };

  Map<String, dynamic> _syncValues() {
    final state = toLearningStateJson();
    return {
      for (final key in _sharedPreferenceKeys) 'setting/$key': _prefs.get(key),
      'bookOrder': books.map((b) => b.id).toList(),
      for (final raw
          in jsonDecode(_prefs.getString('wordRelations.v1') ?? '[]') as List)
        'relation/${raw['id']}': raw,
      for (final raw
          in jsonDecode(_prefs.getString('pronunciationSelections.v1') ?? '[]')
              as List)
        'pronunciation/${raw['bookId']}/${raw['wordId']}': raw,
      for (final book in books) ...{
        'bookFavorite/${book.id}': book.isFavorite,
        for (final word in book.words) ...{
          'word/${book.id}/${word.id}': _wordState(word),
          'favorite/${book.id}/${word.id}': word.isFavorite,
        },
      },
      for (final entry in activeStudies.entries)
        'session/${entry.key}': {
          'active': entry.value.toJson(),
          // Preserve the branch's touched card states alongside its queue.
          'words': {
            for (final decision in entry.value.undoHistory)
              for (final book in books.where(
                  (b) => b.id == (decision.bookId ?? entry.value.bookId)))
                for (final word
                    in book.words.where((w) => w.id == decision.wordId))
                  'word/${book.id}/${word.id}': _wordState(word),
          },
        },
      for (final entry in _readSyncMap(_syncCompletedKey).entries)
        'completed/${entry.key}': entry.value,
      for (final entry in coursePasses.entries)
        'passes/${entry.key}': entry.value,
      for (final entry in _readSyncMap(_syncDailyBaseKey).entries)
        'dailyBase/${entry.key}': entry.value,
      for (final entry in _readSyncMap(_syncEventsKey).entries)
        'event/${entry.key}': entry.value,
      for (final entry in resetMarkers.entries)
        'reset/${entry.key}': entry.value.toIso8601String(),
      for (final event in state['studyEventLog'] as List)
        'log/${event['id']}': event,
    };
  }

  Future<void> _captureSyncReplica({bool persist = false}) {
    if (_applyingReplica) return Future<void>.value();
    final task = _syncWork.then((_) async {
      final replica = _replica;
      if (replica == null) return;
      replica.capture(_syncValues());
      // Account switching must recover the just-finished local action even
      // before the next cloud upload.  Keep this compact local checkpoint
      // current, while reserving the larger replica JSON write for a flush.
      if (_activeAccountId != null) {
        await _saveAccountState(_activeAccountId!);
        await _writeSyncCheckpoint();
      }
      if (persist) {
        await _prefs.setString(_syncReplicaKey, jsonEncode(replica.toJson()));
      }
    });
    _syncWork = task.catchError((Object _) {});
    return task;
  }

  Future<void> _writeSyncCheckpoint() async {
    final data = <String, dynamic>{
      for (final key in VocaStore._accountScopedKeys)
        if (_prefs.get(key) != null) key: _prefs.get(key),
      VocaStore._booksKey: _encodeBooks(),
    };
    final account = _activeAccountId;
    if (account == null) return;
    await _prefs.setString(
        'sync.v2.checkpoint.$account',
        jsonEncode({
          'account': account,
          'state': data,
        }));
  }

  Future<Map<String, dynamic>> syncV2Snapshot() async {
    await _captureSyncReplica(persist: true);
    return jsonDecode(jsonEncode(_replica!.toJson())) as Map<String, dynamic>;
  }

  /// The legacy merge is used only once, before any version-2 remote merge.
  Future<void> importLegacyForSyncV2(
      List<Map<String, dynamic>> snapshots) async {
    final marker = 'sync.v2.imported.${_activeAccountId ?? 'local'}';
    if (_prefs.getBool(marker) == true) return;
    final before = await syncV2Snapshot();
    await _prefs.setString('$marker.backup', jsonEncode(snapshots));
    await applyLearningStateSnapshots(snapshots);
    await _rememberCompletedMembership();
    // Legacy totals are a baseline; new event deltas remain separate.
    final base = _readSyncMap(_syncDailyBaseKey);
    for (final snapshot in snapshots) {
      final stats = snapshot['dailyStudyStats'];
      if (stats is! Map) continue;
      for (final entry in stats.entries) {
        final day = Map<String, dynamic>.from(base[entry.key] as Map? ?? {});
        for (final count in (entry.value as Map).entries) {
          final n = (count.value as num).toInt();
          if (n > ((day[count.key] as num?)?.toInt() ?? 0))
            day[count.key.toString()] = n;
        }
        base[entry.key.toString()] = day;
      }
    }
    await _prefs.setString(_syncDailyBaseKey, jsonEncode(base));
    final migrated = SyncReplica(_replica!.deviceId)..seed(_syncValues());
    // Explicit new edits outrank imported legacy records.
    migrated.merge({
      ...before,
      'records': {
        for (final entry in (before['records'] as Map).entries)
          if ((entry.value['clock'] as num) > 0) entry.key: entry.value,
      }
    });
    _replica = migrated;
    await _applyReplicaValues();
    await _prefs.setBool(marker, true);
    await _captureSyncReplica();
  }

  Future<void> applySyncV2(Iterable<Map<String, dynamic>> snapshots) async {
    await beforeRemoteApply?.call();
    await _captureSyncReplica();
    final task = _syncWork.then((_) async {
      _applyingReplica = true;
      try {
        for (final snapshot in snapshots) _replica!.merge(snapshot);
        await _applyReplicaValues();
        await _prefs.setString(_syncReplicaKey, jsonEncode(_replica!.toJson()));
        if (_activeAccountId != null)
          await _saveAccountState(_activeAccountId!);
        await _writeSyncCheckpoint();
      } finally {
        _applyingReplica = false;
      }
      learningStateRevision.value++;
    });
    _syncWork = task.catchError((Object _) {});
    return task;
  }

  Future<void> _setSharedPreference(String key, dynamic value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is num) {
      await _prefs.setDouble(key, value.toDouble());
    } else if (value is String) {
      await _prefs.setString(key, value);
    }
  }

  void _applyWordState(Word word, Map raw) {
    word.state = StudyState.values.firstWhere((s) => s.name == raw['state'],
        orElse: () => StudyState.fresh);
    word.correctCount = (raw['correctCount'] as num?)?.toInt() ?? 0;
    word.wrongCount = (raw['wrongCount'] as num?)?.toInt() ?? 0;
    word.lastStudiedAt = DateTime.tryParse('${raw['lastStudiedAt']}');
    word.lastWrongAt = DateTime.tryParse('${raw['lastWrongAt']}');
  }

  Future<void> _applyReplicaValues() async {
    final replica = _replica!;
    final reset = replica.records['reset/all'];
    bool live(String key) =>
        reset == null || SyncReplica.compare(replica.records[key]!, reset) >= 0;
    final values = replica.values;
    await _prefs.setString(
        'wordRelations.v1',
        jsonEncode([
          for (final entry in values.entries)
            if (entry.key.startsWith('relation/') && entry.value != null)
              entry.value,
        ]));
    await _prefs.setString(
        'pronunciationSelections.v1',
        jsonEncode([
          for (final entry in values.entries)
            if (entry.key.startsWith('pronunciation/') && entry.value != null)
              entry.value,
        ]));
    await wordRelations.reload();
    SyncAuxiliary.revision.value++;
    for (final key in _sharedPreferenceKeys) {
      if (values.containsKey('setting/$key'))
        await _setSharedPreference(key, values['setting/$key']);
    }
    final order = values['bookOrder'];
    if (order is List) {
      final byId = {for (final b in books) b.id: b};
      books = [
        for (final id in order)
          if (byId.containsKey(id)) byId.remove(id)!,
        ...byId.values
      ];
    }
    final wordRecords = <String, Map<String, dynamic>>{
      for (final entry in replica.records.entries)
        if (entry.key.startsWith('word/') && live(entry.key))
          entry.key: entry.value,
    };
    final studies = <String, ActiveStudy>{};
    for (final entry in replica.records.entries) {
      if (!entry.key.startsWith('session/') ||
          !live(entry.key) ||
          entry.value['value'] is! Map) continue;
      final data = entry.value['value'] as Map;
      studies[entry.key.substring(8)] =
          ActiveStudy.fromJson(Map<String, dynamic>.from(data['active']));
      for (final word in (data['words'] as Map? ?? {}).entries) {
        final old = wordRecords[word.key];
        if (old == null || SyncReplica.compare(entry.value, old) > 0) {
          wordRecords[word.key.toString()] = {
            ...entry.value,
            'value': word.value
          };
        }
      }
    }
    for (final book in books) {
      if (values['bookFavorite/${book.id}'] is bool)
        book.isFavorite = values['bookFavorite/${book.id}'];
      for (final word in book.words) {
        final raw = wordRecords['word/${book.id}/${word.id}']?['value'];
        if (raw is Map)
          _applyWordState(word, raw);
        else if (reset != null) _applyWordState(word, {});
        final favorite = values['favorite/${book.id}/${word.id}'];
        if (favorite is bool) word.isFavorite = favorite;
      }
    }
    final memberships = <String, dynamic>{};
    final passes = <String, int>{};
    final bases = <String, dynamic>{};
    final events = <String, dynamic>{};
    final logs = <StudyEventLog>[];
    for (final entry in values.entries) {
      final key = entry.key;
      if (entry.value == null || !live(key)) continue;
      if (key.startsWith('completed/'))
        memberships[key.substring(10)] = entry.value;
      if (key.startsWith('passes/'))
        passes[key.substring(7)] = (entry.value as num).toInt();
      if (key.startsWith('dailyBase/')) bases[key.substring(10)] = entry.value;
      if (key.startsWith('event/')) events[key.substring(6)] = entry.value;
      if (key.startsWith('log/'))
        logs.add(
            StudyEventLog.fromJson(Map<String, dynamic>.from(entry.value)));
    }
    await _prefs.setString(_syncCompletedKey, jsonEncode(memberships));
    await _projectCompletedMembership();
    await _prefs.setString(VocaStore._coursePassesKey, jsonEncode(passes));
    await _prefs.setString(_syncDailyBaseKey, jsonEncode(bases));
    await _prefs.setString(_syncEventsKey, jsonEncode(events));
    final totals = <String, Map<String, dynamic>>{
      for (final entry in bases.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    };
    for (final event in events.values.whereType<Map>()) {
      if (event['canceled'] == true) continue;
      final total = totals.putIfAbsent(event['date'] as String, () => {});
      for (final entry in (event['delta'] as Map).entries) {
        total[entry.key.toString()] =
            ((total[entry.key] as num?)?.toInt() ?? 0) +
                (entry.value as num).toInt();
      }
    }
    await _saveDailyStudyStats(
        totals.map((k, v) => MapEntry(k, DailyStudyStats.fromJson(v))));
    await _prefs.setStringList(VocaStore._studyDaysKey, totals.keys.toList());
    await _saveStudyEventLog(_prunedStudyEventLog(logs));
    await _saveActiveStudies(studies);
    await _saveResetMarkers({
      for (final entry in values.entries)
        if (entry.key.startsWith('reset/') && entry.value is String)
          entry.key.substring(6): DateTime.parse(entry.value),
    });
    await _saveBooks();
    replica.acceptView(_syncValues());
    wordSearch.invalidate();
  }

  Future<String> _appendSyncEvent(String day, Map<String, int> delta,
      {String? bookId, int? wordId}) async {
    final events = _readSyncMap(_syncEventsKey);
    final device = await cloudChanges.deviceId();
    final id =
        '$device:${DateTime.now().microsecondsSinceEpoch}:${events.length}';
    events[id] = {
      'date': day,
      'delta': delta,
      'bookId': bookId,
      'wordId': wordId
    };
    await _prefs.setString(_syncEventsKey, jsonEncode(events));
    return id;
  }

  Future<void> undoWordDecision(Word word, StudyState previous,
      {String? bookId}) async {
    final events = _readSyncMap(_syncEventsKey);
    final keys = events.keys.where((key) {
      final event = events[key] as Map;
      return event['wordId'] == word.id &&
          event['bookId'] == bookId &&
          event['canceled'] != true;
    }).toList();
    if (keys.isNotEmpty) {
      final key = keys.last;
      final event = Map<String, dynamic>.from(events[key]);
      events[key] = {...event, 'canceled': true, 'cancels': key};
      await _prefs.setString(_syncEventsKey, jsonEncode(events));
      final stats = Map<String, DailyStudyStats>.from(dailyStudyStats);
      final day = event['date'] as String;
      final current = stats[day]?.toJson() ?? <String, dynamic>{};
      for (final delta in (event['delta'] as Map).entries) {
        current[delta.key.toString()] =
            (((current[delta.key] as num?)?.toInt() ?? 0) -
                    (delta.value as num).toInt())
                .clamp(0, 1 << 30);
      }
      stats[day] = DailyStudyStats.fromJson(current);
      await _saveDailyStudyStats(stats);
    }
    final prior = studyEventLog
        .where((e) => e.wordId == word.id && e.bookId == bookId)
        .firstOrNull;
    if (prior != null) {
      word.correctCount = prior.previousCorrectCount ?? word.correctCount;
      word.wrongCount = prior.previousWrongCount ?? word.wrongCount;
      word.lastStudiedAt = prior.previousLastStudiedAt;
      word.lastWrongAt = prior.previousLastWrongAt;
      await _saveStudyEventLog(
          studyEventLog.where((e) => e.id != prior.id).toList());
    }
    await mark(word, previous, recordAttempt: false);
    await cloudChanges.markLearningState();
  }
}
