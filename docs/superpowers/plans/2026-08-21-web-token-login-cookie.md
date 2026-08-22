# Web Token Login (Cookie) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the server-rendered web page behind a single login form that stores `UPLOAD_TOKEN` in a cookie, and make every media request authenticate with that cookie instead of a `?token=` query string.

**Architecture:** A new `GET/POST /login` form page writes an HttpOnly cookie named `upload_token` holding the raw token. `router._check_token_or_query` accepts that cookie as a third credential form (alongside `Authorization: Bearer` and `?token=`), the SSR page redirects cookie-less visitors to `/login`, the response cache keys cached pages by a hash of the cookie so an anonymous visitor can never be served a cached authenticated page, and Caddy — which does the token check in-process for disk-served MP4s and HLS segments — gets the same cookie alternative in its `@ptunauth` matcher. Write endpoints stay Bearer-only; the page keeps injecting `window.UPLOAD_TOKEN` for its own `fetch`/`XMLHttpRequest` calls, exactly as today.

**Tech Stack:** FastAPI + Starlette, Jinja2 templates (`views/`), pytest + `fastapi.testclient.TestClient`, Caddy 2 (`~/c/server/Caddyfile`).

**Spec:** No spec file — this is the bounded design approved in chat on 2026-08-21. The design, verbatim:

- `_cookie_token_valid(request)` compares cookie `upload_token` with `UPLOAD_TOKEN` via `secrets.compare_digest`; `_check_token_or_query` gains it as a third accepted form. `_check_token` (writes) stays Bearer-only.
- `GET /login` renders a single-field form; an already-valid cookie 303s to `next`.
- `POST /login` sets the cookie and 303s to `next` on match; re-renders the form with an error at 401 on mismatch. `next` is sanitized to a path starting with `/` and not `//`.
- `GET /logout` deletes the cookie and redirects to `/login`.
- `videos_page` redirects cookie-less visitors to `/login?next=…` with 303.
- `_macros.html` and `render._preview_src` drop `?token=`; `window.UPLOAD_TOKEN` stays.
- Caddy's `@ptunauth` gets `not header Cookie *upload_token={env.UPLOAD_TOKEN}*`.
- The iOS app is untouched (it uses Bearer). The token still reaches an authenticated viewer as `window.UPLOAD_TOKEN`; this gates *access* to the page, it does not hide the secret from someone already logged in.

## Global Constraints

- Cookie name: `upload_token`. Attributes: `path=/`, `httponly=True`, `samesite="lax"`, `max_age=31536000`, `secure=True` only when `request.url.scheme == "https"` (the dev server on `:3050` is plain HTTP; a `Secure` cookie would never be stored there).
- The cookie value is the raw `UPLOAD_TOKEN`. The production token is 23 characters of `[A-Za-z0-9]` (verified 2026-08-21), so Starlette does not quote it and Caddy's substring match on the `Cookie` header is exact. **If the token is ever changed to include characters outside `[A-Za-z0-9._~-]`, Starlette wraps the cookie value in double quotes and the Caddy matcher in Task 6 stops matching.**
- All token comparisons use `secrets.compare_digest` on **bytes** (`a.encode()`, `b.encode()`) — the `str` overload raises `TypeError` on non-ASCII input, which a login form can trivially receive.
- Never log, and never put in a redirect URL, the token itself.
- Tests live in `tests/test_api.py` (endpoint behaviour, uses the existing `client` fixture that sets `UPLOAD_TOKEN=test-secret`) and `tests/test_render.py` (pure template rendering, no HTTP). Follow whichever file the task names.
- Run tests with `python -m pytest` from the repo root (the venv is `python_env/`; `python_env/bin/python -m pytest` if `python` is not that venv).
- **Do not run any iOS test.** Nothing in this plan touches `ios/`.

---

### Task 1: The cookie counts as a credential for read endpoints

`_check_token_or_query` currently accepts a Bearer header or `?token=`. Add the cookie. This is the single change that lets `<video>` tags, `/videos/{id}/preview`, library streams, HLS fallthrough and `/check-auth` work from a browser session with no token in the URL.

