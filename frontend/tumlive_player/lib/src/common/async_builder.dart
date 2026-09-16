/// One place that decides what loading, empty and failed look like.
///
/// Every screen in this app does the same three-state dance around a network
/// call. Without something like this you end up with four slightly different
/// spinners and four slightly different error messages.
library;

import 'package:flutter/material.dart';

import '../api/api_exception.dart';

/// Renders [future] as a spinner, an error with a Retry button, or [builder].
///
/// [future] must come from state, not be built inline in `build()` — otherwise
/// every rebuild kicks off a new request. The screens here keep it in a field
/// and call `setState` to replace it, which is what [onRetry] is for.
class AsyncBuilder<T> extends StatelessWidget {
  const AsyncBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.onRetry,
    this.loading,
  });

  final Future<T>? future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<T> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return loading ??
              const Center(child: CircularProgressIndicator.adaptive());
        }
        if (snapshot.hasError) {
          return ErrorView(
            error: snapshot.error!,
            onRetry: onRetry,
          );
        }
        if (!snapshot.hasData) {
          return ErrorView(
            error: ApiException(0, 'No data came back.'),
            onRetry: onRetry,
          );
        }
        return builder(context, snapshot.data as T);
      },
    );
  }
}

/// Turns an exception into something a student can act on.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  /// Maps our two exception types onto human text, and everything else onto a
  /// generic message — an unhandled `TypeError` should not be shown raw.
  String get _message {
    final Object e = error;
    if (e is ApiException) return e.userMessage;
    if (e is NetworkException) return e.userMessage;
    return 'Something went wrong.';
  }

  bool get _needsSignIn => error is ApiException && (error as ApiException).isUnauthorized;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _needsSignIn ? Icons.lock_outline : Icons.cloud_off,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown when a request succeeded but there is nothing in it.
class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.message, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon ?? Icons.inbox_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
