/// A minimal cooperative cancellation token.
///
/// Long-running loops should check [isCancelled] periodically and stop
/// when it becomes true. Call [cancel] to request cancellation.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
