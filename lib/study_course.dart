import 'models.dart';

enum StudyCourseSource { cumulative, individual }

class StudyCourse {
  const StudyCourse({
    required this.start,
    required this.end,
    required this.source,
  });

  final int start;
  final int end;
  final StudyCourseSource source;

  int get wordCount => end - start;
  String get rangeLabel => 'No.$start~$end';
  String idFor(String bookId) => '$bookId:$start:$end';

  List<Word> wordsFrom(WordBook book) {
    final safeStart = start.clamp(0, book.words.length).toInt();
    final safeEnd = end.clamp(safeStart, book.words.length).toInt();
    return book.words.sublist(safeStart, safeEnd);
  }
}

List<StudyCourse> cumulativeStudyCourses(int wordCount) {
  if (wordCount <= 0) return const [];
  const unit = 50;
  const blockSize = 300;
  final courses = <StudyCourse>[];
  final seen = <String>{};

  void add(int start, int end) {
    if (end <= start) return;
    final key = '$start:$end';
    if (!seen.add(key)) return;
    courses.add(StudyCourse(
      start: start,
      end: end,
      source: StudyCourseSource.cumulative,
    ));
  }

  for (var blockStart = 0; blockStart < wordCount; blockStart += blockSize) {
    final blockEnd = (blockStart + blockSize).clamp(0, wordCount).toInt();
    for (var end = blockStart + unit; end < blockEnd; end += unit) {
      add(blockStart, end);
    }
    add(blockStart, blockEnd);
    if (blockStart > 0) add(0, blockEnd);
  }
  return courses;
}

List<StudyCourse> individualStudyCourses(int wordCount) {
  if (wordCount <= 0) return const [];
  const unit = 50;
  return [
    for (var start = 0; start < wordCount; start += unit)
      StudyCourse(
        start: start,
        end: (start + unit).clamp(0, wordCount).toInt(),
        source: StudyCourseSource.individual,
      ),
  ];
}
