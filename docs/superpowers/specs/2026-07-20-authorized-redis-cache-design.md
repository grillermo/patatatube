# Token-Scoped Redis Response Cache Design

## Goal

Cache successful authenticated GET responses in Redis without storing reusable
Bearer tokens in Redis keys, while preserving the existing public-response
cache behavior.

## Scope

- For a GET request carrying `Authorization: Bearer <token>`, derive a stable
  SHA-256 fingerprint from the token value.
- Use the fingerprint to scope the existing path-and-query cache key. Data
  entries will be named `ptcache:data:auth:<fingerprint>:<path-and-query>`;
  the FIFO list and size hash will hold the same opaque scoped key.
- Keep public request keys exactly as they are today.
- Retain the `Range`-request bypass. Partial media responses must never enter
  this response cache.
- Retain the current cacheability conditions: only complete 200 responses
  without `Set-Cookie` are stored.
- Raise `CACHE_MAX_ITEM_BYTES` from 10 MiB to 300 MiB. The existing total
  FIFO budget (`CACHE_MAX_BYTES`) is already 300 MiB, so a single response may
  occupy the whole cache and cause older entries to be evicted.
- Keep successful POST, PUT, PATCH, and DELETE requests flushing all token
  scopes, as they do for the current public cache.

## Non-goals

- Do not change cache TTL behavior; entries remain FIFO-managed with no
  per-entry expiry.
- Do not change authentication or authorize a request in the middleware. The
  endpoint remains responsible for accepting or rejecting its credential.
- Do not change the query-token fallback used by the browser video player;
  this work scopes Bearer-header requests used by the iOS app.

## Data Flow

1. The middleware continues to reject caching only for requests with a
   `Range` header.
2. For a Bearer-authenticated request, it creates an opaque token scope with
   `sha256(token.encode()).hexdigest()` and prepends it to the URL cache key.
3. `cache.get` and `cache.put` receive that scoped key, so identical URLs for
   different tokens never share a response.
4. The raw token is never passed to the cache module, so it cannot appear in
   Redis data keys, FIFO members, or size-hash fields.
5. An unauthenticated request follows the unchanged public-key path.

## Error Handling and Security

- Redis failures continue to fail open.
- A failed authentication response is not cached because it is not a 200.
- SHA-256 fingerprints are deterministic for cache hits but not reusable
  credentials. A client with a different token receives a separate cache
  scope.
- The 300 MiB per-item limit bounds buffering but can consume substantial
  memory for a large non-range response; this is explicitly accepted to make
  authenticated media responses cacheable.

## Tests

- Replace the old assertion that authenticated requests always bypass Redis.
- Assert that two authenticated GETs with the same token and URL produce a
  cache hit on the second request.
- Assert that a second token misses the first token's cache entry, then hits
  its own entry.
- Inspect the fake Redis keyspace to prove it contains the SHA-256 fingerprint
  and never the plaintext token.
- Assert the default per-item cap is 300 MiB while the existing oversized-item
  behavior remains covered by the explicit lower test limit.
- Keep the existing public-cache, query-key, mutation-flush, eviction, and
  Redis-down tests unchanged.
