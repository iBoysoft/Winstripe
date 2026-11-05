#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-/tmp/swiftpm-cache}"
set -- --cache-path "$SWIFTPM_CACHE_PATH"
if theme_build_output=$(swift build -c release "$@" 2>&1); then
    printf '%s\n' "$theme_build_output"
else
    printf '%s\n' "$theme_build_output" >&2
    exit 1
fi
case "$theme_build_output" in
    *warning:*|*error:*) printf 'FAIL release build diagnostics\n' >&2; exit 1 ;;
esac
printf 'PASS zero-warning release build\n'
if theme_debug_output=$(swift build -c debug "$@" 2>&1); then
    printf '%s\n' "$theme_debug_output"
else
    printf '%s\n' "$theme_debug_output" >&2
    exit 1
fi
case "$theme_debug_output" in
    *warning:*|*error:*) printf 'FAIL debug build diagnostics\n' >&2; exit 1 ;;
esac
theme_debug_binary=$(swift build -c debug --show-bin-path "$@")/Winstripe
"$theme_debug_binary" --check-theme-parity
scripts/gen-builtin-themes.sh --check
printf 'PASS generated themes current\n'
theme_binary=$(swift build -c release --show-bin-path "$@")/Winstripe
"$theme_binary" --win8-anim-selftest
"$theme_binary" --win8-edit-snapshot /tmp/winstripe-win8-edit-check
python3 - "$theme_binary" "$theme_debug_binary" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

binary = sys.argv[1]
debug_binary = sys.argv[2]
failures = []
default_user_dir = pathlib.Path(tempfile.mkdtemp(prefix="winstripe-check-themes-"))
def run(*args):
    command = list(args)
    if "--user-themes-dir" not in command:
        command += ["--user-themes-dir", str(default_user_dir)]
    return subprocess.run([binary, *command], capture_output=True, text=True)
def check(name, action):
    try:
        action()
        print("PASS " + name)
    except Exception as error:
        failures.append(name)
        print("FAIL " + name + ": " + str(error))
def require(condition, message):
    if not condition:
        raise AssertionError(message)
def at(value, path):
    for part in path.split("."):
        value = value[part]
    return value
def no_comments(value):
    if isinstance(value, dict):
        require(not any(k.startswith("_") for k in value), "comment leaked into dump")
        for v in value.values(): no_comments(v)
    elif isinstance(value, list):
        for v in value: no_comments(v)
def builtins():
    result = run("--validate-theme", "builtin")
    require(result.returncode == 0 and not result.stderr, result.stderr)
    require(len(result.stdout.splitlines()) == 10, result.stdout)
check("validate all built-ins", builtins)
builtin_values = {
    "win98": {"startMenu.default": "classic98"},
    "winme": {"startMenu.default": "classicME", "startMenu.banner.suffix": "ME"},
    "win2000": {"startMenu.default": "classic2000", "startMenu.banner.suffix": "2000"},
    "winxp": {"startMenu.default": "xp", "previews.style": "classicTitleList"},
    "vista": {"metrics.barThickness": 40, "startMenu.default": "vista", "previews.style": "aeroGlass",
              "startButton.overflow.outer": 6, "startButton.overflow.panelMargin": 3},
    "win7": {"metrics.barThickness": 40, "startMenu.default": "win7", "previews.style": "aeroGlass",
             "startButton.overflow.outer": 0},
    "win8": {"metrics.barThickness": 40, "startMenu.default": "win8", "previews.style": "flatDark",
             "bar.material.type": "solid", "bar.material.color": "setting:win8StartColor", "bar.material.alpha": 0.78},
    "win10": {"metrics.barThickness": 40, "startMenu.default": "win10", "previews.style": "flatDark"},
}
for id in ["win95", "win98", "winme", "win2000", "winxp", "vista", "win7", "win8", "win10", "win11"]:
    def dump(id=id):
        result = run("--dump-theme", id)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        data = json.loads(result.stdout)
        require(data["id"] == id, "noncanonical id")
        no_comments(data)
        for path, expected in builtin_values.get(id, {}).items():
            require(at(data, path) == expected, f"{path}: {at(data, path)!r} != {expected!r}")
    check("dump " + id, dump)

