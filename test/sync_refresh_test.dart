import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sync_refresh/sync_refresh.dart';
import 'package:test/test.dart';

/// A minimal scripted [HttpClientAdapter]: register responses per path and
/// they are served in registration order (a real queue).
class ScriptedAdapter implements HttpClientAdapter {
  final Map<String, List<Response>> _script = {};

  void enqueue(String path, int status, [Object? data]) {
    _script.putIfAbsent(path, () => []).add(
          Response(
            requestOptions: RequestOptions(path: path),
            statusCode: status,
            data: data ?? const {},
          ),
        );
  }

  int requestsServed = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final queue = _script[options.path];
    if (queue == null || queue.isEmpty) {
      throw StateError('no scripted response for ${options.path}');
    }
    requestsServed += 1;
    final response = queue.removeAt(0);
    final body = switch (response.data) {
      String text => text,
      Map() || List() => _jsonEncode(response.data as Object),
      _ => '',
    };
    return ResponseBody.fromString(body, response.statusCode ?? 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  String _jsonEncode(Object data) {
    // Hand-rolled for the few shapes these tests use — avoids pulling a JSON
    // dependency into the test helper.
    if (data is Map<String, dynamic>) {
      final entries = data.entries
          .map((entry) => '"${entry.key}":${_encodeValue(entry.value)}')
          .join(',');
      return '{$entries}';
    }
    return _encodeValue(data);
  }

  String _encodeValue(Object? value) {
    if (value is String) return '"$value"';
    if (value is num || value is bool) return '$value';
    if (value is List) return '[${value.map(_encodeValue).join(',')}]';
    return 'null';
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late ScriptedAdapter adapter;
  late MemoryTokenStore store;
  late int refreshCalls;

  void attach({bool refreshWorks = true}) {
    refreshCalls = 0;
    dio.interceptors.add(
      SyncRefresh(
        dio: dio,
        store: store,
        refresh: () async {
          refreshCalls += 1;
          if (refreshWorks) {
            await store.write(access: 'new-access', refresh: 'new-refresh');
          }
          return refreshWorks;
        },
        anonymousPaths: const {'/auth/token'},
      ).interceptor,
    );
  }

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'http://api.test'));
    adapter = ScriptedAdapter();
    dio.httpClientAdapter = adapter;
    store = MemoryTokenStore()
      ..access = 'stale-access'
      ..refresh = 'valid-refresh';
  });

  test('401 triggers refresh and the request is replayed', () async {
    attach();
    adapter.enqueue('/accounts/', 401, {'error': 'expired'});
    adapter.enqueue('/accounts/', 200, {'ok': true});

    final response = await dio.get<Map<String, dynamic>>('/accounts/');

    expect(response.statusCode, 200);
    expect(store.access, 'new-access');
    expect(store.refresh, 'new-refresh');
    expect(refreshCalls, 1);
  });

  test('failed refresh clears storage and fires the expiry callback', () async {
    var expired = 0;
    dio.interceptors.add(
      SyncRefresh(
        dio: dio,
        store: store,
        refresh: () async => false,
        onSessionExpired: () => expired += 1,
      ).interceptor,
    );
    adapter.enqueue('/accounts/', 401, {'error': 'expired'});

    await expectLater(
        () => dio.get<Map<String, dynamic>>('/accounts/'), throwsA(anything));

    expect(expired, 1);
    expect(store.access, isNull);
    expect(store.refresh, isNull);
  });

  test('anonymous paths (login) never trigger a refresh', () async {
    attach();
    adapter.enqueue('/auth/token/', 401, {'detail': 'bad credentials'});

    await expectLater(
      () => dio.post<Map<String, dynamic>>('/auth/token/',
          data: {'email': 'a@b.c', 'password': 'x'}),
      throwsA(anything),
    );

    expect(refreshCalls, 0);
    expect(
      store.access,
      'stale-access',
      reason: 'anonymous failures leave storage alone',
    );
  });

  test('a replay that 401s again surfaces instead of looping', () async {
    attach();
    adapter.enqueue('/accounts/', 401, {'error': 'expired'});
    adapter.enqueue('/accounts/', 401, {'error': 'still expired'});

    await expectLater(
        () => dio.get<Map<String, dynamic>>('/accounts/'), throwsA(anything));

    expect(refreshCalls, 1, reason: 'one refresh, one replay — then it stops');
    expect(store.access, isNull, reason: 'second 401 tears the session down');
  });

  test('concurrent 401s share a single refresh', () async {
    var refreshRuns = 0;
    dio.interceptors.add(
      SyncRefresh(
        dio: dio,
        store: store,
        refresh: () async {
          refreshRuns += 1;
          // A refresh that takes a moment widens the race window so all
          // three requests overlap inside it.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await store.write(access: 'fresh');
          return true;
        },
      ).interceptor,
    );

    for (final path in ['/a/', '/b/', '/c/']) {
      adapter.enqueue(path, 401, {'e': 1});
      adapter.enqueue(path, 200, {'ok': true});
    }

    final results = await Future.wait([
      dio.get<Map<String, dynamic>>('/a/'),
      dio.get<Map<String, dynamic>>('/b/'),
      dio.get<Map<String, dynamic>>('/c/'),
    ]);

    expect(results.every((response) => response.statusCode == 200), isTrue);
    expect(refreshRuns, 1,
        reason: 'three concurrent 401s, exactly one refresh');
  });
}
