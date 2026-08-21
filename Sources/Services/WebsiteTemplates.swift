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

    var id: String { name }
}

enum WebsiteTemplates {

    static let all: [WebsiteTemplate] = [blog, vlog, myspace, tumblr, memeLab, avatar, banner, linkBio]

    // MARK: - Blog

    static let blog = WebsiteTemplate(
        name: "Blog",
        icon: "text.justify.left",
        description: "Classic personal blog: header, posts, sidebar",
        html: """
        <header class="site-header">
          <div class="container header-inner">
            <div class="logo">My Blog</div>
            <nav class="nav"><a href="#">Home</a><a href="#">Archive</a><a href="#">About</a></nav>
          </div>
        </header>
        <div class="container layout">
          <main class="posts">
            <article class="post">
              <h2 class="post-title">First post title</h2>
              <div class="post-meta">August 21, 2026 - 5 min read</div>
              <p>Your first paragraph goes here. Write something worth reading.</p>
              <a class="read-more" href="#">Continue reading</a>
            </article>
            <article class="post">
              <h2 class="post-title">An older post</h2>
              <div class="post-meta">August 12, 2026 - 3 min read</div>
              <p>Excerpt of the older post shows on the index page.</p>
              <a class="read-more" href="#">Continue reading</a>
            </article>
          </main>
          <aside class="sidebar">
            <div class="widget"><h3>About</h3><p>Short bio. Who writes this and why.</p></div>
            <div class="widget"><h3>Categories</h3>
              <ul><li><a href="#">Essays</a></li><li><a href="#">Notes</a></li><li><a href="#">Projects</a></li></ul>
            </div>
          </aside>
        </div>
        <footer class="site-footer"><div class="container">(c) 2026 My Blog</div></footer>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Georgia, serif; background: #fafaf7; color: #222; min-height: 100vh; }
        .container { max-width: 1080px; margin: 0 auto; padding: 0 24px; }
        .site-header { background: #fff; border-bottom: 1px solid #e5e2da; padding: 20px 0; }
        .header-inner { display: flex; justify-content: space-between; align-items: center; }
        .logo { font-family: -apple-system, sans-serif; font-size: 24px; font-weight: 700; }
        .nav a { margin-left: 24px; color: #555; text-decoration: none; font-family: -apple-system, sans-serif; font-size: 15px; }
        .layout { display: grid; grid-template-columns: 1fr 300px; gap: 48px; padding: 40px 0 60px; }
        .post { background: #fff; border: 1px solid #e5e2da; border-radius: 8px; padding: 32px; margin-bottom: 32px; }
        .post-title { font-size: 30px; margin-bottom: 8px; }
        .post-meta { color: #999; font-size: 14px; font-family: -apple-system, sans-serif; margin-bottom: 18px; }
        .post p { margin-bottom: 14px; line-height: 1.7; }
        .read-more { color: #7c3aed; text-decoration: none; font-weight: 600; font-size: 14px; }
        .widget { background: #fff; border: 1px solid #e5e2da; border-radius: 8px; padding: 24px; margin-bottom: 24px; }
        .widget h3 { font-family: -apple-system, sans-serif; font-size: 14px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }
        .widget ul { list-style: none; }
        .widget li { margin-bottom: 8px; }
        .widget a { color: #7c3aed; text-decoration: none; }
        .site-footer { border-top: 1px solid #e5e2da; padding: 24px 0; color: #999; font-size: 13px; font-family: -apple-system, sans-serif; }
        @media (max-width: 800px) { .layout { grid-template-columns: 1fr; } }
        """
    )

    // MARK: - Vlog

