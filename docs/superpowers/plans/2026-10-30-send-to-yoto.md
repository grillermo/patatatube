# Send to Yoto Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Send to Yoto de Elisa" item in the iOS video menu that sends the video's audio, as MP3, to the English card of the yosubee user `hola@grillermo.com`.

**Architecture:** iOS calls a new PatataTube endpoint, `POST /api/videos/{id}/yoto`. PatataTube POSTs `{path, title}` over localhost to yosubee's Caddy port 3200, at `/upload-from-video?user=…&playlist_name=English`. yosubee checks a shared token, finds the user and the card, and creates an `UploadRun` with a new `local` source. Its downloader is an ffmpeg `-vn` conversion of the file at `path`. From there the run follows the existing pipeline (upload to Yoto, icon pick in yosubee's UI, finalize). No media bytes cross HTTP, and PatataTube spawns no ffmpeg.

**Tech Stack:** FastAPI + httpx (PatataTube), Rails 8.1 + RSpec + Solid Queue (yosubee, `~/c/yosubee`), SwiftUI + PatataTubeKit (iOS).

**Spec:** `docs/superpowers/specs/2026-10-30-send-to-yoto-design.md`

**Repos:** Tasks 1–3 and 7–8 commit in `~/c/patatatube`. Tasks 4–6 commit in `~/c/yosubee`. Both use git-sync, so commit locally and never push by hand.

---

## File map

PatataTube
- Create `yosubee.py`: the outbound localhost call, `send(path, title)`. It reads env at call time.
- Modify `router.py`: the `POST /api/videos/{id}/yoto` handler, next to `api_mark_played`.
- Create `tests/test_yosubee.py`: client tests with `httpx.MockTransport`.
- Modify `tests/test_api.py`: endpoint tests.
- Modify `.env.example`, `CLAUDE.md`.

yosubee
- Create `app/services/local_audio_convert_service.rb`: ffmpeg mp4 → mp3.
- Modify `app/services/upload_source.rb`: `LocalSource`.
- Modify `app/models/upload_run.rb`: accept `file://` urls for `source == "local"`.
- Create `app/controllers/local_uploads_controller.rb`, and modify `config/routes.rb`.
- Create `spec/services/local_audio_convert_service_spec.rb`, `spec/requests/local_uploads_spec.rb`.

iOS
- Modify `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`: `sendToYoto` on `VideoAPI` (defaulted) and `APIClient`.
- Modify `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`: `sendToYoto(id:)` and `noticeText`.
- Modify `ios/PatataTube/Sources/VideoRow.swift`, `VideoCell.swift`: the menu item.
- Modify `ios/PatataTube/Sources/VideoGridView.swift`: wiring plus the notice banner.

---

### Task 1: PatataTube → yosubee client (`yosubee.py`)

**Files:**
- Create: `yosubee.py`
- Test: `tests/test_yosubee.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_yosubee.py
import json

import httpx
import pytest

import yosubee

URL = "http://localhost:3200/upload-from-video?user=hola@grillermo.com&playlist_name=English"


@pytest.fixture()
def configured(monkeypatch):
    monkeypatch.setenv("YOSUBEE_LOCAL_URL", URL)
    monkeypatch.setenv("YOSUBEE_LOCAL_TOKEN", "local-secret")


@pytest.mark.asyncio
async def test_send_posts_path_title_and_token(configured):
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(202, json={"job_id": "abc"})

    await yosubee.send("/media/videos/7.mp4", "A title", transport=httpx.MockTransport(handler))

    req = seen[0]
    assert str(req.url) == URL
    assert req.headers["X-Local-Token"] == "local-secret"
    assert json.loads(req.content) == {"path": "/media/videos/7.mp4", "title": "A title"}


@pytest.mark.asyncio
async def test_send_raises_with_yosubee_error_message(configured):
    transport = httpx.MockTransport(lambda r: httpx.Response(422, json={"error": "No card named English"}))
    with pytest.raises(yosubee.YosubeeError, match="No card named English"):
        await yosubee.send("/p.mp4", "t", transport=transport)


@pytest.mark.asyncio
async def test_send_raises_on_connect_error(configured):
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    with pytest.raises(yosubee.YosubeeError, match="unreachable"):
        await yosubee.send("/p.mp4", "t", transport=httpx.MockTransport(handler))


def test_not_configured_without_url(monkeypatch):
    monkeypatch.delenv("YOSUBEE_LOCAL_URL", raising=False)
    assert yosubee.configured() is False
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MEDIA_ROOT=. python -m pytest tests/test_yosubee.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'yosubee'`

