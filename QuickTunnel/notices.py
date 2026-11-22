"""Collect redistribution notices from the modules linked into the iOS connector."""
from pathlib import Path
import sys

modules = dict(line.rstrip("\n").split("\t", 1) for line in sys.stdin if line.strip())
modules["Go standard library"] = sys.argv[1]
sections = {}
for name, folder in sorted(modules.items()):
    found_license = False
    for path in sorted(Path(folder).iterdir()):
        if not path.is_file() or not path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "PATENTS")):
            continue
        if path.suffix.lower() == ".go":
            continue
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        sections.setdefault(content, []).append(name + " (" + path.name + ")")
        found_license = True
    if not found_license:
        raise SystemExit("Missing distribution notice for " + name)
output = Path(sys.argv[2])
output.parent.mkdir(exist_ok=True, parents=True)
output.write_text("\n\n".join("\n".join(names) + "\n\n" + body for body, names in sections.items()) + "\n")
