import json, os, re, shutil, sys, tempfile
import lupa.lua54 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
# the repo's reframework tree; SKS_REFRAMEWORK points the harness at another copy (e.g. the game's)
GAME = os.environ.get("SKS_REFRAMEWORK") or os.path.join(HERE, "..", "reframework")
data = tempfile.mkdtemp(prefix="sks_data_")
shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "builtin"), os.path.join(data, "ShapeKeySystem", "builtin"))
os.makedirs(os.path.join(data, "ShapeKeySystem", "user", "conditions"), exist_ok=True)
shutil.copy(os.path.join(HERE, "fixtures", "ShinanoOC.json"), os.path.join(data, "ShapeKeySystem", "user", "conditions"))
if os.path.isdir(os.path.join(GAME, "data", "ShapeKeySystem", "faces")):
    shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "faces"), os.path.join(data, "ShapeKeySystem", "faces"))
if "--legacy" in sys.argv:
    shutil.copy(os.path.join(GAME, "data", "ArkitFaceDriver.json"), data)

# one Lua runtime with the REFramework mock's file layer over data_dir (json / fs from Python)
def boot(data):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    G = L.globals()

    def to_lua(v):
        if isinstance(v, dict):
            t = L.table()
            for k, x in v.items(): t[k] = to_lua(x)
            return t
        if isinstance(v, list):
            t = L.table()
            for i, x in enumerate(v): t[i + 1] = to_lua(x)
            return t
        return v

    def to_py(v):
        if lupa.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
                return [to_py(v[k]) for k in sorted(keys)]
            return {str(k): to_py(v[k]) for k in keys}
        return v

    def load_file(p):
        fp = os.path.join(data, p)
        if not os.path.isfile(fp): return None
        with open(fp, encoding="utf-8") as f: return to_lua(json.load(f))

    def dump_file(p, t, indent=None):
        fp = os.path.join(data, p)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        with open(fp, "w", encoding="utf-8") as f: json.dump(to_py(t), f, ensure_ascii=False, indent=2)
        return True

    def load_string(s): return to_lua(json.loads(s))

    def glob(pattern, *_):
        out = L.table(); i = 1
        rx = re.compile(pattern)
        for d, _, files in os.walk(data):
            for fn in files:
                rel = os.path.relpath(os.path.join(d, fn), data)
                if rx.fullmatch(rel): out[i] = rel; i += 1
        return out

    # REF 的 io 相对路径属于数据目录；绝对源码路径供离线 loadfile/源码检查使用。
    G.test_io_path = lambda p: p if os.path.isabs(p) else os.path.join(data, p)
    L.execute('local native_open = io.open; io.open = function(path, mode) '
              'return native_open(test_io_path(path), mode) end')

    G.json = L.table_from({"load_file": load_file, "dump_file": dump_file, "load_string": load_string})
    G.fs = L.table_from({"glob": glob})
    G.package.path = os.path.join(GAME, "autorun", "?.lua").replace("\\", "/")
    G.ENTRY = os.path.join(GAME, "autorun", "ShapeKeySystem.lua").replace("\\", "/")

    def lua_files(sub):   # every .lua under autorun/<sub>
        out = L.table(); i = 1
        for d, _, files in os.walk(os.path.join(GAME, "autorun", sub)):
            for fn in sorted(files):
                if fn.endswith(".lua"): out[i] = os.path.join(d, fn).replace("\\", "/"); i += 1
        return out
    G.lua_files = lua_files
    return L, G, to_lua

if "--re4r-only" in sys.argv:
    L, G, _ = boot(data)
    L.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
    L.execute(open(os.path.join(HERE, "tests_re4r.lua"), encoding="utf-8").read())
    sys.exit(0)

L, G, to_lua = boot(data)
L.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
from render_ui import font as _pil_font
def py_measure(family, size, s):
    f = _pil_font(family, size)
    l, t, r, b = f.getbbox(s)
    return f.getlength(s), size * 1.33