- [ ] **Step 3: Implement**

```python
# yosubee.py
"""Hands a finished video to yosubee, which runs on the same machine.

Only the file's path crosses the wire: yosubee reads the mp4 off the shared
disk and does the MP3 conversion itself, so nothing here spawns ffmpeg and no
media bytes go over HTTP. YOSUBEE_LOCAL_URL points at yosubee's Caddy port
(3200), never a Rails port: Rails alternates between 3201 and 3202 on deploys.
"""

import os

import httpx

TIMEOUT_SECS = 5.0


class YosubeeError(Exception):
    pass


def configured() -> bool:
    return bool(os.getenv("YOSUBEE_LOCAL_URL"))


async def send(path: str, title: str, transport: httpx.AsyncBaseTransport | None = None) -> None:
    url = os.getenv("YOSUBEE_LOCAL_URL", "")
    headers = {"X-Local-Token": os.getenv("YOSUBEE_LOCAL_TOKEN", "")}
    # trust_env=False: see CLAUDE.md "Every httpx call passes trust_env=False".
    async with httpx.AsyncClient(timeout=TIMEOUT_SECS, trust_env=False, transport=transport) as client:
        try:
            resp = await client.post(url, json={"path": path, "title": title}, headers=headers)
        except httpx.HTTPError as e:
            raise YosubeeError(f"yosubee unreachable: {e}") from e
    if resp.is_success:
        return
    try:
        message = resp.json().get("error") or resp.text
    except ValueError:
        message = resp.text
    raise YosubeeError(f"yosubee {resp.status_code}: {message}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `MEDIA_ROOT=. python -m pytest tests/test_yosubee.py -v`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add yosubee.py tests/test_yosubee.py
git commit -m "feat: localhost client for sending a video to yosubee"
```

---

### Task 2: `POST /api/videos/{id}/yoto`

**Files:**
- Modify: `router.py`. Add `import yosubee` to the local imports block (alphabetical, after `import services`). Add the handler right after `api_mark_played`, around line 1212.
- Test: `tests/test_api.py` (append)

- [ ] **Step 1: Write the failing tests** (append to `tests/test_api.py`)

