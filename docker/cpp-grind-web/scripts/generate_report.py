import html
import os
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

def main():
    if len(sys.argv) < 3:
        print("Usage: generate_report.py <source_root> <result_dir>")
        sys.exit(1)

    source_root = pathlib.Path(sys.argv[1]).resolve()
    result_dir = pathlib.Path(sys.argv[2]).resolve()
    src_out = result_dir / "src"
    src_out.mkdir(parents=True, exist_ok=True)

    exts = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".ipp", ".tpp", ".inl"}

    def safe_rel(path: pathlib.Path) -> pathlib.Path:
        try:
            return path.resolve().relative_to(source_root)
        except Exception:
            return pathlib.Path("_external") / path.name

    # Generate source browser pages with line anchors.
    source_map = {}
    if source_root.is_dir():
        for p in source_root.rglob("*"):
            if not p.is_file() or p.suffix.lower() not in exts:
                continue
            rel = safe_rel(p)
            out = src_out / (str(rel) + ".html")
            out.parent.mkdir(parents=True, exist_ok=True)
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
            body = []
            for i, line in enumerate(lines, 1):
                body.append(f"<tr><td><a id='L{i}' href='#L{i}'>{i}</a></td><td><pre>{html.escape(line)}</pre></td></tr>")
            out.write_text(
                "<!doctype html><html><head><meta charset='utf-8'><title>{}</title>"
                "<style>body{{font-family:system-ui,sans-serif;margin:1rem}}table{{border-collapse:collapse;width:100%}}"
                "td{{vertical-align:top;border-bottom:1px solid #eee}}td:first-child{{width:5rem;color:#666}}pre{{margin:0;white-space:pre-wrap}}"
                "</style></head><body><h1><code>{}</code></h1><table>{}</table></body></html>".format(
                    html.escape(str(rel)), html.escape(str(rel)), "".join(body)
                ),
                encoding="utf-8",
            )
            source_map[str(p.resolve())] = out.relative_to(result_dir).as_posix()

    path_any_re = re.compile(
        r"(?P<pathline>/[^:\\s]+\\.(?:c|cc|cpp|cxx|h|hh|hpp|hxx|ipp|tpp|inl):(?P<line>\\d+))"
        r"|(?P<path>/[^:\\s]+\\.(?:c|cc|cpp|cxx|h|hh|hpp|hxx|ipp|tpp|inl))(?P<trail>:?)"
    )

    def source_out_rel_for(path: pathlib.Path) -> pathlib.Path:
        try:
            rel = path.resolve().relative_to(source_root)
        except Exception:
            rel = pathlib.Path("_external") / path.resolve().as_posix().lstrip("/")
        return pathlib.Path(str(rel) + ".html")

    def register_source(path_str: str):
        p = pathlib.Path(path_str)
        if not p.is_file():
            return None
        if p.suffix.lower() not in exts:
            return None
        resolved = p.resolve()
        key = str(resolved)
        if key in source_map:
            return source_map[key]

        rel_out = source_out_rel_for(resolved)
        out = src_out / rel_out
        out.parent.mkdir(parents=True, exist_ok=True)
        lines = resolved.read_text(encoding="utf-8", errors="replace").splitlines()
        body = []
        for i, line in enumerate(lines, 1):
            body.append(f"<tr><td><a id='L{i}' href='#L{i}'>{i}</a></td><td><pre>{html.escape(line)}</pre></td></tr>")
        out.write_text(
            "<!doctype html><html><head><meta charset='utf-8'><title>{}</title>"
            "<style>body{{font-family:system-ui,sans-serif;margin:1rem}}table{{border-collapse:collapse;width:100%}}"
            "td{{vertical-align:top;border-bottom:1px solid #eee}}td:first-child{{width:5rem;color:#666}}pre{{margin:0;white-space:pre-wrap}}"
            "</style></head><body><h1><code>{}</code></h1><table>{}</table></body></html>".format(
                html.escape(str(resolved)), html.escape(str(resolved)), "".join(body)
            ),
            encoding="utf-8",
        )
        rel = out.relative_to(result_dir).as_posix()
        source_map[key] = rel
        return rel

    def linkify_text(text: str) -> str:
        pieces = []
        last = 0
        for m in path_any_re.finditer(text):
            pieces.append(html.escape(text[last:m.start()]))

            if m.group("pathline"):
                raw_path = m.group("pathline").rsplit(":", 1)[0]
                line = m.group("line")
                rel = register_source(raw_path)
                label = html.escape(m.group("pathline"))
                if rel:
                    pieces.append(f"<a href='/{rel}#L{line}' target='_blank' rel='noopener'>{label}</a>")
                else:
                    pieces.append(label)
            else:
                raw_path = m.group("path")
                trail = m.group("trail") or ""
                rel = register_source(raw_path)
                label = html.escape(raw_path)
                if rel:
                    pieces.append(f"<a href='/{rel}' target='_blank' rel='noopener'>{label}</a>{html.escape(trail)}")
                else:
                    pieces.append(label + html.escape(trail))

            last = m.end()

        pieces.append(html.escape(text[last:]))
        return "".join(pieces)

    # Parse valgrind XML into readable HTML.
    val_html = ["<h2>Valgrind (Memcheck)</h2>"]
    xml_path = result_dir / "valgrind.xml"
    if xml_path.exists():
        try:
            root = ET.parse(xml_path).getroot()
            errs = root.findall("error")
            val_html.append(f"<p>Found {len(errs)} error(s).</p>")
            for idx, err in enumerate(errs, 1):
                kind = err.findtext("kind", default="unknown")
                what = err.findtext("what") or err.findtext("xwhat/text", default="")
                val_html.append(f"<details><summary><b>{idx}. {html.escape(kind)}</b> {html.escape(what)}</summary>")
                for stack in err.findall("stack"):
                    val_html.append("<ol>")
                    for frame in stack.findall("frame"):
                        fn = frame.findtext("fn", default="?")
                        file = frame.findtext("file", default="")
                        line = frame.findtext("line", default="")
                        loc = f"{file}:{line}" if file and line else file
                        linked = linkify_text(loc) if loc else ""
                        val_html.append(f"<li><code>{html.escape(fn)}</code> {linked}</li>")
                    val_html.append("</ol>")
                val_html.append("</details>")
        except Exception as e:
            val_html.append(f"<pre>Failed to parse valgrind.xml: {html.escape(str(e))}</pre>")
    else:
        val_html.append("<p>No valgrind XML result found.</p>")
    (result_dir / "val.html").write_text(
        "<!doctype html><html><head><meta charset='utf-8'><title>Valgrind</title>"
        "<style>body{{font-family:system-ui,sans-serif;margin:1rem}}code{{background:#f1f5f9;padding:0.1rem 0.3rem;border-radius:0.2rem}}</style>"
        "</head><body>{}</body></html>".format("\n".join(val_html)),
        encoding="utf-8",
    )

    for name, title in [("cachegrind.txt", "Cachegrind"), ("callgrind.txt", "Callgrind")]:
        p = result_dir / name
        out = result_dir / ("cache.html" if "cache" in name else "call.html")
        if p.exists():
            text = p.read_text(encoding="utf-8", errors="replace")
            lines = text.splitlines()
            file_header_re = re.compile(r"^\s*<\s+.*\s+/[^\s:]+\.(?:c|cc|cpp|cxx|h|hh|hpp|hxx|ipp|tpp|inl):\s*$")
            section_item_re = re.compile(r"^\s+\d")
            blocks = []
            i = 0
            while i < len(lines):
                line = lines[i]
                if file_header_re.match(line):
                    header = line
                    j = i + 1
                    body = []
                    while j < len(lines) and (section_item_re.match(lines[j]) or lines[j].strip() == ""):
                        body.append(lines[j])
                        j += 1
                    header_html = linkify_text(header)
                    body_html = linkify_text("\n".join(body)) if body else "<i>No entries</i>"
                    blocks.append(
                        "<div class='grind-block section'>"
                        "<details open><summary><code>{}</code></summary><pre>{}</pre></details>"
                        "</div>".format(
                            header_html, body_html
                        )
                    )
                    i = j
                    continue
                blocks.append("<div class='grind-block line'><pre>{}</pre></div>".format(linkify_text(line)))
                i += 1
            content = "\n".join(blocks)
        else:
            content = f"<p>No {html.escape(title.lower())} result found.</p>"
        
        page_html = """<!doctype html><html><head><meta charset='utf-8'><title>__TITLE__</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;background:#f8fafc}
.top{position:sticky;top:0;z-index:10;background:#fff;border-bottom:1px solid #e2e8f0;padding:0.75rem}
.main{padding:1rem}
.controls{display:flex;gap:0.6rem;flex-wrap:wrap;align-items:center}
.controls input[type='text']{min-width:280px;padding:0.35rem 0.55rem;border:1px solid #cbd5e1;border-radius:0.4rem}
.controls button{padding:0.35rem 0.6rem;border:1px solid #cbd5e1;background:#fff;border-radius:0.4rem;cursor:pointer}
.controls label{display:flex;gap:0.35rem;align-items:center;font-size:0.92rem}
.summary{font-size:0.9rem;color:#475569;margin-top:0.45rem}
.grind-block{margin-bottom:0.45rem}
.grind-block.hidden{display:none}
pre{white-space:pre-wrap;font-family:ui-monospace,monospace;background:#fff;border:1px solid #e2e8f0;padding:0.6rem;border-radius:0.45rem;margin:0}
details>summary{cursor:pointer;background:#fff;border:1px solid #e2e8f0;padding:0.45rem 0.55rem;border-radius:0.45rem}
details>pre{margin-top:0.3rem}
a{color:#1d4ed8}
</style>
</head><body>
<div class='top'>
<h2 style='margin:0 0 0.55rem'>__TITLE__</h2>
<div class='controls'>
<input id='filterText' type='text' placeholder='Filter text (file, symbol, path, line...)'>
<label><input id='linkedOnly' type='checkbox'> linked only</label>
<button id='expandAll' type='button'>Expand all</button>
<button id='collapseAll' type='button'>Collapse all</button>
<button id='resetFilter' type='button'>Reset</button>
</div>
<div id='filterSummary' class='summary'></div>
</div>
<div class='main' id='contentRoot'>__CONTENT__</div>
<script>
(function(){
const root=document.getElementById('contentRoot');
const blocks=[...root.querySelectorAll('.grind-block')];
const details=[...root.querySelectorAll('details')];
const txt=document.getElementById('filterText');
const linked=document.getElementById('linkedOnly');
const summary=document.getElementById('filterSummary');
function apply(){
  const q=(txt.value||'').toLowerCase();
  const onlyLinked=linked.checked;
  let shown=0;
  for(const b of blocks){
    const t=(b.innerText||'').toLowerCase();
    const hasLink=b.querySelector('a')!==null;
    const okText=!q||t.includes(q);
    const okLink=!onlyLinked||hasLink;
    const show=okText&&okLink;
    b.classList.toggle('hidden',!show);
    if(show) shown++;
  }
  summary.textContent=`Showing ${shown} of ${blocks.length} blocks`;
}
txt.addEventListener('input',apply);
linked.addEventListener('change',apply);
document.getElementById('resetFilter').addEventListener('click',()=>{txt.value='';linked.checked=false;apply();});
document.getElementById('expandAll').addEventListener('click',()=>details.forEach(d=>d.open=true));
document.getElementById('collapseAll').addEventListener('click',()=>details.forEach(d=>d.open=false));
apply();
})();
</script>
</body></html>"""
        page_html = page_html.replace("__TITLE__", html.escape(title)).replace("__CONTENT__", content)
        out.write_text(page_html, encoding="utf-8")

    index = """<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>Grind Analysis Dashboard</title>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#f8fafc}
.top{position:sticky;top:0;z-index:10;background:#fff;border-bottom:1px solid #e2e8f0;padding:0.8rem}
.tabs{display:flex;gap:0.5rem;flex-wrap:wrap}
.tab{border:1px solid #cbd5e1;background:#f8fafc;padding:0.45rem 0.8rem;border-radius:0.5rem;cursor:pointer}
.tab.active{background:#0f172a;color:#fff;border-color:#0f172a}
.panel{display:none;padding:0.8rem}
.panel.active{display:block}
iframe{width:100%;height:calc(100vh - 6rem);border:1px solid #e2e8f0;background:#fff;border-radius:0.5rem}
</style>
</head>
<body>
  <div class='top'>
    <div class='tabs'>
      <button class='tab active' data-tab='overview'>Overview</button>
      <button class='tab' data-tab='val'>Valgrind</button>
      <button class='tab' data-tab='cache'>Cachegrind</button>
      <button class='tab' data-tab='call'>Callgrind</button>
    </div>
  </div>
  <section class='panel active' data-panel='overview'>
    <h2>Grind Analysis</h2>
    <p>Tabs show results from selected tools. Source links open in new tab where file+line information exists.</p>
  </section>
  <section class='panel' data-panel='val'><iframe src='/val.html' title='Valgrind'></iframe></section>
  <section class='panel' data-panel='cache'><iframe src='/cache.html' title='Cachegrind'></iframe></section>
  <section class='panel' data-panel='call'><iframe src='/call.html' title='Callgrind'></iframe></section>
<script>
const tabs=[...document.querySelectorAll('.tab')];
const panels=[...document.querySelectorAll('.panel')];
function setTab(name){tabs.forEach(t=>t.classList.toggle('active',t.dataset.tab===name));panels.forEach(p=>p.classList.toggle('active',p.dataset.panel===name));}
tabs.forEach(t=>t.addEventListener('click',()=>setTab(t.dataset.tab)));
</script>
</body></html>"""
    (result_dir / "index.html").write_text(index, encoding="utf-8")

if __name__ == "__main__":
    main()
