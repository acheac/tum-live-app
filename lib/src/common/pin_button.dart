/// The pin toggle, and the one signal that tells the home screen it moved.
///
/// TUM-Live has always had pinning — `Course.pinned` comes straight off the
/// API and `TumLiveApi.setCoursePinned` has been there unused — so this is
/// wiring, not a new concept. It lives in `common/` because two pages carry
/// the same button and neither owns it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';

/// Bumped whenever a pin actually changes on the server.
///
/// The home screen's pinned list is a separate request from the course page
/// the pin was toggled on, so without a nudge it would keep showing the list
/// it fetched on launch and a freshly pinned course would not appear until a
/// pull-to-refresh. A revision counter rather than the list itself: the home
/// screen already knows how to refetch, and holding courses here as well would
/// leave two places claiming to know what is pinned.
final ValueNotifier<int> pinRevision = ValueNotifier<int>(0);

/// Pins or unpins [course].
///
/// Renders nothing at all when signed out: pinning is per-account and the
/// endpoint needs a token, so an enabled-looking button would only ever fail.
class PinButton extends StatefulWidget {
  const PinButton({required this.course, this.compact = false, super.key});

  final Course course;

  /// Shrinks the tap target for the app bar, where the default 48dp button
  /// pushes the two-line course title around.
  final bool compact;

  @override
  State<PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<PinButton> {
  late bool _pinned = widget.course.pinned;
  bool _busy = false;

  @override
  void didUpdateWidget(PinButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload can hand the same page a fresh Course. Follow it, unless a
    // request of our own is in flight and the optimistic value is newer.
    if (!_busy && oldWidget.course.pinned != widget.course.pinned) {
      _pinned = widget.course.pinned;
    }
  }

  Future<void> _toggle() async {
    final TumLiveApi api = AppScope.apiOf(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool next = !_pinned;
    // Optimistic: a pin is a one-bit change the user just asked for, and
    // waiting a round trip to fill the icon in makes the button feel broken.
    setState(() {
      _pinned = next;
      _busy = true;
    });
    try {
      await api.setCoursePinned(courseId: widget.course.id, pinned: next);
      pinRevision.value++;
    } on Object {
      // Put it back rather than leave the icon claiming something the server
      // never agreed to. Every other failure in this app is silent, but this
      // one has to be visible: the user watched the icon change.
      if (!mounted) return;
      setState(() => _pinned = !next);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            next ? 'Could not pin this course.' : 'Could not unpin it.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.authOf(context);
    if (!auth.isSignedIn) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey<String>('pin-button'),
      tooltip: _pinned ? 'Unpin course' : 'Pin course',
      onPressed: _busy ? null : () => unawaited(_toggle()),
      icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
      iconSize: widget.compact ? 20 : 24,
      style: widget.compact
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
            )
          : null,
    );
  }
}