```python
# --- Send to Yoto ---------------------------------------------------------

@pytest.fixture()
def yoto_sent(monkeypatch, tmp_path):
    """Captures yosubee.send calls and points VIDEOS_DIR at tmp_path."""
    import router
    import yosubee

    calls = []

    async def fake_send(path, title, transport=None):
        calls.append((path, title))

    monkeypatch.setenv("YOSUBEE_LOCAL_URL", "http://localhost:3200/upload-from-video")
    monkeypatch.setattr(yosubee, "send", fake_send)
    monkeypatch.setattr(router, "VIDEOS_DIR", tmp_path)
    return calls


def _done_video(tmp_path, title="Song"):
    import db

    vid = db.add_video("https://youtube.com/watch?v=abc", title=title)
    db.update_video(vid, status="done", filename=f"{vid}.mp4")
    (tmp_path / f"{vid}.mp4").write_bytes(b"mp4")
    return vid


def test_send_to_yoto_posts_absolute_path_and_title(client, auth_headers, yoto_sent, tmp_path):
    vid = _done_video(tmp_path, title="Twinkle")
    resp = client.post(f"/api/videos/{vid}/yoto", headers=auth_headers)
    assert resp.status_code == 202
    assert resp.json() == {"status": "sent"}
    assert yoto_sent == [(str((tmp_path / f"{vid}.mp4").resolve()), "Twinkle")]


def test_send_to_yoto_requires_token(client, yoto_sent, tmp_path):
    vid = _done_video(tmp_path)
    assert client.post(f"/api/videos/{vid}/yoto").status_code == 401


def test_send_to_yoto_503_when_unconfigured(client, auth_headers, yoto_sent, tmp_path, monkeypatch):
    monkeypatch.delenv("YOSUBEE_LOCAL_URL")
    vid = _done_video(tmp_path)
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 503


def test_send_to_yoto_404_unknown(client, auth_headers, yoto_sent):
    assert client.post("/api/videos/999999/yoto", headers=auth_headers).status_code == 404


def test_send_to_yoto_409_while_downloading(client, auth_headers, yoto_sent):
    import db

    vid = db.add_video("https://youtube.com/watch?v=abc")
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 409
    assert yoto_sent == []


def test_send_to_yoto_409_for_library_rows(client, auth_headers, yoto_sent, tmp_path):
    import db

    vid = _done_video(tmp_path)
    with db._conn() as conn:
        conn.execute("UPDATE videos SET source = 'library', plex_kind = 'movie' WHERE id = ?", (vid,))
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 409
    assert yoto_sent == []


def test_send_to_yoto_409_when_file_missing(client, auth_headers, yoto_sent, tmp_path):
    vid = _done_video(tmp_path)
    (tmp_path / f"{vid}.mp4").unlink()
    assert client.post(f"/api/videos/{vid}/yoto", headers=auth_headers).status_code == 409


def test_send_to_yoto_502_when_yosubee_fails(client, auth_headers, yoto_sent, tmp_path, monkeypatch):
    import yosubee

    async def failing(path, title, transport=None):
        raise yosubee.YosubeeError("yosubee 422: No card named English")

    monkeypatch.setattr(yosubee, "send", failing)
    vid = _done_video(tmp_path)
    resp = client.post(f"/api/videos/{vid}/yoto", headers=auth_headers)
    assert resp.status_code == 502
    assert "No card named English" in resp.json()["detail"]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MEDIA_ROOT=. python -m pytest tests/test_api.py -k send_to_yoto -v`
Expected: FAIL. Everything returns 404 or 405 because the route doesn't exist.

- [ ] **Step 3: Implement** (in `router.py` after `api_mark_played`)

```python
@router.post("/api/videos/{video_id}/yoto", status_code=202)
async def api_send_to_yoto(video_id: int, request: Request):
    """Send a finished video's audio to the Yoto card yosubee is configured for.

    Fire and forget: yosubee only enqueues (convert, upload, wait for an icon
    pick in its own UI), so a 202 here means "accepted", not "on the card".
    Plex rows are refused because the menu never offers them for TV/Movies.
    """
    _check_token(request)
    if not yosubee.configured():
        raise HTTPException(status_code=503, detail="Yoto not configured")
    video = db.get_video(video_id)
    if not video or video.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Video not found")
    if video.get("source") == "library" or video.get("plex_kind"):
        raise HTTPException(status_code=409, detail="Library videos can't be sent to Yoto")
    if video.get("status") != "done" or not video.get("filename"):
        raise HTTPException(status_code=409, detail="Video isn't downloaded yet")
    path = (VIDEOS_DIR / video["filename"]).resolve()
    if not path.is_file():
        raise HTTPException(status_code=409, detail="Video file is missing")
    try:
        await yosubee.send(str(path), video.get("title") or path.stem)
    except yosubee.YosubeeError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"status": "sent"}
```

Call `yosubee.send` through the module (not `from yosubee import send`) so the tests' monkeypatch takes effect.

- [ ] **Step 4: Run the tests to verify they pass, then the full suite**

