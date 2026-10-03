// A runnable tour of the package against a scripted server.
//
//   cd example && dart pub add dio sync_refresh && dart example.dart
//
// Shows: bearer attachment, 401 → single-flight refresh → replay, and the
// session-expiry callback when the refresh dies.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sync_refresh/sync_refresh.dart';

void main() async {
  final store = MemoryTokenStore()
    ..access = 'stale-access'
    ..refresh = 'valid-refresh';

  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = _ScriptedServer();

  var sessionExpired = false;

  dio.interceptors.add(
    SyncRefresh(
      dio: dio,
      store: store,
      refresh: () async {
        // Your refresh endpoint call — shaped however your API wants.
        print('→ refreshing token…');
        await store.write(access: 'new-access', refresh: 'new-refresh');
        return true;
      },
      onSessionExpired: () => sessionExpired = true,
      anonymousPaths: const {'/auth/token'},
    ).interceptor,
  );

  print('calling /accounts/ with a stale token…');
  final response = await dio.get<dynamic>('/accounts/');
  print('← ${response.statusCode} (token replayed, now: ${store.access})');
  print('session expired? $sessionExpired');
}

/// Serves one 401 then 200s — enough to demonstrate the whole flow.
class _ScriptedServer implements HttpClientAdapter {
  var _first = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_first) {
      _first = false;
      print('  server: 401 (token expired)');
      return ResponseBody.fromString('{"error":"expired"}', 401);
    }
    print('  server: 200 with fresh token');
    return ResponseBody.fromString('{"accounts":[]}', 200);
  }

  @override
  void close({bool force = false}) {}
}
