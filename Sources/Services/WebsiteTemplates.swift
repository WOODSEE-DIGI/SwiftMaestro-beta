import Foundation

// MARK: - Website Templates
//
// Full-page HTML/CSS presets for the HTML Builder's Websites sidebar section.
// Unlike overlay templates (1920x1080 transparent), these render as real
// pages: fluid layout, opaque background, normal document flow.
// Selecting one loads it into the HTML/CSS editor for customization.

struct WebsiteTemplate: Sendable, Identifiable {
    let name: String
    let icon: String
    let description: String
    let html: String
    let css: String
    /// Natural pixel canvas for fixed-size assets (avatar 512, banner 1500x500).
    /// nil = fluid page layout, canvas left as-is.
    var canvasWidth: Int? = nil
    var canvasHeight: Int? = nil
    /// When true the preview pane renders the page fluidly like a browser.
    /// When false the page is framed at `canvasWidth` × `canvasHeight`.
    var fluid: Bool = true

    var id: String { name }
}

enum WebsiteTemplates {

    static let all: [WebsiteTemplate] = [blog, vlog, myspot, timble, memeLab, avatar, banner, linkBio, neonText]

    // MARK: - Blog

    static let blog = WebsiteTemplate(
        name: "Blog",
        icon: "text.justify.left",
        description: "Neocities-ready pastel personal blog: marquee, lace boxes, sidebar",
        html: """
        <div class="blog-page">
          <header class="blog-header">
            <div class="blog-logo">✿ my dream diary ✿</div>
            <div class="blog-marquee">welcome to my little corner of the internet ~ thanks for stopping by ~</div>
            <nav class="blog-nav">
              <a href="index.html">home</a>
              <a href="#">archive</a>
              <a href="#">about</a>
              <a href="#">guestbook</a>
            </nav>
          </header>
          <div class="blog-layout">
            <main class="blog-main">
              <article class="blog-post">
                <h2 class="blog-post-title">first entry ~</h2>
                <div class="blog-post-meta">september 17, 2026 ♥</div>
                <p>dear diary, today i started a new page on neocities. i can't wait to fill it with thoughts, art and blinkies.</p>
                <a class="blog-read-more" href="#">read more...</a>
              </article>
              <article class="blog-post">
                <h2 class="blog-post-title">a rainy afternoon</h2>
                <div class="blog-post-meta">september 10, 2026 ♥</div>
                <p>the sky was grey and i drank strawberry milk. sometimes quiet days are the best kind.</p>
                <a class="blog-read-more" href="#">read more...</a>
              </article>
            </main>
            <aside class="blog-sidebar">
              <div class="blog-widget">
                <h3>about me</h3>
                <p>hi! i'm a dreamer who loves pixels, pastels and old web goodies.</p>
              </div>
              <div class="blog-widget">
                <h3>links</h3>
                <ul>
                  <li><a href="#">my shrines</a></li>
                  <li><a href="#">my art</a></li>
                  <li><a href="#">cool sites</a></li>
                </ul>
              </div>
              <div class="blog-widget">
                <h3>tags</h3>
                <div class="blog-tags">
                  <span class="blog-tag">pink</span>
                  <span class="blog-tag">diary</span>
                  <span class="blog-tag">kawaii</span>
                </div>
              </div>
            </aside>
          </div>
          <footer class="blog-footer">
            made with love ♡ 2026
          </footer>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: "Comic Sans MS", "Chalkboard SE", "Trebuchet MS", cursive, sans-serif;
          background: #fff0f6;
          background-image:
            radial-gradient(#ffd6e8 15%, transparent 16%),
            radial-gradient(#ffd6e8 15%, transparent 16%);
          background-size: 24px 24px;
          background-position: 0 0, 12px 12px;
          color: #5c3a4d;
          min-height: 100vh;
        }
        .blog-page { max-width: 920px; margin: 0 auto; padding: 24px 16px; }
        .blog-header { text-align: center; margin-bottom: 24px; }
        .blog-logo { font-size: 32px; font-weight: bold; color: #d63384; text-shadow: 2px 2px 0 #ffd6e8; margin-bottom: 10px; }
        .blog-marquee {
          background: #fff;
          border: 2px dashed #ff9ec8;
          border-radius: 999px;
          padding: 6px 16px;
          font-size: 13px;
          color: #d63384;
          margin-bottom: 14px;
          overflow: hidden;
          white-space: nowrap;
          animation: blog-scroll 12s linear infinite;
        }
        @keyframes blog-scroll { 0% { text-indent: 100%; } 100% { text-indent: -100%; } }
        .blog-nav { display: flex; justify-content: center; gap: 18px; flex-wrap: wrap; }
        .blog-nav a {
          display: inline-block;
          background: #fff;
          border: 2px solid #ff9ec8;
          border-radius: 20px;
          padding: 6px 16px;
          color: #d63384;
          text-decoration: none;
          font-size: 13px;
          font-weight: bold;
        }
        .blog-nav a:hover { background: #ffd6e8; }
        .blog-layout { display: grid; grid-template-columns: 1fr 260px; gap: 24px; }
        .blog-post {
          background: #fff;
          border: 3px double #ff9ec8;
          border-radius: 16px;
          padding: 22px;
          margin-bottom: 20px;
          box-shadow: 4px 4px 0 rgba(214, 51, 132, 0.12);
        }
        .blog-post-title { font-size: 22px; color: #d63384; margin-bottom: 6px; }
        .blog-post-meta { font-size: 12px; color: #b56e8a; margin-bottom: 12px; }
        .blog-post p { line-height: 1.7; margin-bottom: 12px; }
        .blog-read-more { color: #d63384; font-weight: bold; text-decoration: none; }
        .blog-read-more:hover { text-decoration: underline; }
        .blog-widget {
          background: #fff;
          border: 2px dashed #ff9ec8;
          border-radius: 16px;
          padding: 16px;
          margin-bottom: 18px;
        }
        .blog-widget h3 {
          background: #ffd6e8;
          color: #d63384;
          font-size: 13px;
          text-transform: uppercase;
          letter-spacing: 1px;
          padding: 6px 10px;
          border-radius: 12px;
          margin: -10px -10px 12px;
          text-align: center;
        }
        .blog-widget ul { list-style: none; }
        .blog-widget li { margin-bottom: 8px; }
        .blog-widget a { color: #d63384; text-decoration: none; }
        .blog-widget a:hover { text-decoration: underline; }
        .blog-tags { display: flex; flex-wrap: wrap; gap: 6px; }
        .blog-tag {
          background: #ffd6e8;
          color: #d63384;
          font-size: 11px;
          padding: 4px 10px;
          border-radius: 999px;
        }
        .blog-footer { text-align: center; font-size: 12px; color: #b56e8a; margin-top: 20px; }
        @media (max-width: 760px) {
          .blog-layout { grid-template-columns: 1fr; }
          .blog-logo { font-size: 24px; }
        }
        """,
        canvasWidth: 1024,
        canvasHeight: 768
    )

