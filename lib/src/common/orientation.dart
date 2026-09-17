/// Which way up the app is allowed to be, decided by screen size.
///
/// The app has exactly one use for landscape: the player's fullscreen, which
/// the fullscreen button enters explicitly. Physical rotation anywhere else
/// only ever turned a portrait list of courses sideways, so on a phone it is
/// off. A tablet is wide enough for those same lists to read well in either
/// orientation, and is usually docked or held in one, so there it stays on.
///
/// The screen is asked rather than the platform: one build runs on both, and a
/// foldable crosses the line while running.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shortest side, in logical pixels, at which a screen counts as a tablet.
///
/// Material's own phone/tablet break. Measured on the shortest side so it
/// means the same thing whichever way the device is currently held.
const double kTabletShortestSide = 600;

/// The orientations [media] should be allowed to rotate through.
List<DeviceOrientation> allowedOrientations(MediaQueryData media) =>
    media.size.shortestSide < kTabletShortestSide
    ? const <DeviceOrientation>[DeviceOrientation.portraitUp]
    : DeviceOrientation.values;

/// Applies [allowedOrientations] to the platform, and keeps it applied.
///
/// Wraps the app below `MaterialApp`, which is the first place a `MediaQuery`
/// exists to measure. Re-applied on size changes rather than once at startup,
/// because a foldable opening mid-session changes the answer.
class OrientationPolicy extends StatefulWidget {
  const OrientationPolicy({required this.child, super.key});

  final Widget child;

  @override
  State<OrientationPolicy> createState() => _OrientationPolicyState();
}

class _OrientationPolicyState extends State<OrientationPolicy> {
  /// What was last handed to the platform, so an unrelated rebuild — a theme
  /// change, a keyboard opening — does not re-issue the same call.
  List<DeviceOrientation>? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final List<DeviceOrientation> allowed = allowedOrientations(
      MediaQuery.of(context),
    );
    if (_applied != null && listEquals(_applied, allowed)) return;
    _applied = allowed;
    // Fire-and-forget: nothing downstream waits on the platform agreeing, and
    // a rejected request would only leave rotation as it was.
    SystemChrome.setPreferredOrientations(allowed);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
