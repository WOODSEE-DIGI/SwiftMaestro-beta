import Foundation

// MARK: - Story Game Web Exporter
//
// Exports a Game Studio project to a self-contained web build:
//   - index.html   (DOS/CRT UI + JS runtime, inline)
//   - game.json    (canonical project data)
//   - portraits/   (copied from the project folder if present)

enum StoryGameWebExporterError: LocalizedError {
    case missingProjectURL
    case failedToCopyAssets(Error)

    var errorDescription: String? {
        switch self {
        case .missingProjectURL:
            return "Cannot locate project assets for export."
        case .failedToCopyAssets(let error):
            return "Failed to copy portrait assets: \(error.localizedDescription)"
        }
    }
}

struct StoryGameWebExporter {

    /// Export `project` to `outputDirectory`. If `assetSourceDirectory` is supplied,
    /// any `portraits` folder inside it is copied into the build.
    static func export(
        project: StoryGameProject,
        to outputDirectory: URL,
        assetSourceDirectory: URL? = nil
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let gameData = try encoder.encode(project)
        try gameData.write(
            to: outputDirectory.appendingPathComponent("game.json"),
            options: .atomic
        )

        let indexHTML = Self.indexHTML(project: project)
        try indexHTML.write(
            to: outputDirectory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        if let source = assetSourceDirectory {
            try copyAssetFolder(named: "portraits", from: source, to: outputDirectory)
            try copyAssetFolder(named: "maps", from: source, to: outputDirectory)
        }
    }

    private static func copyAssetFolder(named name: String, from source: URL, to outputDirectory: URL) throws {
        let manager = FileManager.default
        let sourceFolder = source.appendingPathComponent(name)
        guard manager.fileExists(atPath: sourceFolder.path) else { return }
        let destFolder = outputDirectory.appendingPathComponent(name)
        if manager.fileExists(atPath: destFolder.path) {
            try manager.removeItem(at: destFolder)
        }
        do {
            try manager.copyItem(at: sourceFolder, to: destFolder)
        } catch {
            throw StoryGameWebExporterError.failedToCopyAssets(error)
        }
    }

    // MARK: - HTML shell

    private static func indexHTML(project: StoryGameProject) -> String {
        let title = escapeHTML(project.metadata.title)
        let subtitle = project.metadata.subtitle.map { " — \($0)" } ?? ""
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)\(subtitle)</title>
          <style>
            :root {
              --fg: #73ff73;
              --bg: #0a0f0a;
              --dim: rgba(115, 255, 115, 0.6);
              --danger: #ff5555;
            }
            body.amber { --fg: #ffb838; --bg: #140c04; --dim: rgba(255, 184, 56, 0.6); }
            body.cyan  { --fg: #5ae6ff; --bg: #050c10; --dim: rgba(90, 230, 255, 0.6); }

            * { box-sizing: border-box; }
            html, body {
              margin: 0; padding: 0;
              background: var(--bg);
              color: var(--fg);
              font-family: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
              font-size: 16px;
              line-height: 1.55;
              height: 100%;
              overflow: hidden;
            }
            #app {
              display: flex; flex-direction: column;
              height: 100vh; max-width: 900px; margin: 0 auto;
              padding: 20px;
            }
            header {
              display: flex; justify-content: space-between; align-items: flex-end;
              border-bottom: 1px solid rgba(115,255,115,0.25);
              padding-bottom: 12px; margin-bottom: 12px;
            }
            h1 { margin: 0; font-size: 1.1rem; letter-spacing: 1px; }
            #subtitle { color: var(--dim); font-size: 0.8rem; }
            #counter { font-size: 0.75rem; color: var(--dim); }

            #stats {
              display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
              gap: 12px; margin-bottom: 16px;
            }
            .stat { display: flex; flex-direction: column; gap: 4px; }
            .stat-label { font-size: 0.65rem; color: var(--dim); text-transform: uppercase; }
            .stat-row { display: flex; justify-content: space-between; font-size: 0.75rem; }
            .bar { height: 6px; background: rgba(115,255,115,0.15); border-radius: 3px; overflow: hidden; }
            .bar-fill { height: 100%; background: var(--fg); transition: width 0.4s ease; }
            .bar-fill.danger { background: var(--danger); }

            #scroller { flex: 1; overflow-y: auto; padding-right: 8px; }
            #scene-meta { margin-bottom: 14px; }
            #scene-title { font-size: 1.15rem; font-weight: bold; text-transform: uppercase; margin-bottom: 6px; }
            #scene-badges { display: flex; gap: 14px; font-size: 0.75rem; color: var(--dim); }
            #portrait { margin-top: 12px; }
            #portrait img {
              width: 96px; height: 96px; object-fit: cover;
              border-radius: 6px;
              border: 1px solid rgba(115,255,115,0.35);
            }
            #narrative { font-size: 1rem; margin-bottom: 18px; white-space: pre-wrap; }
            #symbols { display: flex; gap: 10px; margin-bottom: 18px; font-size: 1.3rem; }
            #choices { display: flex; flex-direction: column; gap: 10px; }
            .choice {
              display: flex; align-items: center; gap: 12px;
              padding: 12px 14px; cursor: pointer;
              background: rgba(115,255,115,0.06);
              border: 1px solid rgba(115,255,115,0.3);
              border-radius: 6px;
              transition: background 0.15s, border-color 0.15s;
            }
            .choice:hover { background: rgba(115,255,115,0.14); border-color: var(--fg); }
            .choice-num { width: 24px; text-align: center; font-weight: bold; background: rgba(115,255,115,0.15); border-radius: 4px; padding: 2px 0; }
            .choice-text { flex: 1; }
            .choice-hist { font-size: 0.65rem; color: var(--dim); border: 1px solid rgba(115,255,115,0.35); border-radius: 4px; padding: 2px 6px; }
            #gameover { margin-top: 20px; padding: 16px; border: 1px solid var(--fg); border-radius: 6px; }
            #gameover h2 { margin: 0 0 8px; font-size: 1rem; }
            #controls { display: flex; gap: 10px; margin-top: 14px; flex-wrap: wrap; }
            button {
              background: transparent; color: var(--fg); border: 1px solid rgba(115,255,115,0.4);
              border-radius: 4px; padding: 6px 12px; cursor: pointer; font-family: inherit; font-size: 0.8rem;
            }
            button:hover { background: rgba(115,255,115,0.12); }
            .scanlines {
              position: fixed; inset: 0; pointer-events: none; z-index: 10;
              background: repeating-linear-gradient(
                to bottom,
                rgba(0,0,0,0.22),
                rgba(0,0,0,0.22) 1px,
                transparent 1px,
                transparent 3px
              );
            }
            .scanlines.hidden { display: none; }
            #cursor { animation: blink 1s step-end infinite; }
            @keyframes blink { 50% { opacity: 0; } }
          </style>
        </head>
        <body>
          <div class="scanlines"></div>
          <div id="app">
            <header>
              <div>
                <h1 id="game-title">\(title)</h1>
                <div id="subtitle">\(escapeHTML(project.metadata.subtitle ?? ""))</div>
              </div>
              <div id="counter"></div>
            </header>
            <div id="stats"></div>
            <div id="scroller">
              <div id="scene-meta">
                <div id="scene-title"></div>
                <div id="scene-badges"></div>
                <div id="portrait"></div>
              </div>
              <div id="narrative"></div>
              <div id="symbols"></div>
              <div id="choices"></div>
              <div id="gameover" style="display:none;">
                <h2>[ END OF TRANSMISSION ]</h2>
                <p id="end-reason"></p>
                <button id="restart">Restart</button>
              </div>
            </div>
            <div id="controls">
              <button id="theme-green">Green</button>
              <button id="theme-amber">Amber</button>
              <button id="theme-cyan">Cyan</button>
              <button id="toggle-scanlines">Toggle Scanlines</button>
            </div>
          </div>
          <script>
        \(runtimeJS)
          </script>
        </body>
        </html>
        """
    }

    // MARK: - Runtime JS

    private static let runtimeJS = """
    (function() {
      let project = null;
      let scenes = [];
      let stats = {};
      let currentIndex = 0;
      let typingTimer = null;

      const els = {
        counter: document.getElementById('counter'),
        stats: document.getElementById('stats'),
        title: document.getElementById('scene-title'),
        badges: document.getElementById('scene-badges'),
        portrait: document.getElementById('portrait'),
        narrative: document.getElementById('narrative'),
        symbols: document.getElementById('symbols'),
        choices: document.getElementById('choices'),
        gameover: document.getElementById('gameover'),
        endReason: document.getElementById('end-reason')
      };

      fetch('game.json')
        .then(r => r.json())
        .then(data => {
          project = data;
          scenes = project.scenes || [];
          initStats();
          loadScene(0);
        })
        .catch(err => {
          els.narrative.textContent = 'ERROR LOADING GAME.JSON: ' + err.message;
        });

      function initStats() {
        stats = {};
        const defs = project.statDefinitions || {};
        for (const key in defs) {
          stats[key] = defs[key].defaultValue;
        }
        renderStats();
      }

      function renderStats() {
        const defs = project.statDefinitions || {};
        let html = '';
        for (const key of Object.keys(defs).sort()) {
          const def = defs[key];
          const val = Math.max(def.min, Math.min(def.max, stats[key] ?? def.defaultValue));
          const pct = (val - def.min) / (def.max - def.min) * 100;
          const dangerClass = def.isDanger ? 'danger' : '';
          html += `<div class="stat">
            <div class="stat-label">${escapeHtml(def.name)}</div>
            <div class="stat-row"><span>${escapeHtml(def.name)}</span><span>${Math.round(val)}</span></div>
            <div class="bar"><div class="bar-fill ${dangerClass}" style="width:${pct}%"></div></div>
          </div>`;
        }
        els.stats.innerHTML = html;
      }

      function applyEffects(effects) {
        if (!effects) return;
        const defs = project.statDefinitions || {};
        for (const key in effects) {
          if (!defs[key]) continue;
          const def = defs[key];
          stats[key] = Math.max(def.min, Math.min(def.max, (stats[key] ?? def.defaultValue) + effects[key]));
        }
        renderStats();
      }

      function loadScene(index) {
        if (index < 0 || index >= scenes.length) return endGame('The story ends here.');
        stopTyping();
        currentIndex = index;
        const scene = scenes[index];

        els.counter.textContent = 'SCENE ' + String(index + 1).padStart(2, '0') + ' / ' + String(scenes.length).padStart(2, '0');
        els.title.textContent = (scene.title || 'SCENE ' + String(index + 1)).toUpperCase();
        els.gameover.style.display = 'none';
        els.choices.innerHTML = '';
        els.symbols.innerHTML = '';

        const badges = [];
        if (scene.displayDate || scene.date) badges.push('📅 ' + escapeHtml(scene.displayDate || scene.date));
        if (scene.locationID && project.locations && project.locations[scene.locationID]) {
          badges.push('📍 ' + escapeHtml(project.locations[scene.locationID].name));
        }
        const charID = scene.primaryCharacterID || (scene.characterIDs && scene.characterIDs[0]);
        if (charID && project.characters && project.characters[charID]) {
          badges.push('👤 ' + escapeHtml(project.characters[charID].name));
        }
        els.badges.innerHTML = badges.map(b => '<span>' + b + '</span>').join('');

        typeText(scene.narrative || '', () => showChoices(scene));

        if (scene.symbols && scene.symbols.length) {
          els.symbols.innerHTML = scene.symbols.map(s => '<span>' + escapeHtml(s) + '</span>').join('');
        }

        els.portrait.innerHTML = '';
        const charID = scene.primaryCharacterID || (scene.characterIDs && scene.characterIDs[0]);
        const portraitChar = charID && project.characters && project.characters[charID];
        if (portraitChar && portraitChar.portraitFilename) {
          els.portrait.innerHTML = '<img src="portraits/' + escapeHtml(portraitChar.portraitFilename) + '" alt="' + escapeHtml(portraitChar.name) + '">';
        }
      }

      function typeText(text, onDone) {
        els.narrative.innerHTML = '<span id="typed"></span><span id="cursor">_</span>';
        const typed = document.getElementById('typed');
        let i = 0;
        typingTimer = setInterval(() => {
          if (i < text.length) {
            typed.textContent += text[i];
            i++;
          } else {
            stopTyping();
            if (onDone) onDone();
          }
        }, 18);
      }

      function stopTyping() {
        if (typingTimer) {
          clearInterval(typingTimer);
          typingTimer = null;
        }
      }

      function showChoices(scene) {
        els.choices.innerHTML = '';
        if (!scene.choices || !scene.choices.length) {
          setTimeout(() => nextOrEnd(), 800);
          return;
        }
        scene.choices.forEach((choice, idx) => {
          const div = document.createElement('div');
          div.className = 'choice';
          div.innerHTML = '<div class="choice-num">' + (idx + 1) + '</div>' +
            '<div class="choice-text">' + escapeHtml(choice.text || '(continue)') + '</div>' +
            (choice.isHistorical ? '<div class="choice-hist">HISTORICAL</div>' : '');
          div.addEventListener('click', () => selectChoice(idx));
          els.choices.appendChild(div);
        });
      }

      function selectChoice(idx) {
        const scene = scenes[currentIndex];
        const choice = scene.choices[idx];
        if (!choice) return;
        applyEffects(choice.effects);
        if (choice.targetSceneID) {
          const target = scenes.findIndex(s => s.id === choice.targetSceneID);
          if (target >= 0) return loadScene(target);
        }
        nextOrEnd();
      }

      function nextOrEnd() {
        if (currentIndex + 1 < scenes.length) {
          loadScene(currentIndex + 1);
        } else {
          endGame('The story ends here.');
        }
      }

      function endGame(reason) {
        stopTyping();
        els.choices.innerHTML = '';
        els.gameover.style.display = 'block';
        els.endReason.textContent = reason || '';
      }

      function escapeHtml(str) {
        return String(str).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',\"'\":'&#39;'}[c]));
      }

      document.getElementById('restart').addEventListener('click', () => { initStats(); loadScene(0); });
      document.getElementById('theme-green').addEventListener('click', () => document.body.className = '');
      document.getElementById('theme-amber').addEventListener('click', () => document.body.className = 'amber');
      document.getElementById('theme-cyan').addEventListener('click', () => document.body.className = 'cyan');
      document.getElementById('toggle-scanlines').addEventListener('click', () => document.querySelector('.scanlines').classList.toggle('hidden'));

      document.addEventListener('keydown', e => {
        if (e.key >= '1' && e.key <= '9') {
          const idx = parseInt(e.key) - 1;
          const btns = els.choices.querySelectorAll('.choice');
          if (idx < btns.length) btns[idx].click();
        }
      });
    })();
    """

    // MARK: - Helpers

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