    // MARK: - Vlog / Aero Channel

    static let vlog = WebsiteTemplate(
        name: "Aero Channel",
        icon: "play.rectangle",
        description: "Neocities-ready Frutiger Aero video channel: glossy player, grid",
        html: """
        <div class="aero-page">
          <header class="aero-header">
            <div class="aero-brand">Aero<span>Channel</span></div>
            <nav class="aero-nav">
              <a href="index.html">episodes</a>
              <a href="#">about</a>
              <a class="aero-subscribe" href="#">subscribe</a>
            </nav>
          </header>
          <section class="aero-hero">
            <div class="aero-player">
              <div class="aero-play">▶</div>
            </div>
            <h1 class="aero-hero-title">Latest Episode Title Goes Here</h1>
            <p class="aero-hero-meta">Episode 42 • 18:24 • 12K views</p>
          </section>
          <section class="aero-episodes">
            <h2 class="aero-section-title">Recent Episodes</h2>
            <div class="aero-grid">
              <div class="aero-card"><div class="aero-thumb"></div><h3>Episode 41</h3><p>Description of this episode.</p></div>
              <div class="aero-card"><div class="aero-thumb"></div><h3>Episode 40</h3><p>Description of this episode.</p></div>
              <div class="aero-card"><div class="aero-thumb"></div><h3>Episode 39</h3><p>Description of this episode.</p></div>
              <div class="aero-card"><div class="aero-thumb"></div><h3>Episode 38</h3><p>Description of this episode.</p></div>
            </div>
          </section>
          <footer class="aero-footer">best viewed in 1024×768 • made with glass and gradients</footer>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: Tahoma, Verdana, "Segoe UI", sans-serif;
          background: linear-gradient(180deg, #dff6ff 0%, #b8e7ff 40%, #e7f7ff 100%);
          color: #1a3c5a;
          min-height: 100vh;
        }
        .aero-page { max-width: 900px; margin: 0 auto; padding: 24px 18px; }
        .aero-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          flex-wrap: wrap;
          gap: 12px;
          background: rgba(255,255,255,0.55);
          border: 1px solid rgba(255,255,255,0.8);
          border-radius: 18px;
          padding: 14px 22px;
          box-shadow: 0 8px 24px rgba(0, 120, 180, 0.15);
          backdrop-filter: blur(6px);
          margin-bottom: 26px;
        }
        .aero-brand { font-size: 22px; font-weight: 800; color: #0078b4; text-shadow: 0 1px 0 rgba(255,255,255,0.8); }
        .aero-brand span { color: #00a8e8; font-weight: 400; }
        .aero-nav { display: flex; gap: 16px; align-items: center; }
        .aero-nav a { color: #1a6fa0; text-decoration: none; font-size: 13px; font-weight: 700; }
        .aero-nav a:hover { color: #0078b4; text-decoration: underline; }
        .aero-subscribe {
          background: linear-gradient(180deg, #8ee3ff 0%, #00a8e8 100%);
          color: #fff !important;
          padding: 6px 16px;
          border-radius: 20px;
          box-shadow: 0 3px 0 #0078b4;
        }
        .aero-hero { margin-bottom: 28px; }
        .aero-player {
          aspect-ratio: 16/9;
          background: linear-gradient(135deg, #dff6ff 0%, #aee5ff 50%, #8ee3ff 100%);
          border: 4px solid rgba(255,255,255,0.8);
          border-radius: 24px;
          display: flex;
          align-items: center;
          justify-content: center;
          box-shadow: inset 0 0 40px rgba(255,255,255,0.7), 0 12px 30px rgba(0,120,180,0.18);
          margin-bottom: 16px;
        }
        .aero-play {
          width: 76px;
          height: 76px;
          border-radius: 50%;
          background: linear-gradient(180deg, #ffffff 0%, #d6f2ff 100%);
          color: #00a8e8;
          font-size: 26px;
          display: flex;
          align-items: center;
          justify-content: center;
          box-shadow: 0 6px 16px rgba(0,120,180,0.25);
          padding-left: 6px;
        }
        .aero-hero-title { font-size: 26px; color: #005a8c; margin-bottom: 4px; }
        .aero-hero-meta { color: #3d8ab8; font-size: 13px; }
        .aero-section-title { font-size: 18px; color: #005a8c; margin-bottom: 16px; }
        .aero-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 18px; }
        .aero-card {
          background: rgba(255,255,255,0.65);
          border: 1px solid rgba(255,255,255,0.9);
          border-radius: 16px;
          padding: 14px;
          box-shadow: 0 6px 18px rgba(0,120,180,0.12);
        }
        .aero-thumb {
          aspect-ratio: 16/9;
          background: linear-gradient(135deg, #c4ecff 0%, #9adfff 100%);
          border-radius: 12px;
          margin-bottom: 10px;
        }
        .aero-card h3 { font-size: 14px; color: #005a8c; margin-bottom: 4px; }
        .aero-card p { color: #3d8ab8; font-size: 12px; }
        .aero-footer { text-align: center; font-size: 11px; color: #5a9ec4; margin-top: 28px; }
        @media (max-width: 560px) { .aero-grid { grid-template-columns: 1fr; } }
        """,
        canvasWidth: 1024,
        canvasHeight: 768
    )

