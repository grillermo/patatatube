from html import escape

# filename, CSS device width, CSS device height, pixel ratio, orientation
SPLASH_STARTUP_IMAGES = (
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_portrait.png", 320, 568, 2, "portrait"),
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_landscape.png", 320, 568, 2, "landscape"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_portrait.png", 375, 667, 2, "portrait"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_landscape.png", 375, 667, 2, "landscape"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_portrait.png", 414, 736, 3, "portrait"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_landscape.png", 414, 736, 3, "landscape"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_portrait.png", 375, 812, 3, "portrait"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_landscape.png", 375, 812, 3, "landscape"),
    ("iPhone_11__iPhone_XR_portrait.png", 414, 896, 2, "portrait"),
    ("iPhone_11__iPhone_XR_landscape.png", 414, 896, 2, "landscape"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_portrait.png", 414, 896, 3, "portrait"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_landscape.png", 414, 896, 3, "landscape"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_portrait.png", 390, 844, 3, "portrait"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_landscape.png", 390, 844, 3, "landscape"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_portrait.png", 428, 926, 3, "portrait"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_landscape.png", 428, 926, 3, "landscape"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_portrait.png", 393, 852, 3, "portrait"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_landscape.png", 393, 852, 3, "landscape"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_portrait.png", 430, 932, 3, "portrait"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_landscape.png", 430, 932, 3, "landscape"),
    ("iPhone_Air_landscape.png", 420, 912, 3, "landscape"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_portrait.png", 402, 874, 3, "portrait"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_landscape.png", 402, 874, 3, "landscape"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png", 440, 956, 3, "portrait"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_landscape.png", 440, 956, 3, "landscape"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_portrait.png", 768, 1024, 2, "portrait"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_landscape.png", 768, 1024, 2, "landscape"),
    ("10.2__iPad_portrait.png", 810, 1080, 2, "portrait"),
    ("10.2__iPad_landscape.png", 810, 1080, 2, "landscape"),
    ("10.5__iPad_Air_portrait.png", 834, 1112, 2, "portrait"),
    ("10.5__iPad_Air_landscape.png", 834, 1112, 2, "landscape"),
    ("10.9__iPad_Air_portrait.png", 820, 1180, 2, "portrait"),
    ("10.9__iPad_Air_landscape.png", 820, 1180, 2, "landscape"),
    ("8.3__iPad_Mini_portrait.png", 744, 1133, 2, "portrait"),
    ("8.3__iPad_Mini_landscape.png", 744, 1133, 2, "landscape"),
    ("11__iPad_Pro__10.5__iPad_Pro_portrait.png", 834, 1194, 2, "portrait"),
    ("11__iPad_Pro__10.5__iPad_Pro_landscape.png", 834, 1194, 2, "landscape"),
    ("11__iPad_Pro_M4_portrait.png", 834, 1210, 2, "portrait"),
    ("11__iPad_Pro_M4_landscape.png", 834, 1210, 2, "landscape"),
    ("12.9__iPad_Pro_portrait.png", 1024, 1366, 2, "portrait"),
    ("12.9__iPad_Pro_landscape.png", 1024, 1366, 2, "landscape"),
    ("13__iPad_Pro_M4_portrait.png", 1032, 1376, 2, "portrait"),
    ("13__iPad_Pro_M4_landscape.png", 1032, 1376, 2, "landscape"),
    ("iphone-16-pro-max.jpg", 440, 956, 3, "portrait"),
    ("iphone-15-pro-max.jpg", 430, 932, 3, "portrait"),
    ("iphone-15-14-pro.jpg", 393, 852, 3, "portrait"),
    ("iphone-13-12-pro.jpg", 390, 844, 3, "portrait"),
    ("iphone-14-plus.jpg", 428, 926, 3, "portrait"),
    ("iphone-11-pro-max-xs-max.jpg", 414, 896, 3, "portrait"),
    ("iphone-11-xr.jpg", 414, 896, 2, "portrait"),
    ("iphone-8-plus.jpg", 414, 736, 3, "portrait"),
)


