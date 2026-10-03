## 0.1.0

- Initial release.
- `SyncRefresh` controller: single-flight refresh across concurrent 401s.
- Replay-once semantics per failed request (no retry loops).
- Storage-agnostic `TokenStore` interface; refresh endpoint supplied by you.
- Session-expiry callback for app-level logout.