    static let vlog = WebsiteTemplate(
        name: "Vlog",
        icon: "play.rectangle",
        description: "Video-first channel page: hero player, episode grid",
        html: """
        <header class="topbar">
          <div class="container topbar-inner">
            <div class="brand">Channel<span>TV</span></div>
            <nav><a href="#">Episodes</a><a href="#">About</a><a class="cta" href="#">Subscribe</a></nav>
          </div>
        </header>
        <section class="hero">
          <div class="container">
            <div class="player"><div class="play-btn">PLAY</div></div>
            <h1>Latest Episode Title Goes Here</h1>
            <p class="hero-meta">Episode 42 - 18:24 - 12K views</p>
          </div>
        </section>
        <section class="container episodes">
          <h2>Recent Episodes</h2>
          <div class="grid">
            <div class="card"><div class="thumb"></div><h3>Episode 41</h3><p>Description of this episode.</p></div>
            <div class="card"><div class="thumb"></div><h3>Episode 40</h3><p>Description of this episode.</p></div>
            <div class="card"><div class="thumb"></div><h3>Episode 39</h3><p>Description of this episode.</p></div>
            <div class="card"><div class="thumb"></div><h3>Episode 38</h3><p>Description of this episode.</p></div>
          </div>
        </section>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, sans-serif; background: #0f0f13; color: #f2f2f5; min-height: 100vh; }
        .container { max-width: 1200px; margin: 0 auto; padding: 0 24px; }
        .topbar { background: #15151c; border-bottom: 1px solid #26262f; padding: 16px 0; }
        .topbar-inner { display: flex; justify-content: space-between; align-items: center; }
        .brand { font-size: 22px; font-weight: 800; }
        .brand span { color: #ef4444; }
        .topbar a { color: #c9c9d1; text-decoration: none; margin-left: 24px; font-size: 15px; }
        .topbar a.cta { background: #ef4444; color: #fff; padding: 8px 18px; border-radius: 20px; font-weight: 600; }
        .hero { padding: 48px 0 32px; }
        .player { aspect-ratio: 16/9; background: #1c1c26; border-radius: 14px; display: flex; align-items: center; justify-content: center; border: 1px solid #2e2e3a; }
        .play-btn { width: 90px; height: 90px; border-radius: 50%; background: rgba(239,68,68,0.95); color: #fff; font-size: 13px; font-weight: 700; letter-spacing: 1px; display: flex; align-items: center; justify-content: center; }
        .hero h1 { font-size: 32px; margin-top: 24px; }
        .hero-meta { color: #8a8a96; margin-top: 8px; font-size: 14px; }
        .episodes h2 { font-size: 20px; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; padding-bottom: 60px; }
        .card { background: #15151c; border: 1px solid #26262f; border-radius: 12px; padding: 14px; }
        .thumb { aspect-ratio: 16/9; background: #23232e; border-radius: 8px; margin-bottom: 10px; }
        .card h3 { font-size: 15px; margin-bottom: 4px; }
        .card p { color: #8a8a96; font-size: 13px; }
        @media (max-width: 900px) { .grid { grid-template-columns: repeat(2, 1fr); } }
        """
    )

    // MARK: - MySpace (retro social profile)

    static let myspace = WebsiteTemplate(
        name: "MySpace",
        icon: "person.2",
        description: "Retro 2005 social profile: top 8 friends, comments, glitter",
        html: """
        <div class="page">
          <header class="ms-header">
            <div class="ms-logo">MySpace</div>
            <div class="ms-tagline">a place for friends</div>
          </header>
          <div class="profile-grid">
            <div class="left-col">
              <div class="box profile-card">
                <h2>username</h2>
                <div class="avatar">PIC</div>
                <p>Perth, Western Australia</p>
                <p>Australia</p>
                <p class="status">"living the dream"</p>
              </div>
              <div class="box"><h3>Interests</h3><p>Photography, code, ocean, coffee.</p></div>
              <div class="box"><h3>Details</h3><p>Status: Busy<br/>Zodiac: Leo<br/>Smoke: No</p></div>
            </div>
            <div class="right-col">
              <div class="box"><h3>Latest Blog Entry</h3><p>Welcome to my page. Leave a comment!</p></div>
              <div class="box friends">
                <h3>Top 8 Friends</h3>
                <div class="friend-grid">
                  <div class="friend">TOM</div><div class="friend">JANE</div>
                  <div class="friend">MAX</div><div class="friend">ALEX</div>
                  <div class="friend">SAM</div><div class="friend">KIM</div>
                  <div class="friend">JO</div><div class="friend">LEE</div>
                </div>
              </div>
              <div class="box comments">
                <h3>Comments</h3>
                <div class="comment"><b>Tom:</b> thanks for the add!</div>
                <div class="comment"><b>Jane:</b> love the new layout</div>
              </div>
            </div>
          </div>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: Verdana, Arial, sans-serif; background: #a6c7e0 url('') repeat; color: #000; min-height: 100vh; }
        .page { max-width: 900px; margin: 0 auto; padding: 12px; }
        .ms-header { background: #003399; color: #fff; padding: 10px 16px; display: flex; align-items: baseline; gap: 12px; }
        .ms-logo { font-size: 28px; font-weight: 700; letter-spacing: -1px; }
        .ms-tagline { font-size: 12px; }
        .profile-grid { display: grid; grid-template-columns: 300px 1fr; gap: 12px; margin-top: 12px; }
        .box { background: #fff; border: 1px solid #6699cc; padding: 10px; margin-bottom: 12px; }
        .box h2 { color: #cc0000; font-size: 18px; margin-bottom: 8px; }
        .box h3 { background: #cc0000; color: #fff; font-size: 12px; padding: 3px 6px; margin: -10px -10px 8px; }
        .avatar { background: #dce9f5; border: 1px solid #6699cc; height: 160px; display: flex; align-items: center; justify-content: center; color: #6699cc; font-weight: 700; margin-bottom: 8px; }
        .profile-card p { font-size: 12px; margin-bottom: 4px; }
        .status { font-style: italic; color: #333; }
        .friend-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
        .friend { background: #dce9f5; border: 1px solid #6699cc; aspect-ratio: 1; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; color: #003399; }
        .comment { font-size: 12px; border-top: 1px dotted #999; padding: 6px 0; }
        """
    )

