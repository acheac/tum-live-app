/// Errors raised by [TumLiveApi].
///
/// Kept deliberately small: the UI only ever needs to know "did this fail, is it
/// because we are not logged in, and what do I show the user".
library;

/// The server answered, but with a status we cannot use.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.uri});

  final int statusCode;
  final String message;
  final Uri? uri;

  /// No session, or the access token expired. The caller should sign in again.
  bool get isUnauthorized => statusCode == 401;

  /// Signed in, but not allowed to see this — e.g. a course you are not
  /// enrolled in. Retrying with a fresh token will not help.
  bool get isForbidden => statusCode == 403;

  bool get isNotFound => statusCode == 404;

  /// What to put in front of a user. Deliberately free of status codes.
  String get userMessage {
    if (isUnauthorized) return 'Please sign in to see this.';
    if (isForbidden) return 'You do not have access to this course.';
    if (isNotFound) return 'Not found. It may have been removed.';
    if (statusCode >= 500) return 'TUM-Live is having trouble. Try again later.';
    return message.isEmpty ? 'Something went wrong.' : message;
  }

  @override
  String toString() => 'ApiException($statusCode, $message, uri: $uri)';
}

/// The request never got an answer: no connection, DNS failure, timeout.
class NetworkException implements Exception {
  NetworkException(this.cause, {this.uri});

  final Object cause;
  final Uri? uri;

  String get userMessage => 'Cannot reach TUM-Live. Check your connection.';

  @override
  String toString() => 'NetworkException($cause, uri: $uri)';
}
