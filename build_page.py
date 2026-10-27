"""Assemble public/index.html from the dashboard page fragment (the version published as a Claude Artifact).

Usage: python build_page.py <fragment.html>
The fragment is the page body exactly as the Claude dashboard ran it; this wraps it in a full document,
defines the theme tokens the Claude runtime used to provide, and swaps asset URLs for local files.
"""
import pathlib, sys

here = pathlib.Path(__file__).parent
frag = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
frag = (frag
        .replace('/_blob/46b62e7bf31031d14b731c6dc703b401', '/assets/niete-logo.png')
        .replace('/_blob/afa670782c33f3ac033683c9439fef03', '/assets/outfit.woff2')
        .replace('/_blob/ad88c23db9decab2daa69005e6e41231', '/assets/jakarta.woff2'))
assert '/_blob/' not in frag

head = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>STEPS Teacher Evaluation</title>
<meta name="description" content="STEPS teacher evaluation for Urban-I and Barakahu: subject knowledge, teaching practices, student engagement, presence and supervisor remarks, per teacher and school.">
<link rel="icon" type="image/png" href="/assets/niete-logo.png">
<style>
:root {
  --color-bg: #F5F6F8; --color-panel: #FFFFFF; --color-fg: #1F2230; --color-fg-muted: #5E6475;
  --color-border-line: #E2E5EB; --color-ok: #2E8F5C; --color-warn: #B26B00; --color-bad: #C53030;
  --cds-chart-grid: #E8EBF0; --cds-border: #D8DCE4; --cds-surface-popover: #FFFFFF; --cds-text-secondary: #5E6475;
  --cds-shadow-popover: 0 10px 28px rgba(31, 34, 48, .16); --cds-dur-slow: .4s;
  --cds-font-size-caption: .8125rem; --cds-font-size-body: .9375rem; --cds-font-size-heading: 1.125rem; --cds-font-size-title: 1.75rem;
  --cds-font-weight-medium: 500;
  --cds-gap-xs: 4px; --cds-gap-sm: 8px; --cds-gap-md: 12px; --cds-gap-lg: 16px; --cds-gap-xl: 28px;
  --cds-pad-xs: 4px; --cds-pad-sm: 8px; --cds-pad-md: 12px; --cds-pad-lg: 18px; --cds-radius: 10px;
  --font-anthropic-sans: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --color-bg: #13151C; --color-panel: #1C1F28; --color-fg: #ECEEF3; --color-fg-muted: #A3A8B8;
    --color-border-line: #2C303C; --color-ok: #5CCB90; --color-warn: #E0A84A; --color-bad: #F07272;
    --cds-chart-grid: #2A2E3A; --cds-border: #363B48; --cds-surface-popover: #232733; --cds-text-secondary: #A3A8B8;
    --cds-shadow-popover: 0 10px 28px rgba(0, 0, 0, .5);
    color-scheme: dark;
  }
}
*, *::before, *::after { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--color-bg); color: var(--color-fg); font: 14px/1.5 var(--font-anthropic-sans); -webkit-text-size-adjust: 100%; }
#dash-root { max-width: 1280px; margin: 0 auto; padding-block: max(20px, env(safe-area-inset-top, 0px)) 32px;
  padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
img { max-width: 100%; }
[hidden] { display: none !important; }
.dash-skeleton { color: transparent !important; background: var(--cds-chart-grid); border-radius: 6px; }
.sr-chart.dash-skeleton { min-height: 160px; }
.sr-foot { margin-top: 28px; color: var(--color-fg-muted); font-size: .78rem; display: flex; flex-wrap: wrap; gap: 6px 16px; }
.sr-foot .warn { color: var(--color-warn); }
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/d3/7.9.0/d3.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/html-to-image@1.11.11/dist/html-to-image.js"></script>
<script src="/dash-shim.js?v=__BUILD__"></script>
</head>
<body>
<div id="dash-root">
"""

foot = """
<footer class="sr-foot" id="sr-foot">
  <span>Data: Taleemabad data service (BigQuery). Teacher counts use the official headcount rule; supervisor-remark figures are provisional.</span>
  <span id="sr-foot-status"></span>
</footer>
<script>
dash.onData(() => {
  const m = window.srMeta, el = document.getElementById('sr-foot-status');
  if (!m) { el.textContent = ''; return; }
  el.className = m.last_error ? 'warn' : '';
  el.textContent = m.last_error
    ? `Last refresh attempt failed; showing data from ${m.as_of || 'earlier'}.`
    : `Refreshes automatically every day at ${(m.schedule_pkt || []).join(' and ') || 'set times'} PKT.`;
});
</script>
</div>
</body>
</html>
"""

import hashlib
head = head.replace('__BUILD__', hashlib.sha1((here / 'public' / 'dash-shim.js').read_bytes()).hexdigest()[:10])
out = here / 'public' / 'index.html'
out.write_text(head + frag + foot, encoding='utf-8')
print('wrote', out, len(head + frag + foot))