    // MARK: - Top 8 (retro social profile)

    static let myspot = WebsiteTemplate(
        name: "Top 8",
        icon: "person.2",
        description: "Neocities-ready 2000s social profile: top 8, music, comments",
        html: """
        <div class="t8-page">
          <header class="t8-header">
            <div class="t8-logo">Top<span>8</span></div>
            <div class="t8-tagline">a place for friends</div>
          </header>
          <div class="t8-layout">
            <aside class="t8-left">
              <div class="t8-box t8-profile">
                <h2>username</h2>
                <div class="t8-avatar">PIC</div>
                <p><b>Location:</b> Perth, Western Australia</p>
                <p><b>Status:</b> <span class="t8-status">"living the dream"</span></p>
                <a class="t8-add" href="#">+ Add to friends</a>
              </div>
              <div class="t8-box">
                <h3>Interests</h3>
                <p>Photography, code, the ocean, coffee, glitter text, mid-2000s pop punk.</p>
              </div>
              <div class="t8-box t8-music">
                <h3>Now Playing</h3>
                <div class="t8-track">🎵 Artist - Song Title</div>
                <a href="#">view playlist</a>
              </div>
            </aside>
            <main class="t8-right">
              <div class="t8-box">
                <h3>Latest Blog Entry</h3>
                <p>Welcome to my page! Leave a comment and sign my guestbook.</p>
                <a href="#">read more</a>
              </div>
              <div class="t8-box">
                <h3>Top 8 Friends</h3>
                <div class="t8-friends">
                  <div class="t8-friend"><div class="t8-fpic">🐱</div><span>Tom</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🦊</div><span>Jane</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🐶</div><span>Max</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🐰</div><span>Alex</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🐼</div><span>Sam</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🐯</div><span>Kim</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🐨</div><span>Jo</span></div>
                  <div class="t8-friend"><div class="t8-fpic">🦁</div><span>Lee</span></div>
                </div>
              </div>
              <div class="t8-box">
                <h3>Comments</h3>
                <div class="t8-comment"><b>Tom:</b> thanks for the add!</div>
                <div class="t8-comment"><b>Jane:</b> love the new layout, so glittery</div>
              </div>
            </main>
          </div>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: Verdana, Arial, sans-serif;
          background: #001d4a;
          background-image:
            repeating-linear-gradient(45deg, rgba(0, 51, 153, 0.3) 0 2px, transparent 2px 10px),
            repeating-linear-gradient(-45deg, rgba(0, 51, 153, 0.3) 0 2px, transparent 2px 10px);
          color: #000;
          min-height: 100vh;
        }
        .t8-page { max-width: 860px; margin: 0 auto; padding: 16px; }
        .t8-header {
          background: linear-gradient(180deg, #003399 0%, #002266 100%);
          color: #fff;
          padding: 12px 18px;
          display: flex;
          align-items: baseline;
          gap: 12px;
          border-radius: 6px 6px 0 0;
          border-bottom: 3px solid #fff;
        }
        .t8-logo { font-size: 26px; font-weight: 800; letter-spacing: -1px; text-shadow: 2px 2px 0 #000; }
        .t8-logo span { color: #ffcc00; }
        .t8-tagline { font-size: 12px; color: #aaccff; }
        .t8-layout { display: grid; grid-template-columns: 280px 1fr; gap: 14px; margin-top: 14px; }
        .t8-box {
          background: #fff;
          border: 2px solid #6699cc;
          padding: 12px;
          margin-bottom: 14px;
          border-radius: 4px;
          box-shadow: 3px 3px 0 rgba(0,0,0,0.15);
        }
        .t8-box h2 { color: #cc0000; font-size: 16px; margin-bottom: 8px; }
        .t8-box h3 {
          background: #cc0000;
          color: #fff;
          font-size: 11px;
          padding: 5px 8px;
          margin: -12px -12px 10px;
          text-transform: uppercase;
          letter-spacing: 1px;
        }
        .t8-avatar {
          background: #dce9f5;
          border: 1px solid #6699cc;
          height: 150px;
          display: flex;
          align-items: center;
          justify-content: center;
          color: #6699cc;
          font-weight: 700;
          margin-bottom: 10px;
          font-size: 20px;
        }
        .t8-profile p { font-size: 12px; margin-bottom: 6px; }
        .t8-status { font-style: italic; color: #333; }
        .t8-add {
          display: inline-block;
          background: #ffcc00;
          color: #000;
          padding: 5px 12px;
          border-radius: 4px;
          font-size: 11px;
          font-weight: 700;
          text-decoration: none;
          margin-top: 6px;
        }
        .t8-music .t8-track {
          background: #eef5fc;
          border: 1px solid #cce0f5;
          padding: 6px;
          border-radius: 4px;
          font-size: 12px;
          margin-bottom: 6px;
        }
        .t8-music a { font-size: 11px; color: #003399; }
        .t8-friends {
          display: grid;
          grid-template-columns: repeat(4, 1fr);
          gap: 10px;
        }
        .t8-friend {
          text-align: center;
          font-size: 11px;
          color: #003399;
          font-weight: 700;
        }
        .t8-fpic {
          background: #dce9f5;
          border: 1px solid #6699cc;
          aspect-ratio: 1;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 24px;
          margin-bottom: 4px;
          border-radius: 4px;
        }
        .t8-comment {
          font-size: 12px;
          border-top: 1px dotted #999;
          padding: 8px 0;
        }
        .t8-comment b { color: #cc0000; }
        @media (max-width: 700px) { .t8-layout { grid-template-columns: 1fr; } }
        """,
        canvasWidth: 1024,
        canvasHeight: 768
    )

