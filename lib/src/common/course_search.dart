/// Name matching for the course lists.
///
/// Pure Dart on purpose: the interesting part is the folding, and it is far
/// easier to pin down in unit tests than through a widget.
library;

import '../api/models.dart';

/// German letters a search should treat as their plain ASCII forms.
///
/// The names here are German — "Einführung in die Softwaretechnik",
/// "Fachschaftsvollversammlung" — and a phone keyboard set to English has no
/// umlauts on it. Typing "einfuhrung" and being told there is no such course
/// is the whole reason this exists. Folded both ways: the query and the name
/// go through the same function, so "Einführung" also finds a course someone
/// entered as "Einfuehrung".
const Map<String, String> _folded = <String, String>{
  'ä': 'a',
  'ö': 'o',
  'ü': 'u',
  'ß': 'ss',
  // Not German, but TUM-Live carries the odd imported name.
  'é': 'e',
  'è': 'e',
  'á': 'a',
  'à': 'a',
  'í': 'i',
  'ó': 'o',
  'ú': 'u',
  'ñ': 'n',
  'ç': 'c',
};

/// Lowercases [text] and folds its diacritics, for comparing by eye not bytes.
String foldForSearch(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.toLowerCase().runes) {
    final String char = String.fromCharCode(rune);
    out.write(_folded[char] ?? char);
  }
  return out.toString();
}

/// The courses in [courses] that [query] matches, in their original order.
///
/// An empty or whitespace-only query matches everything, so the caller can
/// hand the raw field value straight in without special-casing the idle state.
///
/// Matches the slug as well as the name: TUM's own course codes live there
/// ("in0006"), and they are shorter to type than the title.
List<Course> searchCourses(List<Course> courses, String query) {
  final String needle = foldForSearch(query.trim());
  if (needle.isEmpty) return courses;
  return courses
      .where(
        (Course c) =>
            foldForSearch(c.name).contains(needle) ||
            foldForSearch(c.slug).contains(needle),
      )
      .toList();
}