Run: `MEDIA_ROOT=. python -m pytest tests/test_api.py -k send_to_yoto -v`
Expected: 8 passed
Run: `MEDIA_ROOT=. python -m pytest tests/`
Expected: no new failures compared to `main`

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: POST /api/videos/{id}/yoto hands a video to yosubee"
```

---

### Task 3: PatataTube config and docs

**Files:**
- Modify: `.env.example`, `CLAUDE.md`

- [ ] **Step 1: Append to `.env.example`**

```
# Send to Yoto: yosubee on the same machine, via its Caddy port (not 3201/3202).
YOSUBEE_LOCAL_URL=http://localhost:3200/upload-from-video?user=hola@grillermo.com&playlist_name=English
# Must equal LOCAL_UPLOAD_TOKEN in ~/c/yosubee/.env
YOSUBEE_LOCAL_TOKEN=
```

- [ ] **Step 2: Add a section to `CLAUDE.md`** under Architecture, after the `/sd` section:

```markdown
### Send to Yoto

The iOS video menu's "Send to Yoto de Elisa" (not on TV/Movies) calls
`POST /api/videos/{id}/yoto`, which POSTs `{path, title}` to
`YOSUBEE_LOCAL_URL`, yosubee (`~/c/yosubee`) on this same machine, with
`X-Local-Token: YOSUBEE_LOCAL_TOKEN`. Only the **path** crosses: yosubee
reads the mp4 off the shared disk and converts it to MP3 itself, so this adds
no ffmpeg call site here. The URL targets yosubee's Caddy port 3200, because
its Rails slots alternate between 3201 and 3202 across deploys. The query string
picks the yosubee user and the card (matched by title). It's fire and forget:
202 means yosubee queued it. The run then waits in yosubee's UI for an icon pick.
Unset URL → 503.
```

- [ ] **Step 3: Commit**

```bash
git add .env.example CLAUDE.md
git commit -m "docs: Send to Yoto config"
```

---

### Task 4: yosubee `local` source and converter

Work in `~/c/yosubee`. Run `git status` first. The tree should be clean. If it isn't, stop and ask.

**Files:**
- Create: `app/services/local_audio_convert_service.rb`
- Modify: `app/services/upload_source.rb`, `app/models/upload_run.rb` (`upload_url_must_be_supported`)
- Test: `spec/services/local_audio_convert_service_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/services/local_audio_convert_service_spec.rb
require "rails_helper"

RSpec.describe LocalAudioConvertService do
  let(:user) { User.create!(email: "local@test.com") }
  let(:workspace) { Dir.mktmpdir }
  let(:run) do
    user.upload_runs.create!(
      session_identifier: "patatatube",
      upload_url: "file:///media/videos/7.mp4",
      yoto_card_url: "card-1",
      status: :queued,
      source: "local",
      title: "Twinkle"
    )
  end

  after { FileUtils.rm_rf(workspace) }

  it "runs ffmpeg -vn from the run's path into workspace/audio.mp3" do
    out = File.join(workspace, "audio.mp3")
    expect(Open3).to receive(:capture3)
      .with(LocalAudioConvertService::FFMPEG_PATH, "-y", "-i", "/media/videos/7.mp4",
            "-vn", "-acodec", "libmp3lame", "-q:a", "2", out) do
        File.write(out, "mp3")
        ["", "", instance_double(Process::Status, success?: true)]
      end

    progress = []
    path = described_class.new.download(run.id, workspace) { |pct, msg| progress << [pct, msg] }

    expect(path).to eq(out)
    expect(progress.map(&:first)).to eq([10, 40])
  end

  it "raises when ffmpeg fails" do
    allow(Open3).to receive(:capture3)
      .and_return(["", "boom", instance_double(Process::Status, success?: false)])

    expect { described_class.new.download(run.id, workspace) }
      .to raise_error(LocalAudioConvertService::ConvertError, /boom/)
  end

  it "is the downloader for the local source" do
    expect(UploadSource.for("local").downloader).to be_a(described_class)
    expect(run).to be_valid
  end

  it "rejects file:// urls on non-local runs" do
    run.source = "youtube"
    expect(run).not_to be_valid
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ~/c/yosubee && bundle exec rspec spec/services/local_audio_convert_service_spec.rb`
Expected: FAIL with `uninitialized constant LocalAudioConvertService`

- [ ] **Step 3: Implement the converter**

```ruby
# app/services/local_audio_convert_service.rb
require "open3"
require "fileutils"