    // MARK: - Cyber Dash (vaporwave microblog)

    static let timble = WebsiteTemplate(
        name: "Cyber Dash",
        icon: "square.stack.3d.up",
        description: "Neocities-ready vaporwave microblog: neon, pixel avatars, feed",
        html: """
        <div class="cyber-page">
          <header class="cyber-header">
            <div class="cyber-logo">CYBER_DASH.exe</div>
            <nav class="cyber-nav">
              <a href="index.html">dash</a>
              <a href="#">explore</a>
              <a href="#">inbox</a>
              <a href="#">blog</a>
            </nav>
          </header>
          <main class="cyber-feed">
            <div class="cyber-new">create post: text / photo / quote / link</div>
            <article class="cyber-post">
              <div class="cyber-avatar">👤</div>
              <div class="cyber-body">
                <div class="cyber-user"><b>blogname</b> <span class="cyber-time">2m ago</span></div>
                <p>something worth scrolling for. text post body lives here.</p>
                <div class="cyber-notes">1,234 notes</div>
              </div>
            </article>
            <article class="cyber-post">
              <div class="cyber-avatar">👤</div>
              <div class="cyber-body">
                <div class="cyber-user"><b>anotherblog</b> reblogged <b>blogname</b></div>
                <blockquote class="cyber-quote">a quote post: big, centered, italic by default.</blockquote>
                <div class="cyber-notes">891 notes</div>
              </div>
            </article>
            <article class="cyber-post">
              <div class="cyber-avatar">👤</div>
              <div class="cyber-body">
                <div class="cyber-user"><b>photoblog</b></div>
                <div class="cyber-photo">PHOTO</div>
                <div class="cyber-notes">5,678 notes</div>
              </div>
            </article>
          </main>
          <footer class="cyber-footer">best viewed in chrome 95 • refresh for new glitches</footer>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: "Courier New", Courier, monospace;
          background: #0b0014;
          background-image:
            linear-gradient(180deg, rgba(255, 0, 255, 0.08) 1px, transparent 1px),
            linear-gradient(90deg, rgba(0, 255, 255, 0.06) 1px, transparent 1px);
          background-size: 100% 24px, 24px 100%;
          color: #e8e8ec;
          min-height: 100vh;
        }
        .cyber-page { max-width: 720px; margin: 0 auto; padding: 24px 18px; }
        .cyber-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          flex-wrap: wrap;
          gap: 12px;
          border: 2px solid #ff00ff;
          box-shadow: 0 0 12px #ff00ff, inset 0 0 20px rgba(255, 0, 255, 0.15);
          padding: 14px 20px;
          margin-bottom: 24px;
          border-radius: 4px;
        }
        .cyber-logo {
          font-size: 20px;
          font-weight: 800;
          color: #00ffff;
          text-shadow: 0 0 8px #00ffff;
          letter-spacing: 2px;
        }
        .cyber-nav { display: flex; gap: 18px; }
        .cyber-nav a {
          color: #ff00ff;
          text-decoration: none;
          font-size: 13px;
          font-weight: 700;
          text-transform: uppercase;
          letter-spacing: 1px;
        }
        .cyber-nav a:hover { color: #00ffff; text-shadow: 0 0 6px #00ffff; }
        .cyber-feed { display: flex; flex-direction: column; gap: 18px; }
        .cyber-new {
          border: 1px dashed #00ffff;
          color: #00ffff;
          padding: 14px;
          text-align: center;
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 1px;
          border-radius: 4px;
        }
        .cyber-post { display: flex; gap: 14px; }
        .cyber-avatar {
          width: 48px;
          height: 48px;
          background: #1a052a;
          border: 2px solid #ff00ff;
          border-radius: 4px;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 22px;
          flex-shrink: 0;
          box-shadow: 0 0 8px #ff00ff;
        }
        .cyber-body {
          flex: 1;
          background: rgba(255, 255, 255, 0.06);
          border: 1px solid rgba(0, 255, 255, 0.4);
          border-radius: 4px;
          padding: 14px 18px;
        }
        .cyber-user { font-size: 13px; margin-bottom: 6px; color: #00ffff; }
        .cyber-user b { color: #ff00ff; }
        .cyber-time { color: #888; font-weight: 400; }
        .cyber-body p { line-height: 1.6; color: #f0f0f5; }
        .cyber-quote {
          font-size: 20px;
          font-style: italic;
          text-align: center;
          color: #ff9eec;
          padding: 14px 6px;
        }
        .cyber-photo {
          background: linear-gradient(135deg, #2a0a3a 0%, #1a052a 100%);
          border: 1px solid #ff00ff;
          border-radius: 4px;
          height: 200px;
          display: flex;
          align-items: center;
          justify-content: center;
          color: #ff00ff;
          font-weight: 700;
          letter-spacing: 3px;
        }
        .cyber-notes { margin-top: 10px; color: #00ffff; font-size: 12px; }
        .cyber-footer { text-align: center; font-size: 11px; color: #666; margin-top: 28px; }
        @media (max-width: 520px) { .cyber-header { flex-direction: column; align-items: flex-start; } }
        """,
        canvasWidth: 1024,
        canvasHeight: 768
    )

