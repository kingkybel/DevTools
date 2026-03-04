import html
import json
import os
import pathlib
import sys

def main():
    if len(sys.argv) < 6:
        print("Usage: generate_report.py <coverage_json> <lcov_info> <include_dir> <coverage_dir> <cmake_root>")
        sys.exit(1)

    coverage_json_path = pathlib.Path(sys.argv[1])
    lcov_info_path = pathlib.Path(sys.argv[2])
    include_dir = pathlib.Path(sys.argv[3])
    coverage_dir = pathlib.Path(sys.argv[4])
    cmake_root = pathlib.Path(sys.argv[5]).resolve()

    header_suffixes = {".h", ".hpp", ".hh", ".hxx", ".ipp", ".tpp", ".inl"}

    def list_headers(root: pathlib.Path):
        if not root.is_dir():
            return []
        return sorted(
            p.resolve() for p in root.rglob("*")
            if p.is_file() and p.suffix.lower() in header_suffixes
        )

    def extract_metrics_from_file_obj(file_obj):
        # LLVM export format: file_obj["summary"]["lines"] has count/covered
        summary = file_obj.get("summary", {})
        lines = summary.get("lines", {})
        if isinstance(lines, dict) and ("count" in lines or "covered" in lines):
            total = int(lines.get("count", 0) or 0)
            covered = int(lines.get("covered", 0) or 0)
            return total, covered

        # gcovr JSON format fallback: file_obj["lines"] with execution counts
        if isinstance(file_obj.get("lines"), list):
            total = 0
            covered = 0
            for line in file_obj["lines"]:
                if not isinstance(line, dict):
                    continue
                if "count" not in line:
                    continue
                count = line.get("count")
                if isinstance(count, int):
                    total += 1
                    if count > 0:
                        covered += 1
            return total, covered

        # Alternative gcovr summary fields if present.
        total = int(file_obj.get("line_total", 0) or 0)
        covered = int(file_obj.get("line_covered", 0) or 0)
        return total, covered

    metrics = {}
    if coverage_json_path.is_file():
        with coverage_json_path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)

        # LLVM export layout.
        if isinstance(data.get("data"), list):
            for unit in data["data"]:
                for fobj in unit.get("files", []):
                    filename = fobj.get("filename")
                    if not filename:
                        continue
                    total, covered = extract_metrics_from_file_obj(fobj)
                    metrics[str(pathlib.Path(filename).resolve())] = (total, covered)

        # gcovr JSON layout.
        if isinstance(data.get("files"), list):
            for fobj in data["files"]:
                filename = fobj.get("file") or fobj.get("filename")
                if not filename:
                    continue
                total, covered = extract_metrics_from_file_obj(fobj)
                metrics[str((cmake_root / filename).resolve())] = (total, covered)

    # LCOV fallback (used by fastcov/genhtml path)
    if lcov_info_path.is_file():
        current_file = None
        total = 0
        covered = 0
        with lcov_info_path.open("r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.strip()
                if line.startswith("SF:"):
                    current_file = os.path.abspath(line[3:])
                    total = 0
                    covered = 0
                elif line.startswith("DA:"):
                    if current_file is None:
                        continue
                    payload = line[3:]
                    parts = payload.split(",")
                    if len(parts) < 2:
                        continue
                    try:
                        count = int(parts[1])
                    except ValueError:
                        continue
                    total += 1
                    if count > 0:
                        covered += 1
                elif line == "end_of_record":
                    if current_file is not None:
                        prev_total, prev_covered = metrics.get(current_file, (0, 0))
                        metrics[current_file] = (max(prev_total, total), max(prev_covered, covered))
                    current_file = None

    headers = list_headers(include_dir)
    rows = []
    counts = {"covered": 0, "uncovered": 0, "non_instrumentable": 0}

    for header in headers:
        abs_header = os.path.abspath(str(header))
        total, covered = metrics.get(abs_header, (0, 0))

        if total <= 0:
            status = "non-instrumentable"
            counts["non_instrumentable"] += 1
        elif covered > 0:
            status = "instrumented-covered"
            counts["covered"] += 1
        else:
            status = "instrumented-uncovered"
            counts["uncovered"] += 1

        rows.append(
            (
                str(header),
                status,
                total,
                covered,
                f"{(covered / total * 100.0):.2f}%" if total > 0 else "n/a",
            )
        )

    def render_row(row):
        path, status, total, covered, pct = row
        css = {
            "instrumented-covered": "covered",
            "instrumented-uncovered": "uncovered",
            "non-instrumentable": "noninst",
        }[status]
        return (
            f"<tr class='{css}'>"
            f"<td><code>{html.escape(path)}</code></td>"
            f"<td>{html.escape(status)}</td>"
            f"<td>{total}</td>"
            f"<td>{covered}</td>"
            f"<td>{pct}</td>"
            "</tr>"
        )

    header_inventory_html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Header Inventory</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 1.5rem; }}
    .summary {{ display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1rem; }}
    .pill {{ padding: 0.4rem 0.7rem; border-radius: 999px; font-size: 0.9rem; }}
    .covered-pill {{ background: #d1fae5; color: #065f46; }}
    .uncovered-pill {{ background: #fee2e2; color: #991b1b; }}
    .noninst-pill {{ background: #e5e7eb; color: #374151; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ border: 1px solid #d1d5db; padding: 0.5rem; text-align: left; }}
    th {{ background: #f3f4f6; }}
    tr.covered {{ background: #ecfdf5; }}
    tr.uncovered {{ background: #fef2f2; }}
    tr.noninst {{ background: #f9fafb; }}
  </style>
</head>
<body>
  <h1>Include Header Inventory</h1>
  <p>Classification uses coverage data plus files discovered under <code>{html.escape(str(include_dir))}</code>.</p>
  <div class="summary">
    <span class="pill covered-pill">Instrumented + covered: {counts["covered"]}</span>
    <span class="pill uncovered-pill">Instrumented + uncovered: {counts["uncovered"]}</span>
    <span class="pill noninst-pill">Non-instrumentable: {counts["non_instrumentable"]}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Header</th>
        <th>Status</th>
        <th>Coverable Lines</th>
        <th>Covered Lines</th>
        <th>Coverage</th>
      </tr>
    </thead>
    <tbody>
      {"".join(render_row(row) for row in rows)}
    </tbody>
  </table>
</body>
</html>
"""

    coverage_dir.mkdir(parents=True, exist_ok=True)
    (coverage_dir / "header_inventory.html").write_text(header_inventory_html, encoding="utf-8")

    overview_html = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Coverage Dashboard</title>
  <style>
    body { margin: 0; font-family: system-ui, sans-serif; background: #f8fafc; color: #0f172a; }
    .top { padding: 1rem 1rem 0.6rem; background: #ffffff; border-bottom: 1px solid #e2e8f0; position: sticky; top: 0; z-index: 20; }
    .title { margin: 0 0 0.75rem 0; font-size: 1.1rem; font-weight: 650; }
    .tabs { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .tab-btn { border: 1px solid #cbd5e1; background: #f8fafc; color: #0f172a; border-radius: 0.5rem; padding: 0.45rem 0.8rem; cursor: pointer; font-weight: 600; }
    .tab-btn.active { background: #0f172a; color: #f8fafc; border-color: #0f172a; }
    .panel { display: none; padding: 1rem; }
    .panel.active { display: block; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 0.8rem; margin-bottom: 1rem; }
    .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 0.75rem; padding: 0.85rem; }
    .card h2 { margin: 0 0 0.35rem; font-size: 0.95rem; }
    .frame-wrap { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 0.75rem; overflow: hidden; }
    iframe { width: 100%; height: calc(100vh - 11rem); border: 0; display: block; background: #ffffff; }
    code { background: #e2e8f0; border-radius: 0.3rem; padding: 0.1rem 0.3rem; }
    a { color: #1d4ed8; }
  </style>
</head>
<body>
  <div class="top">
    <h1 class="title">Coverage Dashboard</h1>
    <div class="tabs">
      <button class="tab-btn active" data-tab="overview">Overview</button>
      <button class="tab-btn" data-tab="main">Main Report</button>
      <button class="tab-btn" data-tab="headers">Header Inventory</button>
    </div>
  </div>

  <section class="panel active" data-panel="overview">
    <div class="cards">
      <div class="card">
        <h2>Main Coverage Report</h2>
        <div>Full source and line-by-line coverage pages.</div>
      </div>
      <div class="card">
        <h2>Header Inventory</h2>
        <div>Headers under <code>include/</code> classified as covered, uncovered, or non-instrumentable.</div>
      </div>
      <div class="card">
        <h2>Direct Links</h2>
        <div><a href="/coverage_main.html" target="_blank" rel="noopener">Open main report</a></div>
        <div><a href="/header_inventory.html" target="_blank" rel="noopener">Open header inventory</a></div>
      </div>
    </div>
  </section>

  <section class="panel" data-panel="main">
    <div class="frame-wrap"><iframe src="/coverage_main.html" title="Main Coverage Report"></iframe></div>
  </section>

  <section class="panel" data-panel="headers">
    <div class="frame-wrap"><iframe src="/header_inventory.html" title="Header Inventory"></iframe></div>
  </section>

  <script>
    (function () {
      const buttons = Array.from(document.querySelectorAll('.tab-btn'));
      const panels = Array.from(document.querySelectorAll('.panel'));
      function setTab(name) {
        buttons.forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
        panels.forEach((p) => p.classList.toggle('active', p.dataset.panel === name));
      }
      buttons.forEach((btn) => btn.addEventListener('click', () => setTab(btn.dataset.tab)));
    })();
  </script>
</body>
</html>
"""
    main_report = coverage_dir / "index.html"
    if main_report.is_file():
        # Keep the tool-generated report as a dedicated page.
        main_report.rename(coverage_dir / "coverage_main.html")

    # Publish the tabbed dashboard as both overview and default index.
    (coverage_dir / "overview.html").write_text(overview_html, encoding="utf-8")
    (coverage_dir / "index.html").write_text(overview_html, encoding="utf-8")

if __name__ == "__main__":
    main()
