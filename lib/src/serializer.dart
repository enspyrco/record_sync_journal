import 'dart:async';

/// Runs one operation at a time, each after the last completes.
typedef Serializer = Future<T> Function<T>(Future<T> Function() op);

/// A [Serializer] for one isolate.
///
/// The queue's own chain never touches the future it hands back: each result
/// goes out through a separate completer. So a failed operation still reaches
/// the zone as an unhandled error when its caller drops the future, and the
/// queue carries on to the next operation either way.
Serializer isolateLocalQueue() {
  Future<void> tail = Future<void>.value();
  return <T>(Future<T> Function() op) {
    final out = Completer<T>();
    tail = tail.then((_) async {
      try {
        out.complete(await op());
      } on Object catch (error, stack) {
        out.completeError(error, stack);
      }
    });
    return out.future;
  };
}
