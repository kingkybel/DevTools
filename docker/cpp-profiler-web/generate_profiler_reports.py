import html
import pathlib
import sys

def main():
    if len(sys.argv) < 6:
        print("Usage: generate_profiler_reports.py <result_dir> <exe_path> <source_root> <perf_freq> <record_rc> <exe_args>")
        sys.exit(1)

    result_dir = pathlib.Path(sys.argv[1])
    exe_path = sys.argv[2]
    source_root = sys.argv[3]
    perf_freq = sys.argv[4]
    record_rc = int(sys.argv[5])
    exe_args = sys.argv[6]

    report_path = result_dir / "perf_report.txt"
    stderr_path = result_dir / "perf_report.stderr"
    script_stderr_path = result_dir / "perf_script.stderr"
    record_stderr_path = result_dir / "perf_record.stderr"
    flamegraph_path = result_dir / "flamegraph.svg"

    report_text = report_path.read_text(encoding="utf-8", errors="replace") if report_path.exists() else ""
    report_err = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
    script_err = script_stderr_path.read_text(encoding="utf-8", errors="replace") if script_stderr_path.exists() else ""
    record_err = record_stderr_path.read_text(encoding="utf-8", errors="replace") if record_stderr_path.exists() else ""

    if flamegraph_path.exists():
        flame_html = """<!doctype html><html><head><meta charset='utf-8'><title>Flamegraph</title>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<style>body{margin:0;background:#fff;font-family:system-ui,sans-serif}object{width:100%;height:100vh;border:0}</style>
</head><body><object data="/flamegraph.svg" type="image/svg+xml"></object></body></html>"""
    else:
        flame_html = """<!doctype html><html><head><meta charset='utf-8'><title>Flamegraph</title>
<style>body{font-family:system-ui,sans-serif;margin:1rem}code{background:#f1f5f9;padding:0.15rem 0.3rem;border-radius:0.2rem}</style>
</head><body><h2>No flamegraph available</h2><p>Check <code>perf_script.stderr</code> and <code>perf_report.stderr</code> for details.</p></body></html>"""
    (result_dir / "flame.html").write_text(flame_html, encoding="utf-8")

    report_page = """<!doctype html><html><head><meta charset='utf-8'><title>perf report</title>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#f8fafc}
.top{position:sticky;top:0;background:#fff;border-bottom:1px solid #e2e8f0;padding:0.75rem}
.main{padding:0.9rem}
pre{white-space:pre-wrap;background:#fff;border:1px solid #e2e8f0;border-radius:0.5rem;padding:0.8rem}
input{padding:0.4rem 0.55rem;border:1px solid #cbd5e1;border-radius:0.4rem;min-width:280px}
.muted{color:#475569}
</style></head><body>
<div class='top'>
<h2 style='margin:0 0 0.55rem'>perf report</h2>
<input id='q' type='text' placeholder='Filter report lines'>
<div class='muted' id='summary'></div>
</div>
<div class='main'><pre id='report'>__REPORT__</pre></div>
<script>
const raw=`__RAW__`.split('\\n');
const report=document.getElementById('report');
const q=document.getElementById('q');
const summary=document.getElementById('summary');
function render(){
  const term=(q.value||'').toLowerCase();
  const filtered=term?raw.filter(l=>l.toLowerCase().includes(term)):raw;
  report.textContent=filtered.join('\\n');
  summary.textContent=`Showing ${filtered.length} of ${raw.length} lines`;
}
q.addEventListener('input',render);
render();
</script></body></html>"""
    escaped_report = html.escape(report_text if report_text else "No perf report output generated.")
    js_raw = (report_text if report_text else "No perf report output generated.").replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
    report_page = report_page.replace("__REPORT__", escaped_report).replace("__RAW__", js_raw)
    (result_dir / "report.html").write_text(report_page, encoding="utf-8")

    status = "ok" if record_rc == 0 else f"failed (exit {record_rc})"
    overview = f"""<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>CPU Profiler Dashboard</title>
<style>
body{{margin:0;font-family:system-ui,sans-serif;background:#f8fafc}}
.top{{position:sticky;top:0;z-index:10;background:#fff;border-bottom:1px solid #e2e8f0;padding:0.8rem}}
.tabs{{display:flex;gap:0.5rem;flex-wrap:wrap}}
.tab{{border:1px solid #cbd5e1;background:#f8fafc;padding:0.45rem 0.8rem;border-radius:0.5rem;cursor:pointer}}
.tab.active{{background:#0f172a;color:#fff;border-color:#0f172a}}
.panel{{display:none;padding:0.8rem}}
.panel.active{{display:block}}
iframe{{width:100%;height:calc(100vh - 14rem);border:1px solid #e2e8f0;background:#fff;border-radius:0.5rem}}
code{{background:#e2e8f0;padding:0.1rem 0.3rem;border-radius:0.2rem}}
pre{{white-space:pre-wrap;background:#fff;border:1px solid #e2e8f0;border-radius:0.5rem;padding:0.8rem}}
</style>
</head>
<body>
  <div class='top'>
    <div class='tabs'>
      <button class='tab active' data-tab='overview'>Overview</button>
      <button class='tab' data-tab='flame'>Flamegraph</button>
      <button class='tab' data-tab='report'>perf report</button>
    </div>
  </div>

  <section class='panel active' data-panel='overview'>
    <h2>CPU Profiling Run</h2>
    <p><b>Status:</b> {html.escape(status)}</p>
    <p><b>Executable:</b> <code>{html.escape(exe_path)}</code></p>
    <p><b>Args:</b> <code>{html.escape(exe_args if exe_args else "(none)")}</code></p>
    <p><b>Source root:</b> <code>{html.escape(source_root)}</code></p>
    <p><b>Sample frequency:</b> <code>{html.escape(perf_freq)} Hz</code></p>
    <p>Use the tabs to inspect the generated flamegraph and textual perf report.</p>
    <h3>Diagnostics</h3>
    <pre>{html.escape((
        ("[perf record]\\n" + record_err.strip() + "\\n\\n") if record_err.strip() else ""
    ) + (
        ("[perf report]\\n" + report_err.strip() + "\\n\\n") if report_err.strip() else ""
    ) + (
        ("[perf script]\\n" + script_err.strip()) if script_err.strip() else ""
    ) or "No perf diagnostics emitted.")}</pre>
  </section>
  <section class='panel' data-panel='flame'><iframe src='/flame.html' title='Flamegraph'></iframe></section>
  <section class='panel' data-panel='report'><iframe src='/report.html' title='perf report'></iframe></section>
<script>
const tabs=[...document.querySelectorAll('.tab')];
const panels=[...document.querySelectorAll('.panel')];
function setTab(name){{tabs.forEach(t=>t.classList.toggle('active',t.dataset.tab===name));panels.forEach(p=>p.classList.toggle('active',p.dataset.panel===name));}}
tabs.forEach(t=>t.addEventListener('click',()=>setTab(t.dataset.tab)));
</script>
</body></html>"""
    (result_dir / "index.html").write_text(overview, encoding="utf-8")

if __name__ == "__main__":
    main()