# Downloader for runs handed over by PatataTube on the same machine: the
# upload_url is file://<path to an mp4 on the shared disk>, so "download" is
# just an ffmpeg audio extraction into the run's workspace.
class LocalAudioConvertService
  class ConvertError < StandardError; end

  FFMPEG_PATH = ENV.fetch("FFMPEG_PATH", "/opt/homebrew/bin/ffmpeg")

  def download(upload_run_id, workspace_path, &block)
    source = UploadRun.find(upload_run_id).upload_url.delete_prefix("file://")
    FileUtils.mkdir_p(workspace_path)
    output = File.join(workspace_path, "audio.mp3")

    block&.call(10, "Converting to mp3...")
    _out, err, status = Open3.capture3(FFMPEG_PATH, "-y", "-i", source,
                                       "-vn", "-acodec", "libmp3lame", "-q:a", "2", output)
    raise ConvertError, "ffmpeg failed: #{err}" unless status.success? && File.exist?(output)

    block&.call(40, "Audio ready: #{File.basename(output)}")
    output
  end
end
```

- [ ] **Step 4: Add `LocalSource`** in `app/services/upload_source.rb`. Add a `when` branch:

```ruby
    when "local"   then LocalSource.new
```

and the class, after `GdriveSource`:

```ruby
  # Handed over by PatataTube (LocalUploadsController): the file is already on
  # this disk and the title came with the request. The :default lane, so a slow
  # Drive queue never holds it up.
  class LocalSource
    def queue = :default
    def downloader = LocalAudioConvertService.new

    def resolve_title(run)
      run.title.presence || File.basename(run.upload_url, ".*")
    end
  end
```

- [ ] **Step 5: Let `local` runs pass URL validation.** In `app/models/upload_run.rb`, `upload_url_must_be_supported` becomes:

```ruby
  def upload_url_must_be_supported
    return if upload_url.blank?
    return if source == "local" && upload_url.start_with?("file://")
    return if download_source

    errors.add(:upload_url, "must be a YouTube or Google Drive URL")
  end
```

`UploadInput` still never classifies `file://`, so the public form can't create one.

- [ ] **Step 6: Run the spec and the suite**

Run: `bundle exec rspec spec/services/local_audio_convert_service_spec.rb`
Expected: 4 examples, 0 failures
Run: `bundle exec rspec`
Expected: no new failures

- [ ] **Step 7: Commit**

```bash
git add app/services/local_audio_convert_service.rb app/services/upload_source.rb app/models/upload_run.rb spec/services/local_audio_convert_service_spec.rb
git commit -m "feat: local upload source converting an on-disk mp4 to mp3"
```

---

### Task 5: yosubee `POST /upload-from-video`

**Files:**
- Create: `app/controllers/local_uploads_controller.rb`
- Modify: `config/routes.rb`
- Test: `spec/requests/local_uploads_spec.rb`

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/local_uploads_spec.rb
require "rails_helper"