**Files:**
- Modify: `router.py:125-136` (`_check_token_or_query`), plus new constants and helper above it near `router.py:116`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `router.LOGIN_COOKIE: str = "upload_token"`
  - `router.LOGIN_COOKIE_MAX_AGE: int = 31536000`
  - `router._cookie_token_valid(request: Request) -> bool`
  - `router._check_token_or_query(request: Request) -> None` (unchanged signature, new accepted credential)

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def test_check_auth_accepts_the_login_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/check-auth")
    assert resp.status_code == 200


def test_check_auth_rejects_a_wrong_login_cookie(client):
    client.cookies.set("upload_token", "nope")
    resp = client.get("/check-auth")
    assert resp.status_code == 401


def test_check_auth_still_accepts_bearer_and_query_token(client):
    assert client.get("/check-auth", headers={"Authorization": "Bearer test-secret"}).status_code == 200
    assert client.get("/check-auth?token=test-secret").status_code == 200
    assert client.get("/check-auth").status_code == 401
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "login_cookie or bearer_and_query" -v`
Expected: `test_check_auth_accepts_the_login_cookie` FAILS with `assert 401 == 200`. The other two PASS (they cover existing behaviour and must keep passing).

- [ ] **Step 3: Write the implementation**

In `router.py`, immediately above `def _check_token(request: Request):` (currently line 116), add:

```python
# The web page authenticates with a cookie holding the raw UPLOAD_TOKEN, set by
# POST /login. It is HttpOnly: the page's own JS gets the token from the
# server-rendered window.UPLOAD_TOKEN instead, so nothing needs to read it back.
LOGIN_COOKIE = "upload_token"
LOGIN_COOKIE_MAX_AGE = 31536000  # one year


def _tokens_match(candidate: str, expected: str) -> bool:
    """compare_digest on bytes: its str overload raises TypeError on non-ASCII,
    which a login form can receive from anyone."""
    return secrets.compare_digest(candidate.encode(), expected.encode())


def _cookie_token_valid(request: Request) -> bool:
    expected = os.getenv("UPLOAD_TOKEN", "")
    candidate = request.cookies.get(LOGIN_COOKIE, "")
    return bool(expected) and bool(candidate) and _tokens_match(candidate, expected)
```

Then in `_check_token_or_query`, extend the docstring and add the cookie branch. The whole function becomes:

```python
def _check_token_or_query(request: Request):
    """Bearer auth, with a ?token= fallback for HTML <video> tags (which can't
    send headers) and a login-cookie fallback for the browser session."""
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and _tokens_match(auth[7:], token):
        return
    query_token = request.query_params.get("token", "")
    if query_token and _tokens_match(query_token, token):
        return
    if _cookie_token_valid(request):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")
```

Leave `_check_token` (the Bearer-only write gate) exactly as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS, including the three new tests and every pre-existing one.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: accept a login cookie as credentials for read endpoints"
```

---

### Task 2: The login page renders

A standalone dark page with one field. Pure rendering, no routes yet.

**Files:**
- Create: `views/templates/login.html`
- Modify: `views/render.py` (add `build_login_page` at the end of the file, after `build_videos_page`)
- Test: `tests/test_render.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `views.render.build_login_page(next_url: str = "/", error: bool = False) -> str`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_render.py`:

```python
def test_login_page_renders_the_form():
    from views.render import build_login_page

    html = build_login_page()

    assert '<form method="post" action="/login">' in html
    assert 'name="token"' in html
    assert 'value="/"' in html
    assert "Wrong token" not in html


def test_login_page_carries_the_next_target():
    from views.render import build_login_page

    html = build_login_page(next_url="/videos?group_id=2")

    assert 'name="next" value="/videos?group_id=2"' in html


def test_login_page_shows_an_error_when_asked():
    from views.render import build_login_page

    html = build_login_page(error=True)

    assert "Wrong token" in html


def test_login_page_never_contains_the_token():
    import os

    from views.render import build_login_page

    os.environ["UPLOAD_TOKEN"] = "super-secret-value"
    try:
        html = build_login_page()
    finally:
        os.environ.pop("UPLOAD_TOKEN", None)

    assert "super-secret-value" not in html
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_render.py -k login -v`
Expected: FAIL with `ImportError: cannot import name 'build_login_page' from 'views.render'`.

- [ ] **Step 3: Write the template**

