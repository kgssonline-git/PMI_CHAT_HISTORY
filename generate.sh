#!/usr/bin/env bash
# Generates index.html from the latest WhatsApp chat zip in the current directory.
# Run: bash generate.sh

set -euo pipefail
cd "$(dirname "$0")"

ZIP=$(ls -t *.zip 2>/dev/null | head -1)
if [[ -z "$ZIP" ]]; then
  echo "No .zip file found in $(pwd)" >&2
  exit 1
fi

echo "Using: $ZIP"
rm -rf /tmp/wa_extract
unzip -q -o "$ZIP" -d /tmp/wa_extract

# Find the .txt file (flat or inside a subdirectory)
TXT=$(find /tmp/wa_extract -maxdepth 2 -name "*.txt" | head -1)
if [[ -z "$TXT" ]]; then
  echo "No .txt file found inside zip" >&2
  exit 1
fi
echo "Chat file: $TXT"

# Copy images into repo so GitHub Pages can serve them
mkdir -p images
find /tmp/wa_extract -maxdepth 2 \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) \
  -exec cp -n {} images/ \;
echo "Images copied → images/"

CHAT_FOLDER_NAME="images"

python3 - "$TXT" "$CHAT_FOLDER_NAME" <<'PYEOF'
import sys, re, html as ht, os, pathlib

txt_path   = sys.argv[1]
folder     = sys.argv[2]   # relative image directory used in HTML hrefs
img_prefix = (folder + "/") if folder else ""

with open(txt_path, encoding="utf-8") as f:
    raw = f.read()

# ── Parse ──────────────────────────────────────────────────────────────────
# U+202F (narrow no-break space) sits between time digits and am/pm
LINE_RE = re.compile(
    r'^(\d{1,2}/\d{2}/\d{2,4}), (\d{1,2}:\d{2}[ \s][ap]m) - (.*)',
    re.MULTILINE
)

messages = []
prev_end  = 0
matches   = list(LINE_RE.finditer(raw))

for i, m in enumerate(matches):
    end = matches[i+1].start() if i+1 < len(matches) else len(raw)
    date    = m.group(1)
    time    = m.group(2).replace(' ', ' ')  # keep as-is
    content = raw[m.start(3):end].strip()
    messages.append({"date": date, "time": time, "content": content})

# ── Helpers ────────────────────────────────────────────────────────────────
SYSTEM_PREFIXES = (
    "Messages and calls", "Welcome to the group", "You're now an admin",
    "This group is", "You created group",
)

def is_system(content):
    for p in SYSTEM_PREFIXES:
        if content.startswith(p):
            return True
    # If no ": " within first 40 chars it's likely system
    ci = content.find(": ")
    return ci < 0 or ci >= 40

def parse_sender(content):
    ci = content.find(": ")
    if ci <= 0 or ci >= 40:
        return None, content
    candidate = content[:ci]
    if re.search(r'^(Messages|Welcome|You\'|This|All|Your)', candidate):
        return None, content
    return candidate, content[ci+2:]

PALETTE = ["#E91E8C","#E53935","#8E24AA","#00897B","#F57C00","#1E88E5","#43A047"]
color_map = {}
color_idx = [0]

def sender_color(name):
    if name not in color_map:
        color_map[name] = PALETTE[color_idx[0] % len(PALETTE)]
        color_idx[0] += 1
    return color_map[name]

IMG_RE  = re.compile(r'^(IMG-\S+\.jpg)\s+\(file attached\)', re.IGNORECASE)
URL_RE  = re.compile(r'(https?://[^\s<>"]+)')
BOLD_RE = re.compile(r'\*([^*\n]+)\*')

lb_count = [0]

def linkify(text):
    h = ht.escape(text)
    h = BOLD_RE.sub(r'<strong>\1</strong>', h)
    h = URL_RE.sub(r'<a href="\1" target="_blank" rel="noopener">\1</a>', h)
    return h

def render_body(body, sender):
    img_m = IMG_RE.match(body)
    if img_m:
        fname   = img_m.group(1)
        img_src = img_prefix + fname
        caption = body[img_m.end():].strip()
        lb_count[0] += 1
        lb_id = f"lb{lb_count[0]}"
        cap_html = f'<div class="cap">{linkify(caption)}</div>' if caption else ""
        return (
            f'<a href="#{lb_id}" class="img-link">'
            f'<img src="{ht.escape(img_src)}" class="thumb" loading="lazy" alt="{ht.escape(fname)}">'
            f'</a>'
            f'<div id="{lb_id}" class="lightbox"><a href="#!" class="lb-close"></a>'
            f'<img src="{ht.escape(img_src)}" alt="{ht.escape(fname)}"></div>'
            + cap_html
        )

    if body == "<Media omitted>":
        return '<span class="media-omit">📎 Media not available</span>'

    if body.startswith("POLL:\n") or body.startswith("POLL:"):
        lines  = [l for l in body.split("\n") if l.strip()]
        q      = lines[1] if len(lines) > 1 else ""
        opts   = [l.replace("OPTION: ", "") for l in lines[2:] if l.startswith("OPTION: ")]
        opts_h = "".join(
            f'<div class="opt">&#9711; {ht.escape(o)}</div>' for o in opts
        )
        return f'<div class="poll"><div class="poll-q">📊 {ht.escape(q)}</div>{opts_h}</div>'

    return f'<span class="txt">{linkify(body)}</span>'

