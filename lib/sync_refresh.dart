/// Synchronized token refresh for Dio.
///
/// Parallel 401s trigger exactly one refresh; failed requests are replayed
/// once with the fresh token; a dead refresh tears the session down through
/// a single callback.
library;

export 'src/token_store.dart';
export 'src/sync_refresh.dart';
