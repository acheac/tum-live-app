/// Player choices that outlive one lecture: the camera angle, and where the
/// fused mode's camera inset sits.
///
/// Picking an angle says something about how this person likes to watch, not
/// about one lecture — someone who wants the slides large wants that for every
/// lecture in the course. So the choice outlives the page, and the app restart
/// too.
///
/// Unlike the session cookie there is nothing sensitive here, so
/// [SharedPreferences] is the right home rather than a compromise.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

class SourcePreference {
  const SourcePreference();

  static const String _key = 'tumlive.lecture_source';

  /// The last chosen angle, or null if there is none or it no longer exists.
  ///
  /// A stored name is matched by [LectureSource.name] rather than by index:
  /// indexes shift whenever the enum gains a value, and this one just did.
  Future<LectureSource?> read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? name = prefs.getString(_key);
      if (name == null) return null;
      for (final LectureSource source in LectureSource.values) {
        if (source.name == name) return source;
      }
    } on Object {
      // No preferences on this platform, or a corrupt store. Falling back to
      // the default is the whole cost of being wrong here.
    }
    return null;
  }

  Future<void> write(LectureSource source) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, source.name);
    } on Object {
      // Remembering the angle is a nicety; never let it break playback.
    }
  }
}


/// Where the fused mode's camera inset sits, and how big it is.
///
/// Every value is a fraction of the slides picture rather than a pixel count,
/// which is what lets one stored position mean the same thing in a phone's 16:9
/// slot and on a full landscape screen. Pixels would put the inset off-screen
/// the first time the user rotated.
class CameraInset {
  const CameraInset({
    required this.right,
    required this.bottom,
    required this.width,
  });

  /// Gap between the inset's right edge and the picture's, over picture width.
  final double right;

  /// Gap between the inset's bottom edge and the picture's, over picture
  /// height.
  final double bottom;

  /// The inset's width, over the picture's width.
  final double width;

  CameraInset copyWith({double? right, double? bottom, double? width}) =>
      CameraInset(
        right: right ?? this.right,
        bottom: bottom ?? this.bottom,
        width: width ?? this.width,
      );
}

class CameraInsetPreference {
  const CameraInsetPreference();

  static const String _rightKey = 'tumlive.inset_right';
  static const String _bottomKey = 'tumlive.inset_bottom';
  static const String _widthKey = 'tumlive.inset_width';

  /// Null when the user has never moved the inset, which leaves the player free
  /// to pick a corner that suits the screen it finds itself on.
  Future<CameraInset?> read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final double? right = prefs.getDouble(_rightKey);
      final double? bottom = prefs.getDouble(_bottomKey);
      final double? width = prefs.getDouble(_widthKey);
      if (right == null || bottom == null || width == null) return null;
      return CameraInset(right: right, bottom: bottom, width: width);
    } on Object {
      return null;
    }
  }

  Future<void> write(CameraInset inset) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_rightKey, inset.right);
      await prefs.setDouble(_bottomKey, inset.bottom);
      await prefs.setDouble(_widthKey, inset.width);
    } on Object {
      // Where a window sits is not worth failing a lecture over.
    }
  }
}