def merge_dict(base, child):
    result = dict(base)
    for key, value in child.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = merge_dict(result[key], value)
        else:
            result[key] = value
    return result

def builtin_file(id):
    return {"win95": "95", "win98": "98", "winxp": "xp", "win7": "7",
            "win8": "8", "win10": "10", "win11": "11"}.get(id, id)

def old_builtin(id):
    raw = None
    for stem in [builtin_file(id), id]:
        present = subprocess.run(["git", "cat-file", "-e", f"HEAD:Themes/{stem}.json"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if present:
            raw = json.loads(subprocess.check_output(["git", "show", f"HEAD:Themes/{stem}.json"], text=True))
            break
    if raw is None:
        raise RuntimeError(f"missing built-in theme {id}")
    parent = raw.get("extends")
    if parent and parent in ["win95", "win98", "winxp", "vista", "win7", "win8", "win10", "win11"]:
        return merge_dict(old_builtin(parent), raw)
    return raw

def resolve_color(value, palette):
    if value == "#00000000":
        return "system:clear"
    if value == "#000000":
        return "system:black"
    if value == "#FFFFFF":
        return "system:white"
    if isinstance(value, str) and value.startswith("@"):
        return resolve_color(palette[value[1:]], palette)
    if isinstance(value, dict):
        if set(value) == {"color"}:
            return resolve_color(value["color"], palette)
        return {key: resolve_color(item, palette) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve_color(item, palette) for item in value]
    return value

def first_edge(data):
    for lines in (data.get("bar", {}).get("edge", {}) or {}).values():
        if lines:
            return lines[0].get("color")
    return None

def natural_values(data):
    palette = data.get("palette", {})
    material = data.get("bar", {}).get("material", {})
    task = data.get("buttons", {}).get("task", {})
    normal_state = task.get("normal", {}) or {}
    active_state = task.get("active", {}) or {}
    normal = normal_state.get("fill", {}) or {}
    active = active_state.get("fill", {}) or {}
    tray = data.get("tray", {})
    tray_fill = (tray.get("container", {}).get("fill", {}) or {})
    input_fill = (tray.get("inputLanguage", {}) or {}).get("fill")
    if input_fill == "system:clear":
        input_fill = palette.get("inputBadge")
    if "taskbarFill" in material:
        bar_fill = material["taskbarFill"]
    elif material.get("type") == "gradient":
        bar_fill = material.get("stops", [])
    elif material.get("type") in ("solid", "aeroGlass"):
        bar_fill = [material.get("color", material.get("tint"))]
    else:
        bar_fill = []
    if "taskbarFill" in tray_fill:
        tray_colors = tray_fill["taskbarFill"]
    elif tray_fill.get("type") == "gradient":
        tray_colors = tray_fill.get("stops", [])
    else:
        tray_colors = []
    edge_line = first_edge(data)
    if material.get("type") == "gradient" and edge_line is not None:
        bar_edge = edge_line
    elif material.get("variant") == "vista" and data.get("bar", {}).get("edgeColor") is not None:
        bar_edge = data["bar"]["edgeColor"]
    elif material.get("type") == "aeroGlass" and material.get("params", {}).get("edgeInnerColor") is not None:
        bar_edge = material["params"]["edgeInnerColor"]
    else:
        bar_edge = data.get("bar", {}).get("edgeColor") or edge_line or material.get("params", {}).get("edgeInnerColor") or "system:clear"
    return {
        "classic": data.get("family") == "classic",
        "face": palette.get("face"), "highlight": palette.get("highlight"),
        "light": palette.get("light"), "shadow": palette.get("shadow"),
        "darkShadow": palette.get("darkShadow"), "barFill": bar_fill,
        "barEdge": bar_edge,
        "buttonFill": task.get("normalFill", normal.get("stops", [])),
        "activeButtonFill": task.get("activeFill", active.get("stops", [])),
        "buttonBorder": task.get("borderColor", normal_state.get("border", {}).get("color", "system:clear")),
        "buttonText": task.get("textColor", (task.get("title", {}) or {}).get("color", palette.get("text"))),
        "startFill": data.get("startButton", {}).get("fill", (data.get("startButton", {}).get("drawerParams", {}) or {}).get("gradient", [])),
        "startText": data.get("startButton", {}).get("textColor", (data.get("startButton", {}).get("label", {}) or {}).get("color", palette.get("text"))),
        "trayFill": tray_colors,
        "trayBorder": tray.get("container", {}).get("leadingBorder") or "system:clear",
        "trayText": tray.get("textColor", (tray.get("clock", {}) or {}).get("color", palette.get("text"))),
        "inputBadge": input_fill,
        "cornerRadius": data.get("metrics", {}).get("cornerRadius", 0),
    }

def dump_mapping_parity():
    for id in ["win95", "win98", "winxp", "vista", "win7", "win8", "win10", "win11"]:
        old = old_builtin(id)
        old_values = old.get("legacyTheme", {})
        old_menu = old.get("legacyMenu", {})
        current = json.loads(run("--dump-theme", id).stdout)
        actual = natural_values(current)
        for key, expected in old_values.items():
            if key == "classic":
                require(actual[key] == (current.get("family") == "classic"), f"{id}.{key}: {actual[key]!r} != family")
            else:
                left = resolve_color(actual.get(key), current.get("palette", {}))
                right = resolve_color(expected, old.get("palette", {}))
                require(left == right, f"{id}.{key}: {left!r} != {right!r}")
        if old_menu:
            require(resolve_color(current["startMenu"]["colors"], current["palette"]) == {
                "face": resolve_color(old_menu["menuFace"], old["palette"]),
                "text": resolve_color(old_menu["menuText"], old["palette"]),
                "highlight": resolve_color(old_menu["menuHighlight"], old["palette"])}, f"{id} menu colors changed")
            require(resolve_color(current["startMenu"]["banner"], current["palette"]) == {
                "fill": resolve_color(old_menu["bannerFill"], old["palette"]),
                "text": resolve_color(old_menu["bannerText"], old["palette"]),
                "suffix": old_menu["bannerSuffix"]}, f"{id} banner changed")
check("dump resolved natural color mapping", dump_mapping_parity)
fixtures = pathlib.Path("Tests/fixtures")
for case in json.loads((fixtures / "expectations.json").read_text()):
    def fixture(case=case):
        path = str(fixtures / case["file"])
        validation = run("--validate-theme", path)
        require(validation.returncode == case["exit"], validation.stderr)
        if "stderr" in case:
            require(case["stderr"] in validation.stderr, validation.stderr)
        else:
            require(not validation.stderr, validation.stderr)
        require("_silent" not in validation.stderr, "comment warned")
        dumped = run("--dump-theme", path)
        require(dumped.returncode == case["exit"], dumped.stderr)
        data = json.loads(dumped.stdout)
        no_comments(data)
        for path, expected in case.get("values", {}).items():
            require(at(data, path) == expected, f"{path}: {at(data, path)!r} != {expected!r}")
        for path in case.get("absent", []):
            try: at(data, path)
            except KeyError: continue
            raise AssertionError("unknown key retained: " + path)
        strict = run("--validate-theme", str(fixtures / case["file"]), "--strict")
        expected = 1 if validation.stderr else case["exit"]
        require(strict.returncode == expected, "strict exit mismatch: " + strict.stderr)
    check(case["file"], fixture)
def folder():
    with tempfile.TemporaryDirectory(suffix=".rdtheme") as temp:
        pathlib.Path(temp, "theme.json").write_text((fixtures / "user-extends-builtin.json").read_text())
        result = run("--validate-theme", temp)
        require(result.returncode == 0 and not result.stderr, result.stderr)
check("rdtheme folder", folder)
def unknown_id():
    require(run("--dump-theme", "unknown-theme-id").returncode == 1, "unknown id accepted")
check("unknown dump id", unknown_id)
def missing_argument():
    require(run("--validate-theme").returncode == 1, "missing argument accepted")
check("missing CLI argument", missing_argument)
def canonical_alias():
    result = run("--dump-theme", "winXP")
    require(result.returncode == 0 and json.loads(result.stdout)["id"] == "winxp", result.stderr)
check("canonical XP alias", canonical_alias)
def debug_directory():
    with tempfile.TemporaryDirectory() as temp:
        override = {
            "$schema": "winstripe-theme/1", "id": "win98", "version": 1,
            "family": "classic", "extends": "win95",
            "metrics": {"buttonHeight": 25}, "startMenu": {"default": "classic98"},
        }
        pathlib.Path(temp, "win98.json").write_text(json.dumps(override))
        result = subprocess.run(
            [debug_binary, "--dump-theme", "win98", "--theme-dir", temp,
             "--user-themes-dir", str(default_user_dir)],
            capture_output=True, text=True)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        data = json.loads(result.stdout)
        require(data["metrics"]["buttonHeight"] == 25, "debug override ignored")
        require(data["metrics"]["barThickness"] == 30, "compiled parent fallback failed")
        result = subprocess.run(
            [debug_binary, "--validate-theme", "builtin", "--theme-dir", temp,
             "--user-themes-dir", str(default_user_dir)],
            capture_output=True, text=True)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        require(len(result.stdout.splitlines()) == 10, result.stdout)
        result = run("--dump-theme", "win98", "--theme-dir", temp)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        require(json.loads(result.stdout)["metrics"]["buttonHeight"] == 22,
                "release read debug directory")
check("debug directory override, inheritance, missing files, release isolation", debug_directory)
def image_drawer():
    import struct
    import zlib
    def png(path):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        path.write_bytes(b'\x89PNG\r\n\x1a\n'
                         + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
                         + chunk(b'IDAT', zlib.compress(b'\x00\x32\xb4\xf5\xff'))
                         + chunk(b'IEND', b''))
    with tempfile.TemporaryDirectory(suffix='.rdtheme') as temp:
        directory = pathlib.Path(temp)
        (directory / 'assets').mkdir()
        png(directory / 'assets/start.png')
        png(directory / 'assets/hover.png')
        theme = {
            '$schema': 'winstripe-theme/1', 'id': 'image-test', 'version': 1,
            'family': 'modern', 'extends': 'win7',
            'startButton': {'drawer': 'image', 'drawerParams': {
                'file': 'assets/start.png', 'width': 18, 'height': 20, 'fit': 'contain',
                'states': {'normal': 'assets/start.png', 'hover': 'assets/hover.png'}}},
        }
        path = directory / 'theme.json'
        def write(): path.write_text(json.dumps(theme))
        write()
        result = run('--validate-theme', temp, '--strict')
        require(result.returncode == 0 and not result.stderr, result.stderr)
        result = run('--dump-theme', temp)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        start = json.loads(result.stdout)['startButton']
        require(start['drawer'] == 'image', 'valid image fell back')
        require(start['drawerParams']['states']['hover'] == 'assets/hover.png', 'hover file lost')
        require(start['drawerParams']['fit'] == 'contain', 'image fit lost')
        # Override a built-in id through --theme-dir; asset paths belong to that folder.
        override = dict(theme, id='win7', extends='win11')
        (directory / 'win7.json').write_text(json.dumps(override))
        result = subprocess.run([debug_binary, '--validate-theme', 'builtin', '--theme-dir', temp,
                                 '--user-themes-dir', str(default_user_dir)],
                                capture_output=True, text=True)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        result = subprocess.run([debug_binary, '--dump-theme', 'win7', '--theme-dir', temp,
                                 '--user-themes-dir', str(default_user_dir)],
                                capture_output=True, text=True)
        require(result.returncode == 0 and not result.stderr, result.stderr)
        require(json.loads(result.stdout)['startButton']['drawer'] == 'image', 'debug image path fell back')
        # An inherited image belongs to the parent's folder; a child may override one state locally.
        child = directory / 'child'
        child.mkdir()
        png(child / 'pressed.png')
        (child / 'theme.json').write_text(json.dumps({
            '$schema': 'winstripe-theme/1', 'id': 'image-child', 'version': 1,
            'family': 'modern', 'extends': '../theme.json',
            'startButton': {'drawerParams': {'states': {'pressed': 'pressed.png'}}},
        }))
        result = run('--validate-theme', str(child), '--strict')
        require(result.returncode == 0 and not result.stderr, result.stderr)
        # A minimal vector PDF tests the same asset decoder without external tools.
        objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
                   b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                   b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 4 0 R >>',
                   b'<< /Length 0 >>\nstream\n\nendstream']
        pdf = bytearray(b'%PDF-1.4\n')
        offsets = [0]
        for i, obj in enumerate(objects, 1):
            offsets.append(len(pdf))
            pdf.extend(f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n')
        xref = len(pdf)
        pdf.extend(b'xref\n0 5\n0000000000 65535 f \n')
        for offset in offsets[1:]: pdf.extend(f'{offset:010d} 00000 n \n'.encode())
        pdf.extend(f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
        (directory / 'assets/start.pdf').write_bytes(pdf)
        pdf_theme = dict(theme, startButton={'drawer': 'image', 'drawerParams': {
            'file': 'assets/start.pdf', 'size': 20, 'fit': 'cover'}})
        path.write_text(json.dumps(pdf_theme))
        result = run('--validate-theme', temp, '--strict')
        require(result.returncode == 0 and not result.stderr, result.stderr)
        write()
        # Missing per-state assets warn, then use normal without discarding the image drawer.
        params = theme['startButton']['drawerParams']
        params['states']['pressed'] = 'assets/missing.png'
        write()
        result = run('--validate-theme', temp)
        require(result.returncode == 0 and 'warning: $.startButton.drawerParams.states.pressed' in result.stderr,
                result.stderr)
        result = run('--dump-theme', temp)
        start = json.loads(result.stdout)['startButton']
        require(start['drawer'] == 'image' and 'pressed' not in start['drawerParams']['states'], result.stderr)
        require(run('--validate-theme', temp, '--strict').returncode == 1, 'strict missing-state check passed')
        params.pop('states')
        # Missing and undecodable normal images use the modern family drawer without crashing.
        (directory / 'assets/corrupt.png').write_bytes(b'not an image')
        for file in ['assets/missing.png', 'assets/corrupt.png', '../outside.png']:
            params['file'] = file
            write()
            result = run('--validate-theme', temp)
            require(result.returncode == 0 and 'image unavailable or forbidden' in result.stderr, result.stderr)
            require(run('--validate-theme', temp, '--strict').returncode == 1, 'strict missing-file check passed')
            result = run('--dump-theme', temp)
            require(result.returncode == 0 and json.loads(result.stdout)['startButton']['drawer'] == 'win11Logo',
                    'missing image did not use family fallback: ' + result.stderr)
check('image drawer PNG/PDF, states, inherited assets, debug directory, missing and corrupt files', image_drawer)

def import_checks():
    import io, struct, zlib, zipfile
    def png_bytes(width=1, height=1, size=None, dpi=None):
        raw = b''.join(b'\0' + bytes([0, 128, 220, 255]) * width for _ in range(height))
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
        data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
        if dpi is not None:
            pixels_per_meter = round(dpi / 0.0254)
            data += chunk(b'pHYs', struct.pack('>IIB', pixels_per_meter, pixels_per_meter, 1))
        data += chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
        return data if size is None else data + b'x' * size
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp); user = root / 'user'; user.mkdir()
        theme = json.loads((pathlib.Path('Themes/95.json')).read_text()); theme['id'] = 'import-good'; theme['name'] = {'en': 'Import Good'}
        src = root / 'good.json'; src.write_text(json.dumps(theme))
        result = subprocess.run([binary, '--import-theme', str(src), '--user-themes-dir', str(user)], capture_output=True, text=True)
        require(result.returncode == 0 and 'IMPORTED import-good' in result.stdout, result.stderr)
        result = subprocess.run([binary, '--import-theme', str(src), '--user-themes-dir', str(user)], capture_output=True, text=True)
        require(result.returncode == 0 and 'import-good-copy' in result.stdout, result.stderr)
        bad = root / 'bad.zip'
        with zipfile.ZipFile(bad, 'w') as z: z.writestr('theme.json', '{')
        require(subprocess.run([binary, '--import-theme', str(bad), '--user-themes-dir', str(user)]).returncode == 1, 'bad JSON zip accepted')
        for name in ['../escape', '/absolute']:
            traversal = root / (name.split('/')[-1] + '.rdtheme')
            with zipfile.ZipFile(traversal, 'w') as z: z.writestr(name + '/theme.json', '{}')
            require(subprocess.run([binary, '--import-theme', str(traversal), '--user-themes-dir', str(user)]).returncode == 1, 'unsafe archive accepted')
        px = root / 'px.rdtheme'; px.mkdir(); (px / 'theme.json').write_text(json.dumps(theme)); (px / 'assets').mkdir(); (px / 'assets/x.png').write_bytes(png_bytes(1025, 1))
        require(subprocess.run([binary, '--import-theme', str(px), '--user-themes-dir', str(user)]).returncode == 1, 'oversized image accepted')
        dpi_px = root / 'dpi-px.rdtheme'; dpi_px.mkdir(); (dpi_px / 'theme.json').write_text(json.dumps(theme)); (dpi_px / 'assets').mkdir(); (dpi_px / 'assets/x.png').write_bytes(png_bytes(2048, 2048, dpi=144))
        require(subprocess.run([binary, '--import-theme', str(dpi_px), '--user-themes-dir', str(user)]).returncode == 1, '2048 px image with 144 dpi metadata accepted')
        big = root / 'big.rdtheme'; big.mkdir(); (big / 'theme.json').write_text(json.dumps(theme)); (big / 'assets').mkdir(); (big / 'assets/x.png').write_bytes(png_bytes(1, 1, 4 * 1024 * 1024))
        require(subprocess.run([binary, '--import-theme', str(big), '--user-themes-dir', str(user)]).returncode == 1, 'oversized image bytes accepted')
        exported = root / 'export.rdtheme'
        require(subprocess.run([binary, '--export-theme', 'import-good', str(exported), '--user-themes-dir', str(user)]).returncode == 0 and exported.exists(), 'export failed')
        roundtrip = root / 'roundtrip'; roundtrip.mkdir()
        result = subprocess.run([binary, '--import-theme', str(exported), '--user-themes-dir', str(roundtrip)], capture_output=True, text=True)
        require(result.returncode == 0 and 'IMPORTED import-good' in result.stdout, result.stderr)
        require(subprocess.run([binary, '--dump-theme', 'import-good', '--user-themes-dir', str(roundtrip)], capture_output=True, text=True).returncode == 0, 'round-trip dump failed')
        require(subprocess.run([binary, '--validate-theme', str(px / 'theme.json'), '--user-themes-dir', str(user)]).returncode == 0, 'example JSON validation failed')
check('import validation, duplicate copy naming, and export', import_checks)

def examples():
    for path in ['docs/examples/win95-teal.rdtheme', 'docs/examples/win7-image-orb.rdtheme']:
        result = run('--validate-theme', path)
        require(result.returncode == 0 and not result.stderr, result.stderr)
check('example themes validate', examples)

def color_schema_migration():
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        current = {
            '$schema': 'winstripe-theme/1', 'id': 'new-colors', 'name': {'en': 'New colors'},
            'version': 1, 'family': 'classic', 'extends': 'win95',
            'startMenu': {'default': 'classic95',
                          'colors': {'face': '#102030', 'text': '#F0E0D0', 'highlight': '#304050'},
                          'banner': {'fill': ['#506070', '#708090'], 'text': '#A0B0C0', 'suffix': 'N'}},
        }
        new_path = root / 'new.json'; new_path.write_text(json.dumps(current))
        result = run('--validate-theme', str(new_path))
        require(result.returncode == 0 and not result.stderr, result.stderr)
        dumped = json.loads(run('--dump-theme', str(new_path)).stdout)
        require(dumped['startMenu']['colors'] == current['startMenu']['colors'], 'new menu colors changed')
        require(dumped['startMenu']['banner'] == current['startMenu']['banner'], 'new banner changed')

        old = {
            '$schema': 'winstripe-theme/1', 'id': 'migrated-colors', 'name': {'en': 'Migrated colors'},
            'version': 1, 'family': 'classic', 'extends': 'win95',
            'legacyTheme': {
                'classic': True, 'face': '#123456', 'highlight': '#FFFFFF', 'light': '#DFDFDF',
                'shadow': '#808080', 'darkShadow': '#000000', 'barFill': ['#123456'],
                'barEdge': '#00000000', 'buttonFill': [], 'activeButtonFill': [],
                'buttonBorder': '#00000000', 'buttonText': '#000000', 'startFill': [],
                'startText': '#000000', 'trayFill': [], 'trayBorder': '#00000000',
                'trayText': '#000000', 'cornerRadius': 0, 'inputBadge': '#654321'},
            'legacyMenu': {
                'menuFace': '#ABCDEF', 'menuText': '#112233', 'menuHighlight': '#445566',
                'bannerFill': ['#010203'], 'bannerText': '#AABBCC', 'bannerSuffix': 'M'},
            'startMenu': {'default': 'classic95'},
        }
        old_path = root / 'old.json'; old_path.write_text(json.dumps(old))
        result = run('--validate-theme', str(old_path))
        require(result.returncode == 0 and 'deprecated theme color blocks migrated' in result.stderr, result.stderr)
        dumped = json.loads(run('--dump-theme', str(old_path)).stdout)
        require(dumped['palette']['face'] == '#123456', 'palette face did not migrate')
        require(dumped['palette']['inputBadge'] == '#654321', 'badge value did not migrate')
        require(dumped['bar']['edgeColor'] == '#00000000', 'bar edge did not migrate')
        require(dumped['buttons']['task']['normalFill'] == [], 'normal button fill did not migrate')
        require(dumped['buttons']['task']['activeFill'] == [], 'active button fill did not migrate')
        require(dumped['buttons']['task']['borderColor'] == '#00000000', 'button border did not migrate')
        require(dumped['buttons']['task']['textColor'] == '#000000', 'button text did not migrate')
        require(dumped['startButton']['fill'] == [], 'start fill did not migrate')
        require(dumped['startButton']['textColor'] == '#000000', 'start text did not migrate')
        require(dumped['tray']['container']['leadingBorder'] == '#00000000', 'tray border did not migrate')
        require(dumped['tray']['textColor'] == '#000000', 'tray text did not migrate')
        require(dumped['startMenu']['colors'] == {'face': '#ABCDEF', 'text': '#112233', 'highlight': '#445566'}, 'menu values did not migrate')
        require(dumped['startMenu']['banner'] == {'fill': ['#010203'], 'text': '#AABBCC', 'suffix': 'M'}, 'banner values did not migrate')
check('new color fields and deprecated block migration', color_schema_migration)

def hot_reload_headless():
    with tempfile.TemporaryDirectory() as temp:
        folder = pathlib.Path(temp) / 'hot.rdtheme'; folder.mkdir()
        data = json.loads((pathlib.Path('Themes/95.json')).read_text()); data['id'] = 'hot-test'; folder.joinpath('theme.json').write_text(json.dumps(data))
        proc = subprocess.Popen([binary, '--hot-reload-test', temp], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        import time
        time.sleep(0.25)
        data['bar']['material'] = {'type': 'gradient', 'stops': [{'color': '#008080'}, {'color': '#004040'}]}
        folder.joinpath('theme.json').write_text(json.dumps(data))
        time.sleep(0.35)
        folder.joinpath('theme.json').write_text('{')
        stdout, stderr = proc.communicate(timeout=3)
        require(proc.returncode == 0 and 'resolved=solid' in stdout and 'reloaded=gradient' in stdout and 'warning=' in stdout, stdout + stderr)
check('headless hot reload core', hot_reload_headless)

def debug_directory_argument():
    result = subprocess.run(
        [debug_binary, "--dump-theme", "win95", "--theme-dir"],
        capture_output=True, text=True)
    require(result.returncode == 1 and "--theme-dir requires a directory" in result.stderr,
            result.stderr)
check("missing debug directory argument", debug_directory_argument)
print(f"{'FAIL' if failures else 'PASS'} theme checks ({len(failures)} failures)")
sys.exit(bool(failures))
PY