# ── Date formatter ─────────────────────────────────────────────────────────
import datetime

def fmt_date(d):
    parts = d.split("/")
    day, mon, yr = int(parts[0]), int(parts[1]), int(parts[2])
    if yr < 100:
        yr += 2000
    try:
        dt = datetime.date(yr, mon, day)
        return dt.strftime("%-d %B %Y")   # e.g. "17 January 2025"
    except:
        return d

# ── Build HTML ─────────────────────────────────────────────────────────────
CSS = """
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
     background:#E5DDD5;min-height:100vh;display:flex;flex-direction:column}
.header{background:#075E54;color:#fff;padding:10px 16px;display:flex;align-items:center;
        gap:12px;position:sticky;top:0;z-index:10;box-shadow:0 2px 5px rgba(0,0,0,.3)}
.avatar{width:42px;height:42px;border-radius:50%;background:#128C7E;
        display:flex;align-items:center;justify-content:center;font-size:22px;flex-shrink:0}
.hinfo h1{font-size:16px;font-weight:600}
.hinfo p{font-size:12px;opacity:.75;margin-top:1px}
.bg{flex:1;padding:10px 12px 30px;
    background-image:url("data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='%23c5b8ad' fill-opacity='0.25'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/svg%3E")}
.inner{max-width:820px;margin:0 auto}
.date-sep{text-align:center;margin:14px 0 6px}
.date-sep span{background:#D1F0E0;color:#4B6356;font-size:12px;font-weight:500;
               padding:4px 14px;border-radius:8px;box-shadow:0 1px 2px rgba(0,0,0,.1)}
.sys{text-align:center;margin:3px 0}
.sys span{background:#D1F0E0;color:#4B6356;font-size:12px;
          padding:3px 12px;border-radius:8px;display:inline-block}
.row{display:flex;margin:2px 0}
.bubble{background:#fff;border-radius:0 8px 8px 8px;padding:6px 9px 5px;
        max-width:min(78%,560px);box-shadow:0 1px 2px rgba(0,0,0,.12);
        position:relative;word-break:break-word}
.bubble::before{content:'';position:absolute;top:0;left:-8px;
                border-top:8px solid #fff;border-left:8px solid transparent}
.sname{font-size:13px;font-weight:700;margin-bottom:3px}
.txt{font-size:14px;color:#111;line-height:1.5;white-space:pre-wrap}
a{color:#0078D4;text-decoration:none}
a:hover{text-decoration:underline}
.ts{font-size:11px;color:#9E9E9E;text-align:right;margin-top:4px}
.thumb{display:block;max-width:280px;max-height:280px;border-radius:6px;
       margin-bottom:4px;cursor:zoom-in;object-fit:cover}
.cap{font-size:13px;color:#333;margin-top:3px;line-height:1.4;white-space:pre-wrap}
.media-omit{font-size:13px;color:#888;font-style:italic}
.poll{background:#f0f4f8;border-left:3px solid #25D366;border-radius:4px;padding:7px 10px;margin-top:2px}
.poll-q{font-size:13px;font-weight:600;color:#333;margin-bottom:6px}
.opt{font-size:13px;color:#444;padding:3px 0}
/* CSS lightbox */
.lightbox{display:none;position:fixed;inset:0;background:rgba(0,0,0,.88);
          z-index:100;align-items:center;justify-content:center}
.lightbox:target{display:flex}
.lightbox img{max-width:92vw;max-height:92vh;border-radius:4px}
.lb-close{position:absolute;inset:0;cursor:zoom-out}
.lb-close::after{content:'✕';position:absolute;top:16px;right:24px;
                 color:#fff;font-size:32px;line-height:1}
@media(max-width:520px){.bubble{max-width:90%}.thumb{max-width:200px;max-height:200px}}
"""

rows = []
last_date = None

for msg in messages:
    d = msg["date"]
    if d != last_date:
        last_date = d
        rows.append(f'<div class="date-sep"><span>{ht.escape(fmt_date(d))}</span></div>')

    content = msg["content"]
    time    = msg["time"].replace(' ', ' ')

    if is_system(content):
        rows.append(f'<div class="sys"><span>{ht.escape(content)}</span></div>')
        continue

    sender, body = parse_sender(content)
    if sender is None:
        rows.append(f'<div class="sys"><span>{ht.escape(content)}</span></div>')
        continue

    color   = sender_color(sender)
    body_h  = render_body(body, sender)
    rows.append(
        f'<div class="row">'
        f'<div class="bubble">'
        f'<div class="sname" style="color:{color}">{ht.escape(sender)}</div>'
        f'{body_h}'
        f'<div class="ts">{ht.escape(time)}</div>'
        f'</div></div>'
    )

rows_html = "\n".join(rows)

html_out = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PMI - Market Updates</title>
<style>
{CSS}
</style>
</head>
<body>
<header class="header">
  <div class="avatar">📊</div>
  <div class="hinfo">
    <h1>PMI – Market Updates</h1>
    <p>WhatsApp Group Chat</p>
  </div>
</header>
<div class="bg">
  <div class="inner">
{rows_html}
  </div>
</div>
</body>
</html>
"""

out_path = "index.html"
with open(out_path, "w", encoding="utf-8") as f:
    f.write(html_out)

print(f"Written {len(messages)} messages → {out_path}")
PYEOF

echo "Done. Open index.html in a browser."