def _status_badge(status: str) -> str:
    colors = {"queued": "#888", "downloading": "#f90", "done": "#0a0", "error": "#c00"}
    return f'<span style="color:{colors.get(status,"#888")};font-size:0.8em">{status}</span>'


def _splash_startup_link(filename: str, width: int, height: int, scale: int, orientation: str) -> str:
    media = (
        f"(device-width: {width}px) and (device-height: {height}px) "
        f"and (-webkit-device-pixel-ratio: {scale}) and (orientation: {orientation})"
    )
    return (
        '<link rel="apple-touch-startup-image" '
        f'media="{media}" href="/assets/splash/{escape(filename, quote=True)}">'
    )


def _splash_startup_links() -> str:
    links = ['<link rel="apple-touch-startup-image" href="/apple-splash-optimized.jpg">']
    links.extend(_splash_startup_link(*image) for image in SPLASH_STARTUP_IMAGES)
    return "\n".join(links)


def _classification_menu(video_id: int, current_cls: str | None, classifications: list[str], page_classification: str | None) -> str:
    page_cls_input = f'<input type="hidden" name="current_classification" value="{escape(page_classification or "")}">'
    items = []
    for cls in classifications:
        active = " active-cls" if cls == (current_cls or "children") else ""
        items.append(
            f'<form method="post" action="/videos/{video_id}/classify">'
            f'{page_cls_input}'
            f'<input type="hidden" name="classification" value="{escape(cls)}">'
            f'<button type="submit" class="menu-btn{active}">{escape(cls)}</button>'
            f'</form>'
        )
    return (
        '<details class="menu">'
        '<summary>&#8942;</summary>'
        f'<div class="menu-dropdown">{"".join(items)}</div>'
        '</details>'
    )


def build_videos_page(videos: list[dict], classifications: list[str], current_classification: str | None) -> str:
    cards = []
    for v in videos:
        title = escape(v["title"]) if v.get("platform") == "youtube" and v.get("title") else None
        cls_menu = _classification_menu(v["id"], v.get("classification"), classifications, current_classification)

        if v["status"] == "done":
            name_text = title if title else escape(v["url"][:60]) + ("…" if len(v["url"]) > 60 else "")
            player = f"""
            <div class="video-wrap">
              <div class="name-overlay">{name_text}</div>
              <video id="v{v['id']}" controls playsinline webkit-playsinline preload="none"
                     onloadedmetadata="this.currentTime=0">
                <source src="/videos/{v['id']}/stream" type="video/mp4">
              </video>
            </div>"""
        elif v["status"] == "error":
            player = f'<p style="color:#c00;font-size:0.85em">Error: {escape(v.get("error_msg","unknown"))}</p>'
        else:
            player = f'<p style="color:#aaa;font-size:0.85em">Video is {v["status"]}…</p>'

        page_cls_input = f'<input type="hidden" name="classification" value="{escape(current_classification or "")}">'
        cards.append(f"""
        <div class="card">
          {cls_menu}
          {player}
          <div class="move">
            <form method="post" action="/videos/{v['id']}/move">
              <input type="hidden" name="direction" value="up">
              {page_cls_input}
              <button type="submit" aria-label="Move up">&#9650;</button>
            </form>
            <form method="post" action="/videos/{v['id']}/move">
              <input type="hidden" name="direction" value="down">
              {page_cls_input}
              <button type="submit" aria-label="Move down">&#9660;</button>
            </form>
          </div>
        </div>""")

    cards_html = "\n".join(cards) if cards else '<p style="color:#aaa;text-align:center">No videos yet.</p>'
    splash_links = _splash_startup_links()

    nav_links = []
    for cls in classifications:
        active_cls = " active" if cls == current_classification else ""
        nav_links.append(f'<a href="/?classification={escape(cls, quote=True)}" class="nav-link{active_cls}">{escape(cls)}</a>')
    nav_html = f'<nav class="nav">{"".join(nav_links)}</nav>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Patata Videos</title>
