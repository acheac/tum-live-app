/// Small formatting helpers shared by the player and the lecture lists.
library;

/// Formats a [Duration] as `mm:ss`, or `h:mm:ss` once it passes an hour.
///
/// The player's clock and the lecture list both use this, so a lecture reads
/// the same length in both places.
String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final String minutes = two(d.inMinutes.remainder(60));
  final String seconds = two(d.inSeconds.remainder(60));
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

/// Short human date for a lecture row, e.g. `10 Oct 2025, 08:00`.
///
/// Deliberately not using `intl`: one format, one language, no extra dependency.
String formatLectureDate(DateTime? date) {
  if (date == null) return '';
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime local = date.toLocal();
  final String hh = local.hour.toString().padLeft(2, '0');
  final String mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, $hh:$mm';
}

/// `W` / `S` as TUM writes them on the website: `WS 2025` / `SS 2025`.
String formatSemester(int year, String teachingTerm) =>
    '${teachingTerm == 'W' ? 'WS' : 'SS'} $year';
