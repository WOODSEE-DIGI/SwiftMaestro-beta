// SwiftMaestro overlay dismisser — injected into a page to clear modals,
// newsletter popups, spin-to-win wheels, cookie walls, and backdrops.
// Strategy: (1) click a close control inside each visible dialog so the site
// cleans up its own state, (2) remove dialogs still visible after the click,
// (3) remove high-z-index backdrops, (4) restore body scrolling.
// Returns JSON: {clicked, removed, scrollRestored}
(function () {
  var clicked = 0, removed = 0;
  var dialogSel = '[role="dialog"], [aria-modal="true"], [class*="modal" i], [id*="modal" i], [class*="popup" i], [id*="popup" i], [class*="overlay" i], [class*="lightbox" i], [class*="newsletter" i], [class*="spin" i], [class*="wheel" i], [class*="dialog" i], [class*="drawer" i]';
  var dialogs = Array.from(document.querySelectorAll(dialogSel)).filter(function (el) {
    var s = getComputedStyle(el);
    var r = el.getBoundingClientRect();
    return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 120 && r.height > 120;
  });

  var closeSel = 'button, [role="button"], a, [class*="close" i], [aria-label*="close" i], [class*="dismiss" i]';
  for (var i = 0; i < dialogs.length; i++) {
    var d = dialogs[i];
    var candidates = Array.from(d.querySelectorAll(closeSel));
    // SVG-only close icons have no text — allow those when class/label says close
    var btn = candidates.find(function (b) {
      var t = ((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.title || '')).toLowerCase();
      var c = (typeof b.className === 'string' ? b.className : '').toLowerCase();
      return /close|dismiss|no thanks|not now|maybe later|×|✕|✖/.test(t) || c.indexOf('close') !== -1 || c.indexOf('dismiss') !== -1;
    });
    if (btn) { try { btn.click(); clicked++; } catch (e) {} }
  }

  // Second pass: dialogs still visible after clicking get removed outright.
  for (var j = 0; j < dialogs.length; j++) {
    var el = dialogs[j];
    if (!el.isConnected) continue;
    var st = getComputedStyle(el);
    if (st.display !== 'none' && st.visibility !== 'hidden') {
      el.remove();
      removed++;
    }
  }

  // Backdrops / scrims: high-z fixed layers left behind by killed modals.
  var backdrops = document.querySelectorAll('[class*="backdrop" i], [class*="scrim" i], [class*="overlay" i], [id*="backdrop" i]');
  Array.from(backdrops).forEach(function (el) {
    var s = getComputedStyle(el);
    var z = parseInt(s.zIndex || '0', 10);
    if ((s.position === 'fixed' || s.position === 'absolute') && (z >= 100 || s.backgroundColor.indexOf('rgba') === 0)) {
      el.remove();
      removed++;
    }
  });

  // Restore scrolling (modals lock body scroll).
  var scrollRestored = false;
  if (document.documentElement.style.overflow) { document.documentElement.style.overflow = ''; scrollRestored = true; }
  if (document.body && (document.body.style.overflow || document.body.style.position === 'fixed')) {
    document.body.style.overflow = '';
    document.body.style.position = '';
    scrollRestored = true;
  }
  // Common scroll-lock classes
  ['modal-open', 'no-scroll', 'noscroll', 'overflow-hidden', 'lock-scroll'].forEach(function (cls) {
    if (document.body && document.body.classList.contains(cls)) {
      document.body.classList.remove(cls);
      scrollRestored = true;
    }
    if (document.documentElement.classList.contains(cls)) {
      document.documentElement.classList.remove(cls);
      scrollRestored = true;
    }
  });

  return JSON.stringify({ clicked: clicked, removed: removed, scrollRestored: scrollRestored });
})();
