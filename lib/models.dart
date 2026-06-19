enum StudyState { fresh, memorized, review }

class Word {
  Word({
    int? id,
    required this.term,
    required this.meaning,
    required this.reading,
    this.example = '',
    this.exampleMeaning = '',
    this.state = StudyState.fresh,
  }) : id = id ?? Object.hash(term, meaning, reading);

  final int id;
  final String term;
  final String meaning;
  final String reading;
  final String example;
  final String exampleMeaning;
  StudyState state;

  Map<String, dynamic> toJson() => {
        'id': id,
        'term': term,
        'meaning': meaning,
        'reading': reading,
        'example': example,
        'exampleMeaning': exampleMeaning,
        'state': state.name,
      };

  factory Word.fromJson(Map<String, dynamic> json) => Word(
        id: json['id'] as int?,
        term: json['term'] as String? ?? '',
        meaning: json['meaning'] as String? ?? '',
        reading: json['reading'] as String? ?? '',
        example: json['example'] as String? ?? '',
        exampleMeaning: json['exampleMeaning'] as String? ?? '',
        state: StudyState.values.firstWhere(
          (value) => value.name == json['state'],
          orElse: () => StudyState.fresh,
        ),
      );

  Word copyWith({
    String? term,
    String? meaning,
    String? reading,
    String? example,
    String? exampleMeaning,
    StudyState? state,
  }) =>
      Word(
        id: id,
        term: term ?? this.term,
        meaning: meaning ?? this.meaning,
        reading: reading ?? this.reading,
        example: example ?? this.example,
        exampleMeaning: exampleMeaning ?? this.exampleMeaning,
        state: state ?? this.state,
      );
}

class SessionOverride {
  const SessionOverride({this.size, this.name});

  final int? size;
  final String? name;

  Map<String, dynamic> toJson() => {'size': size, 'name': name};

  factory SessionOverride.fromJson(Map<String, dynamic> json) =>
      SessionOverride(
          size: json['size'] as int?, name: json['name'] as String?);
}

class StudySession {
  const StudySession({
    required this.index,
    required this.label,
    required this.words,
    required this.size,
  });

  final int index;
  final String label;
  final List<Word> words;
  final int size;

  bool get isCompleted =>
      words.isNotEmpty &&
      words.every((word) => word.state == StudyState.memorized);
  int get memorizedCount =>
      words.where((word) => word.state == StudyState.memorized).length;
}

class WordBook {
  WordBook({
    required this.id,
    required this.name,
    required this.words,
    this.isFavorite = false,
    Map<int, SessionOverride>? sessionOverrides,
  }) : sessionOverrides = sessionOverrides ?? {};

  final String id;
  String name;
  final List<Word> words;
  bool isFavorite;
  final Map<int, SessionOverride> sessionOverrides;

  List<StudySession> sessions(int defaultSize) {
    final result = <StudySession>[];
    var offset = 0;
    var index = 0;
    while (offset < words.length) {
      final override = sessionOverrides[index];
      final size = (override?.size ?? defaultSize).clamp(1, 200);
      final end = (offset + size).clamp(0, words.length);
      result.add(StudySession(
        index: index,
        label: override?.name?.trim().isNotEmpty == true
            ? override!.name!.trim()
            : '세션 ${index + 1}',
        words: words.sublist(offset, end),
        size: size,
      ));
      offset = end;
      index++;
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isFavorite': isFavorite,
        'words': words.map((word) => word.toJson()).toList(),
        'sessionOverrides': sessionOverrides.map(
          (key, value) => MapEntry(key.toString(), value.toJson()),
        ),
      };

  factory WordBook.fromJson(Map<String, dynamic> json) => WordBook(
        id: json['id'] as String,
        name: json['name'] as String,
        isFavorite: json['isFavorite'] as bool? ?? false,
        words: (json['words'] as List<dynamic>)
            .map((item) => Word.fromJson(item as Map<String, dynamic>))
            .toList(),
        sessionOverrides:
            (json['sessionOverrides'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(
            int.parse(key),
            SessionOverride.fromJson(value as Map<String, dynamic>),
          ),
        ),
      );
}