G.py_measure = py_measure
L.execute('dofile("%s")' % os.path.join(GAME, "autorun", "ShapeKeySystem.lua").replace("\\", "/"))
# REFramework finds autorun modules only while scripts load: later requires of files fail
L.execute('package.searchers[2] = function(name) return "autorun module after load: " .. name end')
G.TESTS_DIR = HERE.replace("\\", "/")
L.execute(open(os.path.join(HERE, "tests.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_ui.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_api.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_cond.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_touch.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_target_lookup.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_bind.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_json.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_preview.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_shinano.lua"), encoding="utf-8").read())
G.MMD_NAMES = to_lua(json.load(open(os.path.join(HERE, "mmd_names.json"), encoding="utf-8")))
G.VRC_FACES = to_lua(json.load(open(os.path.join(HERE, "vrc_faces.json"), encoding="utf-8")))
L.execute(open(os.path.join(HERE, "tests_mmd.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_labels.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_playback_analysis.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_playback.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_playback_adapter.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_games.lua"), encoding="utf-8").read())
L.execute(open(os.path.join(HERE, "tests_procedural.lua"), encoding="utf-8").read())

# a second runtime with a minimal made-up adapter (no signals, hooks, conditions or input)
data2 = tempfile.mkdtemp(prefix="sks_fake_")
shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "builtin"), os.path.join(data2, "ShapeKeySystem", "builtin"))
L2, G2, _ = boot(data2)
L2.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
L2.execute(open(os.path.join(HERE, "tests_fake.lua"), encoding="utf-8").read())
# the real Onimusha adapter with a head mesh and boxed hashes in an indexed userdata container
data3 = tempfile.mkdtemp(prefix="sks_onimusha_")
shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "builtin"), os.path.join(data3, "ShapeKeySystem", "builtin"))
L3, G3, _ = boot(data3)
L3.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
L3.execute(open(os.path.join(HERE, "tests_onimusha.lua"), encoding="utf-8").read())
# the real Rise adapter: no raw channels, names from get_Item hashes, unfixed blendshape controllers
data5 = tempfile.mkdtemp(prefix="sks_rise_")
shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "builtin"), os.path.join(data5, "ShapeKeySystem", "builtin"))
L5, G5, _ = boot(data5)
L5.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
L5.execute(open(os.path.join(HERE, "tests_rise.lua"), encoding="utf-8").read())
data4 = tempfile.mkdtemp(prefix="sks_re4r_")
shutil.copytree(os.path.join(GAME, "data", "ShapeKeySystem", "builtin"), os.path.join(data4, "ShapeKeySystem", "builtin"))
L4, G4, _ = boot(data4)
L4.execute(open(os.path.join(HERE, "mock_sks.lua"), encoding="utf-8").read())
L4.execute(open(os.path.join(HERE, "tests_re4r.lua"), encoding="utf-8").read())
sys.path.insert(0, HERE)
from mm3ref import mm3
want = mm3("eyeBlinkLeft".encode("utf-16-le"))
print("murmur3 lua", G.MM3, "python", want, "ok" if G.MM3 == want else "FAIL")
print("data dir:", data)
for root, _, files in os.walk(os.path.join(data, "ShapeKeySystem", "user")):
    for fn in files: print("user file:", os.path.relpath(os.path.join(root, fn), data))

if "--shots" in sys.argv:
    from render_ui import render
    os.makedirs(os.path.join(HERE, "shots"), exist_ok=True)
    snaps = G.SNAPS
    for i in range(1, len(snaps) + 1):
        sn = snaps[i]
        cmds = []
        for j in range(1, len(sn.cmds) + 1):
            c = sn.cmds[j]
            cmds.append([c[k] for k in range(1, c.n + 1)])
        out = os.path.join(HERE, "shots", "page_%d.png" % i)
        render(cmds, out)
        print("shot", out, len(cmds))

if G.PREVIEW_CMDS:
    from render_ui import render
    pc = G.PREVIEW_CMDS
    cmds = []
    for j in range(1, len(pc) + 1):
        c = pc[j]
        cmds.append([c[k] for k in range(1, c.n + 1)])
    render(cmds, os.path.join(HERE, "preview_shot.png"))