    // MARK: - Meme Lab (retro 8-bit meme generator)

    static let memeLab = WebsiteTemplate(
        name: "Meme Lab",
        icon: "face.smiling",
        description: "Retro 8-bit meme generator: pixel art, ASCII gallery, live text",
        html: """
        <div class="cabinet">
          <header class="marquee">
            <h1>MEME LAB</h1>
            <div class="blink">INSERT COIN</div>
          </header>
          <div class="meme-canvas">
            <div class="meme-text top" id="topText">TOP TEXT</div>
            <div class="sprite-heart"></div>
            <div class="meme-text bottom" id="botText">BOTTOM TEXT</div>
          </div>
          <div class="controls">
            <label>TOP <input id="inTop" value="TOP TEXT" oninput="document.getElementById('topText').textContent=this.value"></label>
            <label>BOTTOM <input id="inBot" value="BOTTOM TEXT" oninput="document.getElementById('botText').textContent=this.value"></label>
          </div>
          <div class="controls colors">
            <label>TEXT <input type="color" value="#ffffff" oninput="pick('--textcolor',this.value)"></label>
            <label>CANVAS <input type="color" value="#15152b" oninput="pick('--canvas',this.value)"></label>
            <label>SPRITE <input type="color" value="#d63c6e" oninput="pick('--sprite',this.value)"></label>
            <label>FRAME <input type="color" value="#ffe945" oninput="pick('--frame',this.value)"></label>
            <label>ASCII INK <input type="color" value="#43e97b" oninput="pickInk(this.value)"></label>
            <button class="rainbow-btn" onclick="rainbow()">RAINBOW</button>
          </div>
          <script>
          function pick(name, value) {
            document.querySelector('.meme-canvas').style.setProperty(name, value);
          }
          function pickInk(value) {
            document.querySelectorAll('.ascii-row pre').forEach(function(p) {
              p.classList.remove('rainbow');
              p.style.setProperty('--ink', value);
            });
          }
          function rainbow() {
            document.querySelectorAll('.ascii-row pre').forEach(function(p) {
              p.classList.toggle('rainbow');
            });
          }
          </script>
          <div class="ascii-gallery">
            <h2>ASCII VAULT</h2>
            <div class="ascii-row">
              <pre>  x     x
           x   x
          xxxxxxx
         xx xxx xx
        xxxxxxxxxxx
        x xxxxxxx x
        x x     x x
           xx xx</pre>
              <pre> _____
        | o o |
        |  _  |
        |_____|</pre>
              <pre>=^.^=

          cat</pre>
              <pre>^..^
         woof</pre>
            </div>
          </div>
          <footer>PRESS START TO LAUGH - SCORE 000000</footer>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: "Courier New", monospace; background: #0d0d1a; color: #e8e8f0; min-height: 100vh; image-rendering: pixelated; }
        .cabinet { max-width: 760px; margin: 0 auto; padding: 32px 20px; }
        .marquee { text-align: center; margin-bottom: 24px; }
        .marquee h1 { font-size: 42px; letter-spacing: 6px; color: #ffe945; text-shadow: 4px 4px 0 #d63c6e, 8px 8px 0 #3c1053; }
        .blink { color: #43e97b; margin-top: 8px; animation: blink 1s steps(2) infinite; font-size: 14px; letter-spacing: 3px; }
        @keyframes blink { 50% { opacity: 0; } }
        .meme-canvas { position: relative; background: #15152b; border: 4px solid #ffe945; box-shadow: 0 0 0 4px #0d0d1a, 0 0 0 8px #d63c6e; padding: 40px 20px; text-align: center; }
        .sprite-heart { width: 20px; height: 20px; margin: 30px auto; background: #d63c6e; box-shadow: 20px 0 #d63c6e, -20px 0 #d63c6e, 40px 0 #d63c6e, -40px 0 #d63c6e, 0 -20px #d63c6e, 20px -20px #d63c6e, -20px -20px #d63c6e, 60px 0 transparent, -60px 0 transparent, 0 20px #d63c6e, 20px 20px #d63c6e, -20px 20px #d63c6e, 40px 20px #d63c6e, -40px 20px #d63c6e, 0 40px #d63c6e, 20px 40px #d63c6e, -20px 40px #d63c6e, 0 60px #d63c6e; }
        .meme-text { font-family: Impact, "Arial Black", sans-serif; font-size: 40px; color: #fff; text-shadow: 3px 3px 0 #000, -3px 3px 0 #000, 3px -3px 0 #000, -3px -3px 0 #000; letter-spacing: 2px; text-transform: uppercase; }
        .controls { display: flex; gap: 16px; margin: 28px 0; }
        .controls label { flex: 1; font-size: 12px; letter-spacing: 2px; color: #43e97b; }
        .controls input { display: block; width: 100%; margin-top: 6px; background: #15152b; color: #ffe945; border: 3px solid #43e97b; padding: 10px; font-family: inherit; font-size: 16px; }
        .controls input:focus { outline: none; border-color: #ffe945; }
        .ascii-gallery h2 { color: #d63c6e; font-size: 16px; letter-spacing: 3px; margin-bottom: 12px; }
        .ascii-row { display: flex; gap: 20px; flex-wrap: wrap; }
        .ascii-row pre { background: #15152b; border: 3px solid #33334d; padding: 14px; color: var(--ink, #43e97b); font-size: 13px; line-height: 1.25; }
        .ascii-row pre.rainbow { background-image: linear-gradient(180deg, #ff0040, #ffe945, #43e97b, #38f9d7, #d63c6e); -webkit-background-clip: text; background-clip: text; color: transparent; }
        .controls.colors label { color: #38f9d7; }
        .controls input[type="color"] { height: 38px; padding: 2px; cursor: pointer; }
        .rainbow-btn { align-self: end; background: #15152b; color: #ffe945; border: 3px solid #ffe945; padding: 8px 16px; font-family: inherit; font-size: 13px; letter-spacing: 2px; cursor: pointer; }
        .rainbow-btn:hover { background: #ffe945; color: #0d0d1a; }
        footer { text-align: center; margin-top: 28px; color: #55557a; font-size: 12px; letter-spacing: 2px; }
        """
    )

