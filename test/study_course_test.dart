import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/study_course.dart';

List<String> labels(List<StudyCourse> courses) =>
    courses.map((course) => course.rangeLabel).toList();

void main() {
  group('cumulativeStudyCourses', () {
    test('103 words ends at the real count without duplicates', () {
      expect(
        labels(cumulativeStudyCourses(103)),
        ['No.0~50', 'No.0~100', 'No.0~103'],
      );
    });

    test('338 words creates a partial second block and full review', () {
      expect(
        labels(cumulativeStudyCourses(338)),
        [
          'No.0~50',
          'No.0~100',
          'No.0~150',
          'No.0~200',
          'No.0~250',
          'No.0~300',
          'No.300~338',
          'No.0~338',
        ],
      );
    });

    test('366 words creates 300~350, 300~366, then 0~366', () {
      final result = labels(cumulativeStudyCourses(366));
      expect(result.take(6).last, 'No.0~300');
      expect(result.skip(6), ['No.300~350', 'No.300~366', 'No.0~366']);
      expect(result.toSet().length, result.length);
    });

    test('1206 words adds every 300 block and final partial review', () {
      final result = labels(cumulativeStudyCourses(1206));
      expect(
          result,
          containsAllInOrder([
            'No.0~300',
            'No.300~600',
            'No.0~600',
            'No.600~900',
            'No.0~900',
            'No.900~1200',
            'No.0~1200',
            'No.1200~1206',
            'No.0~1206',
          ]));
      expect(result.toSet().length, result.length);
    });
  });

  group('individualStudyCourses', () {
    test('creates non-overlapping fixed 50 ranges', () {
      expect(
        labels(individualStudyCourses(103)),
        ['No.0~50', 'No.50~100', 'No.100~103'],
      );
    });

    test('same numeric range has the same id in either source mode', () {
      final cumulative = cumulativeStudyCourses(103).first;
      final individual = individualStudyCourses(103).first;
      expect(cumulative.idFor('book'), individual.idFor('book'));
      expect(cumulative.idFor('book'), 'book:0:50');
    });
  });
}