Create `views/templates/login.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Patata Videos</title>
<meta name="theme-color" content="#111111">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
* { box-sizing: border-box; margin: 0; padding: 0 }
body {
  background: #111;
  color: #eee;
  font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
}
form { width: 100%; max-width: 320px; display: flex; flex-direction: column; gap: 12px }
h1 { font-size: 1.1em; text-align: center; font-weight: 600 }
input {
  background: #1c1c1c;
  border: 1px solid #333;
  border-radius: 8px;
  color: #eee;
  font-size: 1em;
  padding: 12px;
}
button {
  background: #2c6cf0;
  border: 0;
  border-radius: 8px;
  color: #fff;
  font-size: 1em;
  padding: 12px;
}
p.error { color: #f66; font-size: 0.85em; text-align: center }
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>Patata Videos</h1>
  {% if error -%}
  <p class="error">Wrong token.</p>
  {%- endif %}
  <input type="password" name="token" autocomplete="current-password" autofocus required
         aria-label="Access token" placeholder="Access token">
  <input type="hidden" name="next" value="{{ next_url }}">
  <button type="submit">Enter</button>
</form>
</body>
</html>
```

- [ ] **Step 4: Write the renderer**

Append to `views/render.py`, after `build_videos_page`:

```python
def build_login_page(next_url: str = "/", error: bool = False) -> str:
    """The token form. Deliberately self-contained: it must render for someone
    who has no credentials, so it links no token-gated asset and embeds its CSS."""
    template = _env.get_template("login.html")
    return template.render(next_url=next_url, error=error)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_render.py -v`
Expected: PASS (all four new tests plus every pre-existing render test).

- [ ] **Step 6: Commit**

```bash
git add views/templates/login.html views/render.py tests/test_render.py
git commit -m "feat: add the login page template"
```

---

### Task 3: /login and /logout endpoints

**Files:**
- Modify: `router.py` — new endpoints directly above `@router.get("/", response_class=HTMLResponse)` (currently line 1280); import change at `router.py:12`; import change at `router.py:26`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `router.LOGIN_COOKIE`, `router.LOGIN_COOKIE_MAX_AGE`, `router._tokens_match`, `router._cookie_token_valid` (Task 1); `views.render.build_login_page` (Task 2).
- Produces:
  - `router._safe_next(raw: str | None) -> str`
  - `GET /login` → 200 HTML, or 303 to `next` when the cookie is already valid
  - `POST /login` (form fields `token`, `next`) → 303 + `Set-Cookie` on match, 401 HTML on mismatch, 503 when `UPLOAD_TOKEN` is unset
  - `GET /logout` → 303 to `/login`, cookie deleted

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def test_login_page_is_reachable_without_credentials(client):
    resp = client.get("/login")
    assert resp.status_code == 200
    assert 'name="token"' in resp.text


def test_login_with_the_right_token_sets_the_cookie_and_redirects(client):
    resp = client.post(
        "/login",
        data={"token": "test-secret", "next": "/videos?group_id=2"},
        follow_redirects=False,
    )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/videos?group_id=2"
    cookie = resp.headers["set-cookie"]
    assert "upload_token=test-secret" in cookie
    assert "HttpOnly" in cookie
    assert "samesite=lax" in cookie.lower()


def test_login_with_a_wrong_token_sets_nothing(client):
    resp = client.post("/login", data={"token": "nope", "next": "/"}, follow_redirects=False)
    assert resp.status_code == 401
    assert "Wrong token" in resp.text
    assert "set-cookie" not in resp.headers


def test_login_refuses_an_offsite_next(client):
    resp = client.post(
        "/login",
        data={"token": "test-secret", "next": "//evil.example.com/"},
        follow_redirects=False,
    )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/"


