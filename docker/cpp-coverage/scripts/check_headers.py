import json
import sys

def main():
    if len(sys.argv) < 3:
        print("Usage: check_headers.py <coverage_json> <include_prefix>")
        sys.exit(1)

    path = sys.argv[1]
    prefix = sys.argv[2]

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    seen = set()
    for entry in data.get("data", []):
        for fobj in entry.get("files", []):
            filename = fobj.get("filename", "")
            if filename.startswith(prefix):
                seen.add(filename)

    print(len(seen))

if __name__ == "__main__":
    main()
