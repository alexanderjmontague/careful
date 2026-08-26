import Foundation

enum BlockPage {
    /// The page lives on disk once; the blocked site and reason ride in the URL fragment
    /// so a redirect never has to rewrite the file.
    static func install() {
        try? html.write(to: Paths.blockPage, atomically: true, encoding: .utf8)
    }

    static func url(site: String, reason: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let s = site.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let r = reason.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return Paths.blockPage.absoluteString + "#site=" + s + "&reason=" + r
    }

    private static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Blocked</title>
    <style>
      :root { color-scheme: light dark; }
      html,body { height:100%; margin:0; }
      body {
        display:flex; align-items:center; justify-content:center;
        font: 400 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        background:#faf9f7; color:#1a1a1a;
      }
      @media (prefers-color-scheme: dark) { body { background:#141414; color:#ededed; } }
      .card { text-align:center; max-width:32rem; padding:2rem; }
      .mark {
        width:56px; height:56px; margin:0 auto 1.75rem; border-radius:14px;
        background:#1a1a1a; color:#faf9f7; display:flex; align-items:center; justify-content:center;
        font-size:26px; font-weight:600;
      }
      @media (prefers-color-scheme: dark) { .mark { background:#ededed; color:#141414; } }
      h1 { font-size:1.5rem; font-weight:600; margin:0 0 .6rem; letter-spacing:-.02em; }
      .site { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size:.95rem;
              padding:.2rem .5rem; border-radius:6px; background:rgba(127,127,127,.16); }
      p { margin:.9rem 0 0; opacity:.62; font-size:.95rem; }
    </style></head>
    <body><div class="card">
      <div class="mark">&#10005;</div>
      <h1>Blocked</h1>
      <div><span class="site" id="site">this site</span></div>
      <p id="reason"></p>
    </div>
    <script>
      var p = new URLSearchParams(location.hash.slice(1));
      if (p.get('site')) document.getElementById('site').textContent = p.get('site');
      document.getElementById('reason').textContent = p.get('reason') || '';
      document.title = 'Blocked \\u2014 ' + (p.get('site') || '');
    </script></body></html>
    """
}