def test_login_page_redirects_when_already_authenticated(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/login?next=/videos", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/videos"


def test_logout_clears_the_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/logout", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login"
    assert "upload_token=" in resp.headers["set-cookie"]
    assert 'upload_token="";' in resp.headers["set-cookie"] or "upload_token=;" in resp.headers["set-cookie"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "login or logout" -v`
Expected: FAIL — `GET /login` returns 404, `POST /login` returns 405/404.

- [ ] **Step 3: Extend the imports**

In `router.py:12`, add `quote` to the `urllib.parse` import (it is unused until Task 5, which is fine — add it now so both tasks touch the line once):

```python
from urllib.parse import parse_qs, quote, urlparse
```

In `router.py:26`, add `build_login_page`:

```python
from views.render import build_login_page, build_videos_page
```

- [ ] **Step 4: Write the endpoints**

In `router.py`, directly above `@router.get("/", response_class=HTMLResponse)`, add:

```python
def _safe_next(raw: str | None) -> str:
    """Same-site paths only. '//evil.example.com/' is a protocol-relative URL:
    it starts with '/' but browsers treat it as an absolute offsite address."""
    if not raw or not raw.startswith("/") or raw.startswith("//"):
        return "/"
    return raw


@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, next: str | None = None):
    target = _safe_next(next)
    if _cookie_token_valid(request):
        return RedirectResponse(url=target, status_code=303)
    return HTMLResponse(build_login_page(next_url=target))


@router.post("/login")
async def login_submit(request: Request, token: str = Form(""), next: str = Form("/")):
    expected = os.getenv("UPLOAD_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503, detail="Upload not configured")
    target = _safe_next(next)
    if not _tokens_match(token, expected):
        return HTMLResponse(build_login_page(next_url=target, error=True), status_code=401)
    response = RedirectResponse(url=target, status_code=303)
    response.set_cookie(
        LOGIN_COOKIE,
        expected,
        max_age=LOGIN_COOKIE_MAX_AGE,
        path="/",
        httponly=True,
        samesite="lax",
        # The dev server answers plain HTTP on :3050; a Secure cookie would
        # never be stored there.
        secure=request.url.scheme == "https",
    )
    return response


@router.get("/logout")
async def logout():
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie(LOGIN_COOKIE, path="/")
    return response
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: add the /login form and /logout"
```

---

### Task 4: The response cache keys pages by cookie

`RedisCacheMiddleware` runs **before** the endpoint: on a cache hit it returns the stored 200 without ever calling `videos_page`. Once Task 5 makes the page redirect anonymous visitors, a cached copy of the authenticated page would still be handed to them. Scope the key by a hash of the cookie, the way Bearer requests are already scoped.

**Files:**
- Modify: `middleware.py:47-53` (the Bearer fingerprint block inside `dispatch`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `router.LOGIN_COOKIE` by value (the middleware hardcodes the string, as it does for header names — it must not import `router`).
- Produces: cache keys of the form `cookie:<sha256>:<path>?<query>` for cookie-bearing GETs.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_api.py`:

```python
def test_cached_pages_are_scoped_to_the_login_cookie(client):
    import middleware

    # The key derivation is what matters, and it is not otherwise observable,
    # so assert on it directly through a request-shaped stub.
    class _Req:
        def __init__(self, cookies, headers=None):
            self.method = "GET"
            self.cookies = cookies
            self.headers = headers or {}

            class _URL:
                path = "/"
                query = ""

            self.url = _URL()

    anon = middleware.cache_key_for(_Req({}))
    authed = middleware.cache_key_for(_Req({"upload_token": "test-secret"}))
    other = middleware.cache_key_for(_Req({"upload_token": "different"}))

    assert anon != authed
    assert authed != other
    assert "test-secret" not in authed
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python -m pytest tests/test_api.py::test_cached_pages_are_scoped_to_the_login_cookie -v`
Expected: FAIL with `AttributeError: module 'middleware' has no attribute 'cache_key_for'`.

- [ ] **Step 3: Extract the key derivation and add the cookie scope**

In `middleware.py`, add a module-level function above `class RedisCacheMiddleware`:

```python
# The web page's session cookie. Hardcoded rather than imported from router:
# middleware is imported by main *before* the router, and this is a wire-format
# constant, not shared logic.
_LOGIN_COOKIE = "upload_token"


def cache_key_for(request) -> str | None:
    """Cache key for a GET, or None when the request must not be cached.

    Bearer requests are scoped by a hash of the token so two tokens never share
    a response. Cookie-bearing requests get the same treatment for a different
    reason: this middleware answers from the cache *before* the endpoint runs,
    so an unscoped key would serve a cached authenticated page to a visitor with
    no cookie at all.
    """
    key = request.url.path
    if request.url.query:
        key += "?" + request.url.query

    auth = request.headers.get("authorization")
    if auth:
        scheme, _, token = auth.partition(" ")
        if scheme.lower() != "bearer" or not token:
            return None
        fingerprint = hashlib.sha256(token.encode()).hexdigest()
        return f"auth:{fingerprint}:{key}"

    session = request.cookies.get(_LOGIN_COOKIE)
    if session:
        fingerprint = hashlib.sha256(session.encode()).hexdigest()
        return f"cookie:{fingerprint}:{key}"

    return key
```

Then replace the inline key derivation in `dispatch` — everything from `key = request.url.path` through the `key = f"auth:{fingerprint}:{key}"` line — with:

```python
        key = cache_key_for(request)
        if key is None:
            return await call_next(request)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/ -v`
Expected: PASS. Confirm no pre-existing cache test regressed.

- [ ] **Step 5: Commit**

```bash
git add middleware.py tests/test_api.py
git commit -m "fix: scope cached responses by the login cookie"
```

---

### Task 5: The SSR page redirects anonymous visitors

**Files:**
- Modify: `router.py:1280-1287` (`videos_page`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `router._cookie_token_valid` (Task 1), `quote` (imported in Task 3), the cookie-scoped cache key (Task 4).
- Produces: `videos_page(request: Request, group_id: int | None = None, plex_kind: str | None = None)` — same query contract, now takes `Request` first.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def test_page_redirects_to_login_without_a_cookie(client):
    resp = client.get("/", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2F"


def test_page_redirect_preserves_the_query_string(client):
    resp = client.get("/videos?group_id=2", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2Fvideos%3Fgroup_id%3D2"


def test_page_renders_with_a_valid_cookie(client):
    client.cookies.set("upload_token", "test-secret")
    resp = client.get("/")
    assert resp.status_code == 200
    assert "window.UPLOAD_TOKEN" in resp.text
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "redirects_to_login or redirect_preserves or renders_with_a_valid_cookie" -v`
Expected: the two redirect tests FAIL with `assert 200 == 303`; the third PASSES already.

- [ ] **Step 3: Gate the page**

Replace `videos_page` in `router.py` with:

```python
@router.get("/", response_class=HTMLResponse)
@router.get("/videos", response_class=HTMLResponse)
async def videos_page(
    request: Request,
    group_id: int | None = None,
    plex_kind: str | None = None,
):
    if not _cookie_token_valid(request):
        target = request.url.path
        if request.url.query:
            target += "?" + request.url.query
        return RedirectResponse(url=f"/login?next={quote(target, safe='')}", status_code=303)
    if plex_kind is not None and plex_kind not in db.PLEX_KINDS:
        plex_kind = None
    videos = db.get_all_videos(group_id=group_id, plex_kind=plex_kind)
    return build_videos_page(videos, db.list_groups(), group_id, plex_kind)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: send visitors without a login cookie to /login"
```

---

### Task 6: Media URLs stop carrying ?token=

With the cookie accepted everywhere the page reads from, the token no longer belongs in `src`/`href` attributes or in Caddy's access log.

**Files:**
- Modify: `views/templates/_macros.html:51` (macro signature), `:65` (`<source src>`), `:75` (download link)
- Modify: `views/templates/videos_page.html` (the `m.card(...)` call)
- Modify: `views/render.py` (`_preview_src`)
- Test: `tests/test_render.py`

**Interfaces:**
- Consumes: `_check_token_or_query`'s cookie branch (Task 1).
- Produces: `card(v, groups, current_group_id, show_titles=False)` — the `upload_token` parameter is gone. `build_videos_page`'s own signature is unchanged and it still passes `upload_token` to the template for `window.UPLOAD_TOKEN`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_render.py`:

```python
def test_media_urls_carry_no_token_query():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert "/videos/1/stream" in html
    assert "?token=" not in html


def test_the_page_still_exposes_the_token_to_its_own_js():
    html = build_videos_page([_video()], GROUPS, 1, None)

    assert "window.UPLOAD_TOKEN" in html


def test_local_previews_carry_no_token_query():
    html = build_videos_page(
        [_video(source="library", plex_kind="movies", group_id=None, preview_url="/videos/1/preview")],
        GROUPS,
        None,
        "movies",
    )

    assert "?token=" not in html
    assert "&token=" not in html
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_render.py -k "no_token_query or exposes_the_token" -v`
Expected: `test_media_urls_carry_no_token_query` FAILS (`?token=` is present). `test_the_page_still_exposes_the_token_to_its_own_js` PASSES. `test_local_previews_carry_no_token_query` FAILS if `preview_url_for` yields the local path — if it PASSES immediately, leave it as a regression guard and move on.

- [ ] **Step 3: Drop the token from the card macro**

In `views/templates/_macros.html`, change line 51 from

```
{% macro card(v, groups, current_group_id, upload_token, show_titles=False) -%}
```

to

```
{% macro card(v, groups, current_group_id, show_titles=False) -%}
```

change the `<source>` line (65) from

```
    <source src="/videos/{{ v.id }}/stream?token={{ upload_token }}" type="video/mp4">
```

to

```
    <source src="/videos/{{ v.id }}/stream" type="video/mp4">
```

and the download link (75) from

```
  <a class="download-btn" href="/videos/{{ v.id }}/stream?token={{ upload_token }}" download="{{ v | download_name }}.mp4" aria-label="Download video">&#8681;</a>
```

to

```
  <a class="download-btn" href="/videos/{{ v.id }}/stream" download="{{ v | download_name }}.mp4" aria-label="Download video">&#8681;</a>
```

- [ ] **Step 4: Update the call site**

In `views/templates/videos_page.html`, change

```
{{ m.card(v, groups, current_group_id, upload_token, show_titles) }}
```

to

```
{{ m.card(v, groups, current_group_id, show_titles) }}
```

Leave `<script>window.UPLOAD_TOKEN = {{ upload_token | tojson }};</script>` alone — `assets/app/videos.js:341` still reads it for the Bearer-only write endpoints.

- [ ] **Step 5: Drop the token from preview URLs**

In `views/render.py`, replace `_preview_src` with:

```python
def _preview_src(video: dict) -> str | None:
    """Poster URL. Local /videos/* posters authenticate with the login cookie
    (see router._check_token_or_query); external ones need nothing."""
    return preview_url_for(video)
```

`import os` stays — `build_videos_page` still reads `UPLOAD_TOKEN` from the environment.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `python -m pytest tests/ -v`
Expected: PASS, including the pre-existing `test_renders_done_card` (it asserts `/videos/1/stream`, which still appears).

- [ ] **Step 7: Commit**

```bash
git add views/templates/_macros.html views/templates/videos_page.html views/render.py tests/test_render.py
git commit -m "feat: authenticate web media requests with the cookie, not ?token="
```

---

### Task 7: Caddy accepts the cookie, and the docs record it

Caddy answers `/videos/{id}/stream` and `/videos/{id}/hls/*` off disk and does the token check itself in `@ptunauth` (`~/c/server/Caddyfile:122-125`) — there is no `forward_auth`. **Until this task lands and Caddy is reloaded, Task 6 leaves the web player 401ing in production.** The two must ship together.

**Files:**
- Modify: `~/c/server/Caddyfile:120-125` (outside this repo — it lives in the `~/c/server` git repo)
- Modify: `CLAUDE.md` (the `### Auth` section)

**Interfaces:**
- Consumes: the cookie set by `POST /login` (Task 3).
- Produces: nothing other tasks read.

- [ ] **Step 1: Add the cookie alternative to the matcher**

In `~/c/server/Caddyfile`, replace lines 120-125:

```
	# Same contract as the app's /check-auth: Bearer header, or ?token= for
	# <video> tags, which cannot set headers.
	@ptunauth {
		not header Authorization "Bearer {env.UPLOAD_TOKEN}"
		not query token={env.UPLOAD_TOKEN}
	}
```

with:

```
	# Same contract as the app's /check-auth: Bearer header for the iOS app,
	# ?token= for anything that cannot set headers, or the web page's login
	# cookie (set by POST /login). The cookie match is a substring test on the
	# whole Cookie header, so it only holds while UPLOAD_TOKEN stays free of
	# characters Starlette would quote — keep it [A-Za-z0-9._~-].
	@ptunauth {
		not header Authorization "Bearer {env.UPLOAD_TOKEN}"
		not query token={env.UPLOAD_TOKEN}
		not header Cookie *upload_token={env.UPLOAD_TOKEN}*
	}
```

- [ ] **Step 2: Validate the config**

Run: `caddy validate --config ~/c/server/Caddyfile --adapter caddyfile`
Expected: `Valid configuration`. If it reports an adapter error on the matcher, the file is not being adapted as a Caddyfile — re-run from `~/c/server` with `caddy validate` (it picks up the local `Caddyfile` automatically).

- [ ] **Step 3: Verify the whole flow by hand**

```bash
# terminal 1
cd /Users/grillermo/c/patatatube && ./serve
# terminal 2
caddy reload --config ~/c/server/Caddyfile
TOKEN=$(grep '^UPLOAD_TOKEN' /Users/grillermo/c/patatatube/.env | cut -d= -f2)

# anonymous page -> login
curl -si http://localhost:3050/ | head -1                 # expect 303
curl -si http://localhost:3050/ | grep -i location        # expect /login?next=%2F

# login sets the cookie
curl -si -X POST http://localhost:3050/login \
  -d "token=$TOKEN" -d "next=/" | grep -i set-cookie      # expect upload_token=…; HttpOnly

# the cookie streams a Caddy-served MP4 with no ?token=
curl -so /dev/null -w '%{http_code}\n' \
  -H "Cookie: upload_token=$TOKEN" \
  -r 0-1023 http://localhost:3050/videos/<A_REAL_DONE_ID>/stream   # expect 206
curl -so /dev/null -w '%{http_code}\n' \
  -r 0-1023 http://localhost:3050/videos/<A_REAL_DONE_ID>/stream   # expect 401
```

Pick `<A_REAL_DONE_ID>` from `sqlite3 data/watch_later.sqlite "select id from videos where status='done' and source='download' limit 1"`.

Then open `http://localhost:3050/` in a browser, log in, and confirm a video plays and a poster loads.

- [ ] **Step 4: Note the cache caveat**

Entries cached before this change are keyed without the cookie, so a stale copy of `/` could still reach an anonymous visitor for up to `CACHE_TTL_SECONDS` (300s) after deploy. Any mutating request flushes the whole cache; deliberately flush after deploying rather than waiting:

```bash
curl -s -X POST http://localhost:3050/api/library/scan -H "Authorization: Bearer $TOKEN" -o /dev/null
```

Confirm `curl -si http://localhost:3050/ | head -1` reports 303 afterwards.

- [ ] **Step 5: Document it in CLAUDE.md**

In the `### Auth` section of `CLAUDE.md`, after the existing paragraph, add:

```markdown
**The web page authenticates with a cookie, the iOS app with a Bearer header.**
`POST /login` (a single form field) sets an HttpOnly `upload_token` cookie
holding the raw `UPLOAD_TOKEN`; `GET /` and `/videos` 303 to `/login?next=…`
without it, and `GET /logout` clears it. `_check_token_or_query` accepts the
cookie alongside Bearer and `?token=`, so nothing in the rendered HTML carries
a token in its URL any more — but Caddy serves downloaded MP4s and HLS segments
off disk and runs the same check itself, so `@ptunauth` in
`~/c/server/Caddyfile` carries the matching `not header Cookie
*upload_token={env.UPLOAD_TOKEN}*` line. **Changing `UPLOAD_TOKEN` to include
characters outside `[A-Za-z0-9._~-]` makes Starlette quote the cookie value and
that Caddy matcher stops matching.** Write endpoints stay Bearer-only, and the
page still gets its own token from the server-rendered `window.UPLOAD_TOKEN` —
this gates access to the page, it does not hide the token from someone already
logged in. `middleware.cache_key_for` scopes cached responses by a hash of the
cookie, because the cache answers before the endpoint runs and would otherwise
hand an anonymous visitor a cached authenticated page.
```

- [ ] **Step 6: Commit both repos**

```bash
cd /Users/grillermo/c/patatatube
git add CLAUDE.md
git commit -m "docs: describe the web login cookie and its Caddy counterpart"

cd ~/c/server
git add Caddyfile
git commit -m "feat: accept patatatube's login cookie for disk-served media"
```

---

## Post-implementation check

- [ ] `python -m pytest tests/ -v` — full suite green.
- [ ] `grep -rn "token=" views/templates/` returns nothing.
- [ ] The iOS app is untouched: `git status ios/` is clean, and `APIClient` still sends Bearer, so no iOS test needs to run.
