import 'dart:async';

/// Waits for a required service. A timeout throws. Callers must not substitute
/// a fresh object whose fields were never initialized.
Future<T> requireInit<T>(
  Future<T> future, {
  required Duration timeout,
  required String label,
}) {
  return future.timeout(
    timeout,
    onTimeout: () {
      throw TimeoutException('$label did not finish starting');
    },
  );
}
