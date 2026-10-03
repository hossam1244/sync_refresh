/// Storage-agnostic token access.
///
/// Implement with whatever you already use — flutter_secure_storage on
/// mobile, a database on the server. The interceptor only ever talks to
/// this interface.
abstract class TokenStore {
  Future<String?> readAccess();
  Future<String?> readRefresh();

  /// [refresh] may be null when the backend did not rotate it.
  Future<void> write({required String access, String? refresh});

  /// Called when the refresh failed — clear whatever you persisted.
  Future<void> clear();
}

/// A trivial in-memory store — handy for tests and examples.
class MemoryTokenStore implements TokenStore {
  String? access;
  String? refresh;

  @override
  Future<String?> readAccess() async => access;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<void> write({required String access, String? refresh}) async {
    this.access = access;
    this.refresh = refresh ?? this.refresh;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
  }
}