RSpec.describe "POST /upload-from-video", type: :request do
  let!(:user) { User.create!(email: "hola@grillermo.com") }
  let(:media_root) { Dir.mktmpdir }
  let(:video) { File.join(media_root, "7.mp4").tap { |p| File.write(p, "mp4") } }
  let(:cards) { [{ "cardId" => "card-en", "title" => "English" }, { "cardId" => "card-es", "title" => "Español" }] }
  let(:headers) { { "X-Local-Token" => "local-secret", "CONTENT_TYPE" => "application/json" } }
  let(:query) { "?user=hola@grillermo.com&playlist_name=English" }

  # No climate_control gem in this repo: set and restore ENV by hand.
  around do |ex|
    old = ENV.to_h.slice("LOCAL_UPLOAD_TOKEN", "PATATATUBE_MEDIA_ROOT")
    ENV["LOCAL_UPLOAD_TOKEN"] = "local-secret"
    ENV["PATATATUBE_MEDIA_ROOT"] = media_root
    ex.run
  ensure
    %w[LOCAL_UPLOAD_TOKEN PATATATUBE_MEDIA_ROOT].each { |k| old.key?(k) ? ENV[k] = old[k] : ENV.delete(k) }
  end

  before do
    api = instance_double(YotoApiClient, list_cards: cards)
    allow(YotoApiClient).to receive(:new).and_return(api)
    allow_any_instance_of(UploadRun).to receive(:start_processing!)
  end

  after { FileUtils.rm_rf(media_root) }

  def post_video(path: video, title: "Twinkle", hdrs: headers, q: query)
    post "/upload-from-video#{q}", params: { path: path, title: title }.to_json, headers: hdrs
  end

  it "creates a local run on the named card and starts it" do
    expect_any_instance_of(UploadRun).to receive(:start_processing!)
    post_video
    expect(response).to have_http_status(:accepted)
    run = UploadRun.find(response.parsed_body["job_id"])
    expect(run).to have_attributes(
      user: user, source: "local", yoto_card_url: "card-en",
      title: "Twinkle", upload_url: "file://#{File.realpath(video)}"
    )
    expect(run.workspace_path).to eq(Rails.root.join("upload_runs", run.id).to_s)
  end

  it "401s on a wrong token" do
    post_video(hdrs: headers.merge("X-Local-Token" => "nope"))
    expect(response).to have_http_status(:unauthorized)
  end

  it "503s when no token is configured" do
    ENV.delete("LOCAL_UPLOAD_TOKEN")
    post_video
    expect(response).to have_http_status(:service_unavailable)
  end

  it "404s an unknown user" do
    post_video(q: "?user=nobody@x.com&playlist_name=English")
    expect(response).to have_http_status(:not_found)
  end

  it "422s when no card has that title" do
    post_video(q: "?user=hola@grillermo.com&playlist_name=French")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("French")
  end

  it "422s when several cards share the title" do
    cards << { "cardId" => "card-en-2", "title" => "English" }
    post_video
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "422s a path outside the media root" do
    outside = Tempfile.new(["x", ".mp4"])
    post_video(path: outside.path)
    expect(response).to have_http_status(:unprocessable_content)
  ensure
    outside&.close!
  end

  it "422s a path that does not exist" do
    post_video(path: File.join(media_root, "missing.mp4"))
    expect(response).to have_http_status(:unprocessable_content)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/requests/local_uploads_spec.rb`
Expected: FAIL with routing errors (`No route matches [POST] "/upload-from-video"`)

- [ ] **Step 3: Add the route** in `config/routes.rb`, next to `match "/health"`:

```ruby
  post "/upload-from-video", to: "local_uploads#create"
```

- [ ] **Step 4: Implement the controller**

```ruby
# app/controllers/local_uploads_controller.rb

