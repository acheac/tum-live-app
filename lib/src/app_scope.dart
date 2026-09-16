/// Dependency wiring for the whole app.
///
/// Deliberately not a DI package. [InheritedNotifier] is built into Flutter, it
/// gives us `AppScope.of(context)`, and it rebuilds dependents when the auth
/// state changes — which is all this app needs. If the object graph ever grows
/// past two entries, that is the moment to reach for `provider` or `riverpod`,
/// not before.
library;

import 'package:flutter/widgets.dart';

import 'api/tum_live_api.dart';
import 'auth/auth_controller.dart';

class AppScope extends InheritedNotifier<AuthController> {
  const AppScope({
    super.key,
    required this.api,
    required AuthController auth,
    required super.child,
  }) : super(notifier: auth);

  final TumLiveApi api;

  /// The API client, already wired to send the current bearer token.
  static TumLiveApi apiOf(BuildContext context) => _of(context).api;

  /// The auth controller. Reading this subscribes the widget to sign-in changes.
  static AuthController authOf(BuildContext context) => _of(context).notifier!;

  static AppScope _of(BuildContext context) {
    final AppScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget.');
    return scope!;
  }
}