<meta name="theme-color" content="#111111">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Videos">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
{splash_links}
<link rel="manifest" href="/manifest.webmanifest">
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:12px;padding-top:calc(12px + env(safe-area-inset-top));padding-bottom:calc(12px + env(safe-area-inset-bottom));padding-left:calc(12px + env(safe-area-inset-left));padding-right:calc(12px + env(safe-area-inset-right));}}
  @media (display-mode: standalone) {{
    body{{min-height:100dvh}}
  }}
  .nav{{display:flex;gap:8px;overflow-x:auto;padding-bottom:10px;margin-bottom:12px;max-width:900px;margin-left:auto;margin-right:auto;scrollbar-width:none}}
  .nav::-webkit-scrollbar{{display:none}}
  .nav-link{{padding:6px 16px;border-radius:20px;background:#2a2a2a;color:#aaa;text-decoration:none;white-space:nowrap;font-size:0.9em;flex-shrink:0}}
  .nav-link.active{{background:#4a9eff;color:#fff}}
  .grid{{display:grid;grid-template-columns:1fr;gap:14px;max-width:480px;margin:0 auto}}
  @media (orientation:landscape) and (min-width:600px){{
    .grid{{grid-template-columns:1fr 1fr;max-width:900px}}
  }}
  .card{{background:#1e1e1e;border-radius:10px;padding:12px;position:relative}}
  .meta{{font-size:0.78em;color:#aaa;margin-bottom:8px;word-break:break-all}}
  .title{{font-size:1.15em;color:#eee;margin-bottom:4px;word-break:break-word}}
  video{{display:block;width:100%;height:100%;object-fit:contain}}
  .video-wrap{{position:relative;aspect-ratio:16/9;background:#000;border-radius:8px;overflow:hidden}}
  .name-overlay{{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;padding:16px;font-size:1.6em;font-weight:600;color:#eee;background:#000;border-radius:8px;pointer-events:none;word-break:break-word}}
  .video-wrap.is-playing .name-overlay{{display:none}}
  .move{{display:flex;gap:8px;margin-top:8px;justify-content:flex-end}}
  .move form{{margin:0}}
  .move button{{background:#2a2a2a;color:#eee;border:1px solid #3a3a3a;border-radius:6px;padding:6px 12px;font-size:1em;cursor:pointer}}
  .move button:active{{background:#3a3a3a}}
  .menu{{position:absolute;top:10px;right:10px;z-index:10}}
  .menu>summary{{list-style:none;cursor:pointer;background:#2a2a2a;border:1px solid #3a3a3a;border-radius:6px;padding:2px 9px;font-size:1.3em;color:#eee;user-select:none;-webkit-user-select:none}}
  .menu>summary::-webkit-details-marker{{display:none}}
  .menu-dropdown{{position:absolute;right:0;top:calc(100% + 4px);background:#2a2a2a;border:1px solid #3a3a3a;border-radius:8px;overflow:hidden;min-width:140px;z-index:20;box-shadow:0 4px 12px rgba(0,0,0,0.5)}}
  .menu-dropdown form{{margin:0}}
  .menu-btn{{display:block;width:100%;padding:10px 14px;background:transparent;color:#eee;border:none;border-bottom:1px solid #3a3a3a;text-align:left;font-size:0.9em;cursor:pointer;font-family:inherit}}
  .menu-dropdown form:last-child .menu-btn{{border-bottom:none}}
  .menu-btn:hover{{background:#3a3a3a}}
  .menu-btn.active-cls{{color:#4a9eff}}
</style>
</head>
<body>
<script>
(function(){{
  var params=new URLSearchParams(window.location.search);
  var cls=params.get('classification');
  if(cls){{
    document.cookie='preferred_classification='+encodeURIComponent(cls)+';path=/;max-age=31536000;SameSite=Lax';
  }}else{{
    var m=document.cookie.match(/(?:^|;\\s*)preferred_classification=([^;]+)/);
    if(m){{window.location.replace('/?classification='+m[1]);}}
  }}
}})();
</script>
<h2 style="text-align:center;margin-bottom:12px;font-size:1.1em;max-width:900px;margin-left:auto;margin-right:auto">Patata Videos</h2>
{nav_html}
<div class="grid">
{cards_html}
</div>
<script>
var activePreloadController = null;
var activePreloadVideoId = null;
var completedPreloads = new Set();

function stopAllPreloads(){{
  if(!activePreloadController) return;
  try {{ activePreloadController.abort(); }} catch (_err) {{}}
  activePreloadController = null;
  activePreloadVideoId = null;
}}

function resolveVideoSource(video){{
  if(video.currentSrc) return video.currentSrc;
  if(video.src) return video.src;
  var source = video.querySelector('source[src]');
  return source ? source.getAttribute('src') : null;
}}

function pauseOtherVideos(activeVideo){{
  document.querySelectorAll('video[id]').forEach(function(v){{
    if(v === activeVideo || v.paused || v.ended) return;
    try {{ v.pause(); }} catch (_err) {{}}
  }});
}}

function preloadEntireVideo(video){{
  if(typeof fetch !== 'function' || typeof AbortController === 'undefined') return;

  var src = resolveVideoSource(video);
  if(!src) return;
  if(completedPreloads.has(video.id)) return;
  if(activePreloadVideoId === video.id && activePreloadController) return;

  stopAllPreloads();
  var controller = new AbortController();
  activePreloadController = controller;
  activePreloadVideoId = video.id;

  fetch(src, {{ signal: controller.signal, cache: 'force-cache', credentials: 'same-origin' }})
    .then(function(resp){{
      if(activePreloadVideoId !== video.id || activePreloadController !== controller) return;
      if(!resp.ok || !resp.body || typeof resp.body.getReader !== 'function') return;

      var reader = resp.body.getReader();
      function pump(){{
        return reader.read().then(function(step){{
          if(step.done) {{
            completedPreloads.add(video.id);
            return;
          }}
          if(activePreloadVideoId !== video.id || activePreloadController !== controller) {{
            try {{ reader.cancel(); }} catch (_err) {{}}
            return;
          }}
          return pump();
        }});
      }}
      return pump();
    }})
    .catch(function(err){{
      if(err && err.name === 'AbortError') return;
    }})
    .finally(function(){{
      if(activePreloadVideoId === video.id && activePreloadController === controller) {{
        activePreloadVideoId = null;
        activePreloadController = null;
      }}
    }});
}}

function exitFullscreen(v){{
  try {{
    if(v && typeof v.webkitExitFullscreen === 'function' && v.webkitDisplayingFullscreen) {{
      v.webkitExitFullscreen();
      return;
    }}
    if(document.exitFullscreen && document.fullscreenElement) {{
      var p = document.exitFullscreen();
      if(p && typeof p.catch === 'function') p.catch(function(){{}});
    }} else if(document.webkitExitFullscreen && document.webkitFullscreenElement) {{
      document.webkitExitFullscreen();
    }}
  }} catch(e) {{}}
}}

function enterFullscreen(v){{
  if(document.fullscreenElement || document.webkitFullscreenElement) return;
  if(v.webkitDisplayingFullscreen) return;
  try {{
    if(typeof v.webkitEnterFullscreen === 'function') {{
      v.webkitEnterFullscreen();
    }} else if(typeof v.requestFullscreen === 'function') {{
      var p = v.requestFullscreen();
      if(p && typeof p.catch === 'function') p.catch(function(){{}});
    }} else if(typeof v.webkitRequestFullscreen === 'function') {{
      v.webkitRequestFullscreen();
    }}
  }} catch(e) {{}}
}}

document.querySelectorAll('video[id]').forEach(function(v){{
  var wrap = v.closest('.video-wrap');
  v.addEventListener('play', function(){{
    if(wrap) wrap.classList.add('is-playing');
    pauseOtherVideos(v);
    preloadEntireVideo(v);
    enterFullscreen(v);
  }});
  v.addEventListener('pause', function(){{
    if(wrap) wrap.classList.remove('is-playing');
    if(activePreloadVideoId === v.id) {{
      stopAllPreloads();
    }}
  }});
  v.addEventListener('ended', function(){{
    if(wrap) wrap.classList.remove('is-playing');
    if(activePreloadVideoId === v.id) {{
      stopAllPreloads();
    }}
    exitFullscreen(v);
  }});
}});

window.addEventListener('pagehide', stopAllPreloads);
document.addEventListener('visibilitychange', function(){{
  if(document.hidden) stopAllPreloads();
}});
</script>
</body>
</html>"""