# Machine-to-machine entry for PatataTube, which runs on this same host and
# hands over the path of an mp4 on the shared disk. The token is mandatory:
# the Cloudflare tunnel also lands on Caddy's :3200, so being "local" proves
# nothing about who is calling.
class LocalUploadsController < ApplicationController
  skip_before_action :verify_authenticity_token, :set_locale, :log_visit, :track_pageview, :capture_referral

  def create
    expected = ENV["LOCAL_UPLOAD_TOKEN"].to_s
    return render_error(:service_unavailable, "Local uploads not configured") if expected.empty?
    unless ActiveSupport::SecurityUtils.secure_compare(request.headers["X-Local-Token"].to_s, expected)
      return render_error(:unauthorized, "Unauthorized")
    end

    user = User.find_by(email: params[:user].to_s)
    return render_error(:not_found, "No user #{params[:user]}") unless user

    path = allowed_path(params[:path].to_s)
    return render_error(:unprocessable_content, "Path not allowed") unless path

    matches = YotoApiClient.new(user).list_cards.select { |c| c["title"] == params[:playlist_name].to_s }
    return render_error(:unprocessable_content, "No card named #{params[:playlist_name]}") if matches.empty?
    return render_error(:unprocessable_content, "Several cards named #{params[:playlist_name]}") if matches.size > 1

    run = user.upload_runs.create!(
      session_identifier: "patatatube",
      upload_url: "file://#{path}",
      yoto_card_url: matches.first["cardId"],
      title: params[:title].to_s.presence,
      progress_pct: 0,
      status: :queued,
      source: "local"
    )
    run.update!(workspace_path: Rails.root.join("upload_runs", run.id).to_s)
    run.start_processing!

    render json: { job_id: run.id }, status: :accepted
  end

  private

  # Realpath under PATATATUBE_MEDIA_ROOT and an .mp4, or nil, so this
  # endpoint can't be pointed at arbitrary files on the machine.
  def allowed_path(raw)
    root = ENV["PATATATUBE_MEDIA_ROOT"].to_s
    return nil if root.empty? || raw.empty?

    real_root = File.realpath(root)
    real = File.realpath(raw)
    return nil unless real.start_with?("#{real_root}/") && File.extname(real).casecmp?(".mp4")

    real
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def render_error(status, message)
    render json: { error: message }, status: status
  end
end
```

- [ ] **Step 5: Run the spec and the suite**

Run: `bundle exec rspec spec/requests/local_uploads_spec.rb`
Expected: 8 examples, 0 failures
Run: `bundle exec rspec && bundle exec brakeman -q`
Expected: no new failures, no new brakeman warnings. If brakeman flags `File.realpath(raw)` as file access, the realpath + prefix check is the mitigation. Add a brakeman ignore entry with that note.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/local_uploads_controller.rb config/routes.rb spec/requests/local_uploads_spec.rb
git commit -m "feat: POST /upload-from-video for same-host PatataTube handoffs"
```

---

### Task 6: yosubee config and docs

- [ ] **Step 1: Document the env vars** in yosubee's `CLAUDE.md` under "Environment Variables":

```markdown
Optional (PatataTube "Send to Yoto"): `LOCAL_UPLOAD_TOKEN` (shared with
PatataTube's `YOSUBEE_LOCAL_TOKEN`; unset → `/upload-from-video` answers 503)
and `PATATATUBE_MEDIA_ROOT` (PatataTube's videos dir; the only tree that
endpoint will read from).
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: LOCAL_UPLOAD_TOKEN / PATATATUBE_MEDIA_ROOT"
```

---

### Task 7: iOS `sendToYoto` in PatataTubeKit

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`

- [ ] **Step 1: Protocol + default.** Add to `protocol VideoAPI`:

```swift
    func sendToYoto(id: Int) async throws
```

and to the `public extension VideoAPI` defaults block (so the test doubles keep compiling):

```swift
    func sendToYoto(id: Int) async throws { throw APIError.notConfigured }
```

- [ ] **Step 2: Real client.** In `APIClient`, after `markPlayed`:

```swift
    /// Hands the video to yosubee (same host as the server), which converts it
    /// to MP3 for the Yoto card. Fire and forget: success only means queued.
    public func sendToYoto(id: Int) async throws {
        _ = try await authedPost("api/videos/\(id)/yoto", body: [:])
    }
```

- [ ] **Step 3: Store.** In `VideoStore`, next to `errorText`:

```swift
    /// A short confirmation for the grid to show and clear (not an error).
    @Published public var noticeText: String?
```

and after `delete(id:)`:

```swift
    public func sendToYoto(id: Int) async {
        do {
            try await api.sendToYoto(id: id)
            noticeText = "Sent to Yoto de Elisa"
        } catch {
            report(error)
        }
    }
```

- [ ] **Step 4: Build**

Run: `cd ios/PatataTubeKit && swift build`
Expected: `Build complete!`

Don't run `swift test` (see CLAUDE.md). A `VideoStoreTests` case would cover this: a double whose `sendToYoto` succeeds sets `noticeText`, and one that throws sets `errorText`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift
git commit -m "feat(ios): sendToYoto API + store action"
```