    // MARK: - Avatar (social profile picture card)

    static let avatar = WebsiteTemplate(
        name: "Avatar",
        icon: "person.crop.square",
        description: "512x512 social avatar: pixel-art card, exportable at exact size",
        html: """
        <div class="avatar-stage">
          <div class="avatar-card">
            <div class="px-face">
              <div class="px-eye left"></div>
              <div class="px-eye right"></div>
              <div class="px-mouth"></div>
            </div>
            <div class="avatar-name">PLAYER ONE</div>
            <div class="avatar-tag">@username</div>
          </div>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { width: 512px; height: 512px; overflow: hidden; font-family: "Courier New", monospace; background: #0d0d1a; display: flex; align-items: center; justify-content: center; }
        .avatar-stage { width: 512px; height: 512px; display: flex; align-items: center; justify-content: center; background: repeating-conic-gradient(#12122a 0% 25%, #0d0d1a 0% 50%) 0 0 / 32px 32px; }
        .avatar-card { width: 400px; height: 400px; background: var(--card, #1a1a35); border: 6px solid var(--ring, #ffe945); box-shadow: 0 0 0 6px #0d0d1a, 0 0 0 12px var(--ring2, #d63c6e); display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px; }
        .px-face { width: 160px; height: 160px; background: var(--skin, #43e97b); position: relative; box-shadow: 0 8px 0 var(--skin-dark, #2ba35c); }
        .px-eye { position: absolute; top: 48px; width: 28px; height: 36px; background: #0d0d1a; }
        .px-eye.left { left: 34px; }
        .px-eye.right { right: 34px; }
        .px-mouth { position: absolute; bottom: 34px; left: 50%; transform: translateX(-50%); width: 56px; height: 16px; background: #0d0d1a; }
        .avatar-name { color: var(--name, #ffffff); font-size: 28px; font-weight: 700; letter-spacing: 3px; }
        .avatar-tag { color: #8888aa; font-size: 16px; letter-spacing: 1px; }
        """,
        canvasWidth: 512,
        canvasHeight: 512,
        fluid: false
    )


