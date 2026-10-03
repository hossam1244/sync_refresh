import 'package:dio/dio.dart';

import 'token_store.dart';

/// Coordinates token refresh for a [Dio] client.
///
/// Add [interceptor] to your Dio instance and provide a [refresh] handler
/// that performs the actual token-refresh call (the endpoint shape differs
/// per API — that part stays yours). The package owns the hard part:
///
/// * **Single flight** — concurrent 401s await one in-flight refresh, so a
///   rotating refresh token is never burned twice.
/// * **Replay once** — each failed request is retried exactly once with the
///   fresh token; a second 401 surfaces instead of looping.
/// * **Session teardown** — a failed refresh clears storage and fires
///   [onSessionExpired] once, for app-level logout.
///
/// ```dart
/// final store = MemoryTokenStore();
/// final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
/// final sync = SyncRefresh(
///   dio: dio,
///   store: store,
///   refresh: () async {
///     final response = await Dio(BaseOptions(baseUrl: dio.options.baseUrl))
///         .post('/auth/token/refresh/', data: {
///       'refresh': await store.readRefresh(),
///     });
///     await store.write(
///       access: response.data['access'] as String,
///       refresh: response.data['refresh'] as String?,
///     );
///     return true;
///   },
///   onSessionExpired: () => authBloc.add(const LoggedOut()),
/// );
/// dio.interceptors.add(sync.interceptor);
/// ```
class SyncRefresh {
  SyncRefresh({
    required this.dio,
    required this.store,
    required Future<bool> Function() refresh,
    this.onSessionExpired,
    Set<String> anonymousPaths = const {},
  })  : _refresh = refresh,
        _anonymousPaths = anonymousPaths {
    interceptor = _Interceptor(this);
  }

  /// The Dio client this coordinator is attached to.
  final Dio dio;

  /// Token persistence — implemented by you.
  final TokenStore store;

  /// Performs the refresh call and persists new tokens.
  /// Return `true` on success.
  final Future<bool> Function() _refresh;

  /// Fired exactly once when a refresh fails and the session is dead.
  final void Function()? onSessionExpired;

  /// Paths that must never trigger a refresh (login, register, the refresh
  /// endpoint itself…). Matched with `String.contains`.
  final Set<String> _anonymousPaths;

  /// Add this to `dio.interceptors`.
  late final Interceptor interceptor;

  /// The in-flight refresh future, shared by every concurrent 401.
  Future<bool>? _inflight;

  /// Single-flight refresh: the first caller runs the handler; everyone
  /// else (including later arrivals while it is running) awaits the same
  /// future. A completed refresh is never re-run by concurrent callers.
  Future<bool> refreshOnce() {
    final running = _inflight;
    if (running != null) return running;
    final future = _refresh().whenComplete(() => _inflight = null);
    _inflight = future;
    return future;
  }

  Future<void> _teardownSession() async {
    await store.clear();
    onSessionExpired?.call();
  }
}

class _Interceptor extends Interceptor {
  _Interceptor(this._owner);

  final SyncRefresh _owner;

  static const _retriedFlag = 'sync_refresh.retried';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _owner.store.readAccess();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final isAnonymous = _owner._anonymousPaths.any(request.path.contains);

    if (err.response?.statusCode != 401 || isAnonymous) {
      return handler.next(err);
    }
    if (request.extra[_retriedFlag] == true) {
      // Already replayed once — surface the failure, never loop.
      await _owner._teardownSession();
      return handler.next(err);
    }

    final refreshed = await _owner.refreshOnce();
    if (!refreshed) {
      await _owner._teardownSession();
      return handler.next(err);
    }

    try {
      final response = await _owner.dio.fetch<dynamic>(
        request..extra[_retriedFlag] = true,
      );
      return handler.resolve(response);
    } on DioException catch (replayError) {
      return handler.next(replayError);
    }
  }
}
