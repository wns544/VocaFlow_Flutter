part of 'store.dart';

extension CardStructureStore on VocaStore {
  Future<void> _queueTextRepairsFromCache(
      Map<String, List<int>> changed) async {
    final oldBooks = {for (final book in _loadBooks()) book.id: book};
    final operations = <Map<String, dynamic>>[];
    for (final entry in changed.entries) {
      if (entry.key == 'default') continue;
      for (final id in entry.value) {
        final before = oldBooks[entry.key]
            ?.words
            .where((word) => word.id == id)
            .firstOrNull;
        final after = resolveCard(entry.key, id);
        if (before == null || after == null) continue;
        final oldFields = _cardTextFields(before);
        final next = {
          for (final field in _cardTextFields(after).entries)
            if (oldFields[field.key] != field.value) field.key: field.value
        };
        if (next.isNotEmpty)
          operations.add({
            'kind': 'cardPatch',
            'bookId': entry.key,
            'wordId': id,
            'fields': next,
            'before': {for (final key in next.keys) key: oldFields[key]}
          });
      }
    }
    if (operations.isNotEmpty)
      await cardChanges.enqueueBatch(operations, notify: false);
  }

  Future<bool> verifyLegacyCardWork(
          List<CardBookSnapshot> remote, List<Map<String, dynamic>> metadata) =>
      runLocalMutation(() async {
        if (!cloudChanges.managedBookContentDirty) return true;
        final pending = cloudChanges.snapshot;
        final touched = {
          ...pending.bookIds,
          ...pending.wordIdsByBook.keys,
          ...pending.deletedWordIdsByBook.keys,
          ...pending.deletedBookIds
        }..remove('default');
        final byId = {
          for (final item in remote) item.book['id'].toString(): item
        };
        final deleted = {
          for (final item in metadata)
            if (item['deleted'] == true) item['id'].toString()
        };
        var matches = true;
        for (final id in touched) {
          if (pending.deletedBookIds.contains(id)) {
            matches = matches && deleted.contains(id);
            continue;
          }
          final local = books.where((book) => book.id == id).firstOrNull;
          final server = byId[id];
          if (local == null || server == null) {
            matches = false;
            continue;
          }
          final cards = {
            for (final card in server.cards) (card['id'] as num).toInt(): card
          };
          if (pending.bookIds.contains(id)) {
            matches = matches &&
                local.name == server.book['name'] &&
                SyncReplica.canonical(
                        _bookMetadata(local)['sessionOverrides']) ==
                    SyncReplica.canonical(
                        server.book['sessionOverrides'] ?? {}) &&
                SyncReplica.canonical(
                        local.words.map((word) => word.id).toList()) ==
                    SyncReplica.canonical(server.book['wordOrder']);
          }
          final ids = {
            ...?pending.wordIdsByBook[id],
            if (pending.bookIds.contains(id))
              ...local.words.map((word) => word.id)
          };
          for (final wordId in ids) {
            final word =
                local.words.where((word) => word.id == wordId).firstOrNull;
            final card = cards[wordId];
            if (word == null || card == null || card['deleted'] == true) {
              matches = false;
              continue;
            }
            for (final field in _cardTextFields(word).entries) {
              if (field.value != (card[field.key] ?? '')) matches = false;
            }
          }
          for (final wordId in pending.deletedWordIdsByBook[id] ?? <int>{}) {
            if (cards[wordId]?['deleted'] != true) matches = false;
          }
        }
        final marker = 'card.legacyReview.${_activeAccountId ?? 'local'}';
        if (_prefs.getInt(marker) != pending.generation) {
          await writeLargeLocalValue(
              _prefs,
              '$marker.${pending.generation}',
              jsonEncode({
                'books': books.map((book) => book.toJson()).toList(),
                'bookIds': pending.bookIds.toList(),
                'wordIdsByBook': pending.wordIdsByBook
                    .map((key, value) => MapEntry(key, value.toList())),
                'deletedWordIdsByBook': pending.deletedWordIdsByBook
                    .map((key, value) => MapEntry(key, value.toList())),
                'deletedBookIds': pending.deletedBookIds.toList(),
                'serverMatches': matches
              }));
          await _prefs.setInt(marker, pending.generation);
        }
        if (matches) {
          await cloudChanges.acknowledgeManagedBookContent(pending);
          await cloudChanges.recordLog('이전 단어장 대기: 새 서버 원본과 일치 확인 후 정리 완료');
        } else {
          await cloudChanges
              .recordLog('이전 단어장 대기: 로컬 백업 보존 · 서버와 다른 내용은 복구 확인 필요');
        }
        return matches;
      });
  Map<String, dynamic> _bookMetadata(WordBook book) => {
        'name': book.name,
        'isFavorite': book.isFavorite,
        'sessionOverrides': book.sessionOverrides
            .map((key, value) => MapEntry('$key', value.toJson())),
        'wordOrder': book.words.map((word) => word.id).toList(),
      };

  Future<void> _queueBookCreation(WordBook book, {bool restore = false}) async {
    if (book.words.map((word) => word.id).toSet().length != book.words.length) {
      throw StateError('중복 카드 ID가 있어 단어장을 저장하지 못했습니다.');
    }
    await cardChanges.enqueueBatch([
      {
        'kind': restore ? 'bookRestore' : 'bookCreate',
        'bookId': book.id,
        'fields': {..._bookMetadata(book), 'wordOrder': <int>[]}
      },
      for (final word in book.words)
        {
          'kind': restore ? 'cardRestore' : 'cardCreate',
          'bookId': book.id,
          'wordId': word.id,
          'fields': _cardTextFields(word)
        },
      if (restore)
        for (final old in books
            .where((old) => old.id == book.id)
            .expand((old) => old.words))
          if (!book.words.any((word) => word.id == old.id))
            {
              'kind': 'cardDelete',
              'bookId': book.id,
              'wordId': old.id,
              'fields': <String, dynamic>{}
            },
    ], notify: false);
  }