    // MARK: - Banner (social header, 1500x500)

    static let banner = WebsiteTemplate(
        name: "Banner",
        icon: "photo",
        description: "1500x500 social header: retro sunset + scanlines, X/YouTube size",
        html: """
        <div class="banner">
          <div class="sun"></div>
          <div class="grid-floor"></div>
          <div class="scanlines"></div>
          <div class="banner-text">
            <div class="channel">CHANNEL NAME</div>
            <div class="tagline">new videos every friday</div>
          </div>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { width: 1500px; height: 500px; overflow: hidden; font-family: "Courier New", monospace; }
        .banner { position: relative; width: 1500px; height: 500px; background: linear-gradient(180deg, #1a0533 0%, #3c1053 35%, #d63c6e 70%, #ff9a3c 100%); }
        .sun { position: absolute; left: 50%; top: 90px; transform: translateX(-50%); width: 220px; height: 220px; border-radius: 50%; background: linear-gradient(180deg, #ffe945 0%, #ff9a3c 100%); box-shadow: 0 0 60px rgba(255, 233, 69, 0.6); }
        .grid-floor { position: absolute; left: 0; right: 0; bottom: 0; height: 160px; background: repeating-linear-gradient(90deg, transparent 0 48px, rgba(67, 233, 123, 0.35) 48px 50px), repeating-linear-gradient(0deg, transparent 0 30px, rgba(67, 233, 123, 0.35) 30px 32px); transform: perspective(300px) rotateX(40deg); transform-origin: bottom; }
        .scanlines { position: absolute; inset: 0; background: repeating-linear-gradient(0deg, rgba(0,0,0,0.18) 0 2px, transparent 2px 4px); pointer-events: none; }
        .banner-text { position: absolute; left: 0; right: 0; bottom: 120px; text-align: center; }
        .channel { font-size: 64px; font-weight: 700; letter-spacing: 10px; color: var(--title, #ffffff); text-shadow: 5px 5px 0 #3c1053, 10px 10px 0 rgba(0,0,0,0.4); }
        .tagline { margin-top: 14px; font-size: 22px; letter-spacing: 4px; color: #43e97b; text-shadow: 2px 2px 0 #0d0d1a; }
        """,
        canvasWidth: 1500,
        canvasHeight: 500,
        fluid: false
    )


    // MARK: - SwiftMaestro Neon Pink (title card / text generator)