---

### Task 8: iOS menu item + notice banner

**Files:**
- Modify: `ios/PatataTube/Sources/VideoRow.swift`, `ios/PatataTube/Sources/VideoCell.swift`, `ios/PatataTube/Sources/VideoGridView.swift`

- [ ] **Step 1: Closure on both views.** In `VideoRow` and `VideoCell`, below `let onDelete: () -> Void`, add a defaulted property so `PatataTube/Tests/VideoRowAudioTests.swift` and other call sites keep compiling:

```swift
    /// nil hides "Send to Yoto de Elisa" (Plex items never get it).
    var onSendToYoto: (() -> Void)? = nil
```

- [ ] **Step 2: Menu item.** In both menus, the `if !video.isPlexItem { Menu("Categorize", …) }` block becomes:

```swift
            if !video.isPlexItem {
                Menu("Categorize", systemImage: "folder") {
                    ForEach(groups) { group in
                        Button(group.label) { onSetGroup(group.id) }
                    }
                }
                if let onSendToYoto, video.status == "done" {
                    Button("Send to Yoto de Elisa", systemImage: "headphones") { onSendToYoto() }
                }
            }
```

(Keep each file's existing indentation. In `VideoCell` the block sits one level deeper.)

- [ ] **Step 3: Wire it in `VideoGridView`.** In both the `VideoRow(` and `VideoCell(` initializers, after `onDelete: { … }`:

```swift
                            onDelete: { Task { await store.delete(id: video.id) } },
                            onSendToYoto: { Task { await store.sendToYoto(id: video.id) } }
```

- [ ] **Step 4: Notice banner.** Next to `.overlay { if let error = store.errorText { errorBanner(error) } }`:

```swift
            .overlay { if let notice = store.noticeText { noticeBanner(notice) } }
```

and next to `errorBanner`:

```swift
    private func noticeBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .padding()
                .background(.green.opacity(0.85))
                .foregroundStyle(.white)
                .cornerRadius(8)
        }
        .padding(.bottom, 80)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(2))
            if store.noticeText == text { store.noticeText = nil }
        }
    }
```

Match `errorBanner`'s outer padding if it uses a different bottom inset, so the two banners line up.

- [ ] **Step 5: Build the app**

Run:
```bash
cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build -quiet
```
Expected: `** BUILD SUCCEEDED **`

Don't run `xcodebuild … test`. `PatataTubeTests` (ViewInspector) would cover the menu item's presence for a done non-Plex video and its absence for a Plex item.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoRow.swift ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): Send to Yoto de Elisa menu item"
```

---

### Task 9: Configure, restart, try it end to end (on the macmini)

Hand these steps to the user, or do them with their OK. They touch `.env` files and restart both servers.

- [ ] **Step 1:** Generate one token, and set it in both `.env` files without printing either file:
  - `~/c/patatatube/.env`: `YOSUBEE_LOCAL_URL=http://localhost:3200/upload-from-video?user=hola@grillermo.com&playlist_name=English` and `YOSUBEE_LOCAL_TOKEN=<token>`
  - `~/c/yosubee/.env`: `LOCAL_UPLOAD_TOKEN=<token>` and `PATATATUBE_MEDIA_ROOT=<PatataTube's VIDEOS_DIR, absolute>`
- [ ] **Step 2:** Restart PatataTube (`./serve`) and redeploy yosubee through its own `serve` script, so the new env loads.
- [ ] **Step 3:** Smoke test from the macmini:
  ```bash
  curl -s -X POST -H "Authorization: Bearer $UPLOAD_TOKEN" http://localhost:3050/api/videos/<a done youtube id>/yoto
  ```
  Expected: `{"status":"sent"}`. A new run appears in yosubee's dashboard, converts and uploads, then waits for an icon pick. After you pick one, the chapter shows up on the English card.
- [ ] **Step 4:** Ship iOS with the `deploy-ios` skill.
