# sync_refresh

**Synchronized JWT token refresh for [Dio](https://pub.dev/packages/dio).**

Parallel 401s trigger **exactly one** refresh; every failed request is replayed
**once** with the fresh token; a dead refresh tears the session down through a
single callback.

[![CI](https://github.com/hossam1244/sync_refresh/actions/workflows/ci.yml/badge.svg)](https://github.com/hossam1244/sync_refresh/actions/workflows/ci.yml)
[![pub](https://img.shields.io/badge/pub-0.1.0-blue)](https://pub.dev/packages/sync_refresh)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Why

Rotating refresh tokens (the right way to run JWT) have one awkward property:
**they can only be used once**. When a screen fires five requests and the access
token expires, all five come back 401 — and five naive refresh attempts will
burn the rotating token five times, logging the user out for no reason.

`sync_refresh` coordinates that for you:

| Guarantee | How |
|---|---|
| **Single flight** | Concurrent 401s await one in-flight refresh — the handler runs once |
| **Replay once** | Each failed request is retried exactly once with the fresh token; a second 401 surfaces instead of looping |
| **Session teardown** | A failed refresh clears storage and fires one callback for app-level logout |
| **Anonymous paths** | Login/register/refresh endpoints never trigger refreshes |
| **Storage-agnostic** | You keep your token store (secure storage, DB, whatever) behind a 4-method interface |

Extracted from the author's production-style banking client
([novabank-flutter](https://github.com/hossam1244/novabank-flutter)) — the same
coordinator ships there.

## Install

```yaml
dependencies:
  sync_refresh: ^0.1.0
```

*(published to pub.dev soon; until then, git dependency:)*

```yaml
dependencies:
  sync_refresh:
    git: https://github.com/hossam1244/sync_refresh.git
```

## Usage

```dart
import 'package:dio/dio.dart';
import 'package:sync_refresh/sync_refresh.dart';

final store = MemoryTokenStore(); // or your flutter_secure_storage adapter
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

final sync = SyncRefresh(
  dio: dio,
  store: store,
  refresh: () async {
    // Your refresh endpoint, your shape:
    final response = await Dio(BaseOptions(baseUrl: dio.options.baseUrl)).post(
      '/auth/token/refresh/',
      data: {'refresh': await store.readRefresh()},
    );
    await store.write(
      access: response.data['access'] as String,
      refresh: response.data['refresh'] as String?,
    );
    return true;
  },
  onSessionExpired: () {
    // exactly once, when the refresh is truly dead
    navigatorKey.currentState?.pushReplacementNamed('/login');
  },
  anonymousPaths: const {'/auth/token', '/auth/register'},
);

dio.interceptors.add(sync.interceptor);

// That's it. Every request gets a Bearer token; 401s heal themselves.
final accounts = await dio.get('/accounts/');
```

Need a manual refresh (app start, foreground push)? `sync.refreshOnce()` gives
you the same single-flight guarantee outside the interceptor.

## Testing

The suite covers the full contract: 401 → refresh → replay, refresh-failure
teardown, anonymous-path exclusion, no retry loops, and the headline —
**three concurrent 401s sharing exactly one refresh run** (deterministic, via a
scripted `HttpClientAdapter`, so no mock-package behavior to trust).

```bash
dart test    # 5 tests, pure Dart, milliseconds
```

## License

[MIT](LICENSE)
