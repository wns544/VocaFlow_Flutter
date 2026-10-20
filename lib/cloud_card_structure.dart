part of 'cloud_backup.dart';

extension CloudCardStructure on CloudBackup {
  Future<void> _uploadStructureChange(CardChange change,
      {required String deviceId}) async {
    const kinds = {
      'bookCreate',
      'bookRestore',
      'bookPatch',
      'bookDelete',
      'cardCreate',
      'cardRestore',
      'cardDelete'
    };
    if (!kinds.contains(change.kind) || change.bookId == 'default')
      throw StateError('지원하지 않는 구조 변경입니다.');
    final bookRef = _cardBooksRef.doc(change.bookId);
    final cardRef = bookRef.collection('cards').doc('${change.wordId}');
    final operationRef = bookRef.collection('operations').doc(change.id);
    final signal = _cardBookSignal;
    final signalData = {
      'deviceId': deviceId,
      'bookId': change.bookId,
      'operationId': change.id,
      'updatedAt': FieldValue.serverTimestamp()
    };
    await firestore.runTransaction((transaction) async {
      if ((await transaction.get(operationRef)).exists) {
        transaction.set(signal, signalData);
        return;
      }
      final document = await transaction.get(bookRef);
      final book = document.data() ?? <String, dynamic>{};
      final cardDocument =
          change.isBookOperation ? null : await transaction.get(cardRef);
      final card = cardDocument?.data() ?? <String, dynamic>{};
      final next = ((book['nextChange'] as num?)?.toInt() ?? 0) + 1;
      final order = (book['wordOrder'] as List? ?? [])
          .whereType<num>()
          .map((n) => n.toInt())
          .toList();
      final parent = <String, dynamic>{
        'nextChange': next,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastOperationId': change.id,
        'lastOperationKind': change.kind
      };
      final before = <String, dynamic>{};
      if (change.isBookOperation) {
        if (change.kind == 'bookCreate' && document.exists)
          throw StateError('이미 존재하거나 삭제된 단어장 ID입니다. 복원 기능을 이용해 주세요.');
        if (change.kind == 'bookPatch' &&
            (!document.exists || book['deleted'] == true))
          throw StateError('삭제된 단어장 변경은 보존 후 확인이 필요합니다.');
        if (change.kind == 'bookDelete') {
          parent['deleted'] = true;
          before.addAll(book);
        } else {
          for (final key in const [
            'name',
            'isFavorite',
            'sessionOverrides',
            'wordOrder'
          ]) {
            if (!change.fields.containsKey(key)) continue;
            before[key] = book[key];
            if (key == 'wordOrder' && change.kind == 'bookPatch') {
              final wanted = (change.fields[key] as List)
                  .whereType<num>()
                  .map((n) => n.toInt())
                  .where(order.contains)
                  .toSet()
                  .toList();
              parent[key] = [
                ...wanted,
                ...order.where((id) => !wanted.contains(id))
              ];
            } else {
              parent[key] = change.fields[key];
            }
          }
          if (change.kind == 'bookCreate' || change.kind == 'bookRestore')
            parent['deleted'] = false;
        }
      } else {
        if (!document.exists || book['deleted'] == true)
          throw StateError('삭제된 단어장에 카드를 추가하거나 수정할 수 없습니다.');
        if (change.kind == 'cardCreate' && cardDocument!.exists)
          throw StateError('이미 존재하거나 삭제된 카드 ID입니다. 복원 기능을 이용해 주세요.');
        before.addAll(card);
        final fields = <String, dynamic>{};
        for (final key in const [
          'term',
          'reading',
          'meaning',
          'example',
          'exampleMeaning',
          'explanation'
        ]) {
          if (change.fields.containsKey(key)) fields[key] = change.fields[key];
        }
        final deleted = change.kind == 'cardDelete';
        final write = <String, dynamic>{
          ...fields,
          'deleted': deleted,
          'updatedAt': FieldValue.serverTimestamp(),
          'lastOperationId': change.id,
          'lastOperationKind': change.kind,
          'fieldRevisions': {
            ...(card['fieldRevisions'] as Map? ?? {}),
            for (final key in fields.keys) key: next
          }
        };
        if (!cardDocument!.exists) {
          transaction.set(cardRef, {
            'schema': 1,
            'id': change.wordId,
            'term': '',
            'reading': '',
            'meaning': '',
            'example': '',
            'exampleMeaning': '',
            'explanation': '',
            ...write
          });
        } else {
          transaction.update(cardRef, write);
        }
        if (deleted)
          order.removeWhere((id) => id == change.wordId);
        else if (!order.contains(change.wordId)) order.add(change.wordId);
        parent['wordOrder'] = order;
      }
      if (document.exists)
        transaction.update(bookRef, parent);
      else
        transaction.set(bookRef, {
          'schema': 1,
          'id': change.bookId,
          'name': '',
          'isFavorite': false,
          'sessionOverrides': <String, dynamic>{},
          'wordOrder': <int>[],
          ...parent
        });
      transaction.set(
          bookRef.collection('changes').doc(next.toString().padLeft(12, '0')), {
        'schema': 1,
        'number': next,
        'kind': change.kind,
        'wordId': change.wordId,
        // Concurrent card additions can extend an order patch. The history
        // must describe the effective server order, not the stale requested
        // subset, so strict rules and recovery agree with the committed data.
        'fields': change.isBookOperation
            ? {
                for (final key in change.fields.keys)
                  if (parent.containsKey(key)) key: parent[key]
              }
            : change.fields,
        'before': before,
        'operationId': change.id,
        'deviceId': deviceId,
        'localVersion': change.localVersion,
        'createdAt': FieldValue.serverTimestamp()
      });
      transaction.set(operationRef, {
        'schema': 1,
        'operationId': change.id,
        'changeNumber': next,
        'changeId': next.toString().padLeft(12, '0'),
        'wordId': change.wordId,
        'kind': change.kind,
        'createdAt': FieldValue.serverTimestamp()
      });
      transaction.set(signal, signalData);
    });
  }
}