    static let neonText = WebsiteTemplate(
        name: "SwiftMaestro Neon Pink",
        icon: "sparkles",
        description: "Neon pink title card: white text with a pink outer glow, editable inline and ready to export as PNG.",
        html: """
        <div class="controls">
          <label class="toggle">
            <input type="checkbox" id="transparentBg">
            <span>Transparent background</span>
          </label>
        </div>
        <div class="stage">
          <h1 class="neon" contenteditable="true" spellcheck="false">SwiftMaestro</h1>
          <p class="subtitle" contenteditable="true" spellcheck="false">Private AI. On Your Terms.</p>
        </div>
        <script>
          document.getElementById('transparentBg').addEventListener('change', function() {
            document.body.classList.toggle('transparent', this.checked);
          });
        </script>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&display=swap');
        body {
          font-family: 'JetBrains Mono', monospace;
          background: #0a0a0f;
          min-height: 100vh;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          overflow: hidden;
        }
        body.transparent {
          background: transparent;
        }
        .controls {
          position: absolute;
          top: 20px;
          right: 20px;
          z-index: 10;
        }
        .toggle {
          display: inline-flex;
          align-items: center;
          gap: 8px;
          padding: 8px 12px;
          background: rgba(10, 10, 15, 0.8);
          border: 1px solid rgba(255, 46, 136, 0.4);
          border-radius: 8px;
          color: #ff8ab8;
          font-size: 13px;
          cursor: pointer;
          user-select: none;
        }
        .toggle input {
          accent-color: #ff2e88;
        }
        body.transparent .toggle {
          background: rgba(0, 0, 0, 0.5);
        }
        .stage {
          text-align: center;
          padding: 40px;
        }
        .neon {
          font-family: 'JetBrains Mono', monospace;
          font-weight: 700;
          font-size: 96px;
          letter-spacing: 0.04em;
          color: #fff;
          text-shadow:
            0 0 6px #ff2e88,
            0 0 14px #ff2e88,
            0 0 28px #ff00ff;
          outline: none;
          cursor: text;
        }
        .subtitle {
          margin-top: 18px;
          font-family: 'JetBrains Mono', monospace;
          font-weight: 600;
          font-size: 28px;
          letter-spacing: 0.08em;
          color: #00f0ff;
          text-shadow: 0 0 8px rgba(0, 240, 255, 0.6);
          outline: none;
          cursor: text;
        }
        """,
        canvasWidth: 1920,
        canvasHeight: 400,
        fluid: false
    )

    // MARK: - Link Bio (link-in-bio page)

    static let linkBio = WebsiteTemplate(
        name: "Link Bio",
        icon: "link.circle",
        description: "Link-in-bio page: avatar, pixel buttons, social links",
        html: """
        <div class="bio-page">
          <div class="bio-card">
            <div class="bio-avatar">ME</div>
            <h1>@username</h1>
            <p class="bio-blurb">maker - streamer - professional button clicker</p>
            <a class="bio-link" href="#">LATEST VIDEO</a>
            <a class="bio-link" href="#">DISCORD SERVER</a>
            <a class="bio-link" href="#">MERCH STORE</a>
            <a class="bio-link" href="#">BLOG</a>
            <div class="bio-footer">press start to follow</div>
          </div>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: "Courier New", monospace; background: #0d0d1a; color: #e8e8f0; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .bio-page { width: 100%; max-width: 420px; padding: 40px 20px; }
        .bio-card { text-align: center; }
        .bio-avatar { width: 96px; height: 96px; margin: 0 auto 16px; background: var(--avatar-bg, #d63c6e); border: 4px solid var(--ring, #ffe945); box-shadow: 0 0 0 4px #0d0d1a, 0 0 0 8px var(--ring2, #43e97b); display: flex; align-items: center; justify-content: center; font-size: 32px; font-weight: 700; color: #fff; }
        h1 { font-size: 22px; letter-spacing: 2px; color: var(--name, #ffffff); }
        .bio-blurb { margin: 8px 0 28px; color: #8888aa; font-size: 14px; }
        .bio-link { display: block; background: var(--btn, #15152b); color: var(--btn-text, #ffe945); border: 3px solid var(--btn-border, #43e97b); padding: 16px; margin-bottom: 14px; text-decoration: none; font-size: 16px; letter-spacing: 2px; font-weight: 700; transition: transform 0.08s steps(2), background 0.08s; }
        .bio-link:hover { background: var(--btn-border, #43e97b); color: #0d0d1a; transform: translate(-2px, -2px); box-shadow: 4px 4px 0 var(--ring, #ffe945); }
        .bio-footer { margin-top: 32px; color: #55557a; font-size: 12px; letter-spacing: 2px; animation: blink 1.2s steps(2) infinite; }
        @keyframes blink { 50% { opacity: 0; } }
        """
    )

}