  Future<void> _queueBookUpdate(WordBook previous, WordBook updated) async {
    final operations = <Map<String, dynamic>>[];
    final before = _bookMetadata(previous);
    final after = _bookMetadata(updated);
    if (updated.words.map((word) => word.id).toSet().length !=
        updated.words.length) {
      throw StateError('중복 카드 ID가 있어 단어장을 저장하지 못했습니다.');
    }
    final oldById = {for (final word in previous.words) word.id: word};
    for (final word in updated.words) {
      final old = oldById[word.id];
      final fields = _cardTextFields(word);
      if (old == null) {
        operations.add({
          'kind': 'cardCreate',
          'bookId': updated.id,
          'wordId': word.id,
          'fields': fields
        });
      } else {
        final oldFields = _cardTextFields(old);
        final changed = {
          for (final entry in fields.entries)
            if (oldFields[entry.key] != entry.value) entry.key: entry.value
        };
        if (changed.isNotEmpty)
          operations.add({
            'kind': 'cardPatch',
            'bookId': updated.id,
            'wordId': word.id,
            'fields': changed,
            'before': {for (final key in changed.keys) key: oldFields[key]}
          });
      }
    }
    for (final word in previous.words) {
      if (!updated.words.any((next) => next.id == word.id))
        operations.add({
          'kind': 'cardDelete',
          'bookId': updated.id,
          'wordId': word.id,
          'fields': <String, dynamic>{},
          'before': _cardTextFields(word)
        });
    }
    final changedMetadata = {
      for (final entry in after.entries)
        if (SyncReplica.canonical(before[entry.key]) !=
            SyncReplica.canonical(entry.value))
          entry.key: entry.value
    };
    if (changedMetadata.isNotEmpty)
      operations.add({
        'kind': 'bookPatch',
        'bookId': updated.id,
        'fields': changedMetadata,
        'before': {for (final key in changedMetadata.keys) key: before[key]}
      });
    if (operations.isNotEmpty)
      await cardChanges.enqueueBatch(operations, notify: false);
  }

  /// Replay the durable journal after a crash or a server refresh. A server
  /// download may not replace a user's queued structure or newly added cards.
  void _overlayPendingStructureOperations() {
    for (final op in cardChanges.pending) {
      if (cardChanges.bookWasDeleted(op.bookId) &&
          !cardChanges.pending.any(
              (next) => next.bookId == op.bookId && next.kind == 'bookRestore'))
        continue;
      var book = books.where((book) => book.id == op.bookId).firstOrNull;
      if (op.kind == 'bookDelete') {
        books.removeWhere(
            (book) => book.id == op.bookId && book.id != 'default');
        continue;
      }
      if (op.kind == 'bookCreate' || op.kind == 'bookRestore') {
        if (book == null) {
          book = WordBook(
              id: op.bookId,
              name: op.fields['name']?.toString() ?? '단어장',
              words: []);
          books.add(book);
        }
      }
      if (book == null) continue;
      if (op.isBookOperation) {
        if (op.fields['name'] is String) book.name = op.fields['name'];
        if (op.fields['isFavorite'] is bool)
          book.isFavorite = op.fields['isFavorite'];
        if (op.fields['sessionOverrides'] is Map) {
          book.sessionOverrides.clear();
          (op.fields['sessionOverrides'] as Map).forEach((key, value) {
            final index = int.tryParse('$key');
            if (index != null && value is Map)
              book!.sessionOverrides[index] =
                  SessionOverride.fromJson(Map<String, dynamic>.from(value));
          });
        }
        final order = op.fields['wordOrder'];
        if (order is List && order.isNotEmpty) {
          final byId = {for (final word in book.words) word.id: word};
          book.words
            ..clear()
            ..addAll([
              for (final id in order)
                if (byId.containsKey(id)) byId.remove(id)!,
              ...byId.values
            ]);
        }
      } else if (op.kind == 'cardDelete') {
        book.words.removeWhere((word) => word.id == op.wordId);
      } else if (op.kind == 'cardCreate' || op.kind == 'cardRestore') {
        if (op.kind != 'cardRestore' &&
            cardChanges.cardWasDeleted(op.bookId, op.wordId)) continue;
        var word = book.words.where((word) => word.id == op.wordId).firstOrNull;
        if (word == null) {
          word = Word.fromJson({'id': op.wordId, ...op.fields});
          _restoreDownloadedCardLearning(word, book.id);
          book.words.add(word);
        }
        _overlayPendingCardFields(word, book.id);
      }
    }
  }

  Future<void> applyCardBookDeletion(String bookId) =>
      runLocalMutation(() async {
        await cardChanges.recordServerDeletions(bookId, deleted: true);
        if (cardChanges.pending
            .any((op) => op.bookId == bookId && op.kind == 'bookRestore'))
          return;
        await _applyRemoteBookDeletions([bookId]);
        _overlayPendingStructureOperations();
        await _saveBooks();
        wordSearch.invalidate();
        cardContentRevision.value++;
      });
}