    // MARK: - Tumblr (dashboard feed)

    static let tumblr = WebsiteTemplate(
        name: "Tumblr",
        icon: "t.circle",
        description: "Microblog dashboard: icon rail, post feed, notes",
        html: """
        <div class="tumblr-page">
          <aside class="rail">
            <div class="rail-logo">t</div>
            <nav class="rail-nav"><a href="#">DASH</a><a href="#">EXPLORE</a><a href="#">INBOX</a><a href="#">BLOG</a></nav>
          </aside>
          <main class="feed">
            <div class="new-post">Create post: Text / Photo / Quote / Link</div>
            <article class="post">
              <div class="post-avatar"></div>
              <div class="post-body">
                <div class="post-user"><b>blogname</b></div>
                <p>Something worth scrolling for. Text post body lives here.</p>
                <div class="post-notes">1,234 notes</div>
              </div>
            </article>
            <article class="post">
              <div class="post-avatar"></div>
              <div class="post-body">
                <div class="post-user"><b>anotherblog</b> reblogged <b>blogname</b></div>
                <blockquote class="quote">A quote post: big, centered, italic by default.</blockquote>
                <div class="post-notes">891 notes</div>
              </div>
            </article>
            <article class="post">
              <div class="post-avatar"></div>
              <div class="post-body">
                <div class="post-user"><b>photoblog</b></div>
                <div class="photo-placeholder">PHOTO</div>
                <div class="post-notes">5,678 notes</div>
              </div>
            </article>
          </main>
        </div>
        """,
        css: """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, sans-serif; background: #001935; color: #e8e8ec; min-height: 100vh; }
        .tumblr-page { display: grid; grid-template-columns: 220px 1fr; min-height: 100vh; }
        .rail { background: #001224; padding: 24px 16px; }
        .rail-logo { font-size: 40px; font-weight: 800; color: #fff; margin-bottom: 32px; }
        .rail-nav a { display: block; color: #9fb3c8; text-decoration: none; font-size: 13px; letter-spacing: 2px; padding: 10px 8px; border-radius: 8px; }
        .rail-nav a:hover { background: rgba(255,255,255,0.08); color: #fff; }
        .feed { max-width: 640px; margin: 0 auto; padding: 32px 24px; }
        .new-post { background: #123; border: 1px dashed #345; color: #9fb3c8; border-radius: 12px; padding: 16px; text-align: center; font-size: 14px; margin-bottom: 24px; }
        .post { display: flex; gap: 14px; margin-bottom: 24px; }
        .post-avatar { width: 48px; height: 48px; background: #345; border-radius: 10px; flex-shrink: 0; }
        .post-body { background: #fff; color: #1a1a1a; border-radius: 12px; padding: 16px 20px; flex: 1; }
        .post-user { font-size: 13px; margin-bottom: 8px; color: #444; }
        .post-body p { line-height: 1.6; }
        .quote { font-size: 22px; font-style: italic; text-align: center; padding: 16px 8px; }
        .photo-placeholder { background: #dde; border-radius: 8px; height: 240px; display: flex; align-items: center; justify-content: center; color: #667; font-weight: 700; letter-spacing: 3px; }
        .post-notes { margin-top: 12px; color: #888; font-size: 13px; }
        """
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
        canvasHeight: 512
    )


    // MARK: - Banner (social header, 1500x500)

    static let banner = WebsiteTemplate(
        name: "Banner",
        icon: "rectangle.compact",
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
        canvasHeight: 500
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
