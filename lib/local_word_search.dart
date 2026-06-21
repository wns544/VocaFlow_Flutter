import 'models.dart';

class WordSearchHit {
  const WordSearchHit({required this.book, required this.word});

  final WordBook book;
  final Word word;
}

class LocalWordSearchIndex {
  LocalWordSearchIndex(this._books);

  final List<WordBook> Function() _books;
  List<_SearchDocument>? _documents;
  var _generation = 0;

  WordSearchSession createSession({String? bookId}) =>
      WordSearchSession._(this, bookId);

  void invalidate() {
    _documents = null;
    _generation++;
  }

  List<_SearchDocument> get _currentDocuments {
    final cached = _documents;
    if (cached != null) return cached;
    final documents = <_SearchDocument>[];
    for (final book in _books()) {
      for (final word in book.words) {
        documents.add(_SearchDocument(book, word));
      }
    }
    return _documents = documents;
  }
}

class WordSearchSession {
  WordSearchSession._(this._index, this.bookId);

  final LocalWordSearchIndex _index;
  final String? bookId;
  List<_SearchDocument> _previousMatches = const [];
  String _previousQuery = '';
  int _generation = -1;

  int lastEvaluatedCount = 0;
  int searchExecutionCount = 0;

  List<WordSearchHit> search(String rawQuery) {
    searchExecutionCount++;
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) {
      reset();
      return const [];
    }

    final indexChanged = _generation != _index._generation;
    final canNarrow = !indexChanged &&
        _previousQuery.isNotEmpty &&
        query.length > _previousQuery.length &&
        query.startsWith(_previousQuery);
    final source = canNarrow
        ? _previousMatches
        : _index._currentDocuments
            .where((document) => bookId == null || document.book.id == bookId)
            .toList(growable: false);

    lastEvaluatedCount = source.length;
    final buckets = List.generate(7, (_) => <_SearchDocument>[]);
    final matches = <_SearchDocument>[];
    for (final document in source) {
      final rank = document.rank(query, includeBookName: bookId == null);
      if (rank == null) continue;
      matches.add(document);
      buckets[rank].add(document);
    }

    _generation = _index._generation;
    _previousQuery = query;
    _previousMatches = matches;
    return [
      for (final bucket in buckets)
        for (final document in bucket)
          WordSearchHit(book: document.book, word: document.word),
    ];
  }

  void reset() {
    _previousMatches = const [];
    _previousQuery = '';
    _generation = _index._generation;
    lastEvaluatedCount = 0;
  }
}

class _SearchDocument {
  _SearchDocument(this.book, this.word)
      : bookName = book.name.toLowerCase(),
        term = word.term.toLowerCase(),
        reading = word.reading.toLowerCase(),
        meaning = word.meaning.toLowerCase(),
        example = word.example.toLowerCase(),
        exampleMeaning = word.exampleMeaning.toLowerCase();

  final WordBook book;
  final Word word;
  final String bookName;
  final String term;
  final String reading;
  final String meaning;
  final String example;
  final String exampleMeaning;

  int? rank(String query, {required bool includeBookName}) {
    if (term == query) return 0;
    if (term.startsWith(query)) return 1;
    if (reading == query || reading.startsWith(query)) return 2;
    if (term.contains(query)) return 3;
    if (reading.contains(query) || meaning.contains(query)) return 4;
    if (example.contains(query) || exampleMeaning.contains(query)) return 5;
    if (includeBookName && bookName.contains(query)) return 6;
    return null;
  }
}
