import 'package:flutter_test/flutter_test.dart';
import 'package:tumlive_player/src/api/models.dart';
import 'package:tumlive_player/src/common/course_search.dart';

Course course(String name, {String slug = 'x'}) => Course(
  id: 1,
  name: name,
  slug: slug,
  semester: const Semester(year: 2025, teachingTerm: 'W'),
  vodEnabled: true,
  visibility: 'public',
  pinned: false,
  lectures: const <Lecture>[],
);

void main() {
  group('foldForSearch', () {
    test('lowercases', () {
      expect(foldForSearch('Analysis'), 'analysis');
    });

    test('folds the German umlauts', () {
      expect(foldForSearch('Einführung'), 'einfuhrung');
      expect(foldForSearch('Übung'), 'ubung');
      expect(foldForSearch('Prüfung Größe'), 'prufung grosse');
    });

    test('ß becomes ss, not s', () {
      // Two characters out of one: the loop has to write, not substitute in
      // place, and a length-preserving fold would drop the second s.
      expect(foldForSearch('Größe'), 'grosse');
    });
  });

  group('searchCourses', () {
    final List<Course> courses = <Course>[
      course('Einführung in die Softwaretechnik (IN0006)', slug: 'in0006'),
      course('Analysis for Informatics', slug: 'analysis'),
      course('Fachschaftsvollversammlung Informatik', slug: 'fsvv'),
    ];

    test('an empty query keeps everything', () {
      expect(searchCourses(courses, ''), courses);
      expect(searchCourses(courses, '   '), courses);
    });

    test('matches part of a name, ignoring case', () {
      expect(
        searchCourses(courses, 'INFORMATICS').single.name,
        'Analysis for Informatics',
      );
    });

    test('an umlaut can be typed without one', () {
      // The point of the whole file: an English keyboard has no ü, and this is
      // a German course catalogue.
      expect(searchCourses(courses, 'einfuhrung').single.slug, 'in0006');
    });

    test('the real name still matches itself', () {
      expect(searchCourses(courses, 'Einführung').single.slug, 'in0006');
    });

    test('matches the slug, so a course code is enough', () {
      expect(searchCourses(courses, 'in0006').single.slug, 'in0006');
    });

    test('no match is empty, not everything', () {
      // A filter that fails open would quietly show the full list and look
      // like the search did nothing.
      expect(searchCourses(courses, 'quantum'), isEmpty);
    });

    test('keeps the order it was given', () {
      // Both Informatics courses, second and third in the input, and still in
      // that order out. Nothing here ranks matches; the caller's order is the
      // semester's order and is what the sections already display.
      expect(
        searchCourses(courses, 'informati').map((Course c) => c.slug).toList(),
        <String>['analysis', 'fsvv'],
      );
    });
  });
}
