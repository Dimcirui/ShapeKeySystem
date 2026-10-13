"""Measure every shape key on each avatar's "Body" (face) mesh. Run inside Blender
(Text editor > Run Script, or through the Blender MCP). Each FBX is imported into a temporary
scene that is deleted afterwards, so the open scene is left alone.

Writes probe/<tag>.json next to this file:
  keys[name] = [moved verts, max disp, centroid x y z, mean disp x y z, +x share,
                inner mean dz, inner mean outward dx, outer mean dz, outer mean outward dx]
  (world space after the FBX importer's axis conversion: +X = character's left, -Y = front, +Z = up;
   inner / outer = moved verts nearer / farther from the face midline than their median)
"""
import bpy, glob, json, os, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else \
    r"E:\Data\Github\ShapeKeySystem\tools\vrc_profiles"
OUT = os.path.join(HERE, "probe")
VRC = r"E:\Data\2-模型\VRC" + "\\"
EXT = os.path.join(HERE, "ext") + "\\"   # base FBXs pulled out of archives, see README.md

AVATARS = {
    "airi": VRC + r"0Airi\Airi Ver1.01\Airi.fbx",
    "chocolat": VRC + r"0Chocolat\Chocolat_v1.02\FBX\Chocolat.fbx",
    "kaguya": VRC + r"0Kaguya\Kaguya\FBX\Body\kaguya.fbx",
    "lime": VRC + r"0Lime\0Lime\Lime_v1.00\FBX\Lime_ver1.0.0.fbx",
    "mafuyu": VRC + r"0Mafuyu\Mafuyu_v1.0.2\FBX\Mafuyu.fbx",
    "maya": VRC + r"0Maya\kyubihome_Maya_Maya(V1.0)_3390957\Maya.fbx",
    "milltina": VRC + r"0Milltina\Milltina*_ver1.01.1\FBX\Milltina.fbx",
    "shinano": VRC + r"0Shinano\0Shinano_ver1.02\FBX\Shinano.fbx",
    "moko": VRC + r"1\Assets\Moko\Fbx\Moko.fbx",
    "kumaly": VRC + r"KUMALY_ver1.02\KUMALY.fbx",
    "sairou": VRC + r"sairou\Assets\sairou\fbx\sairou.fbx",
    "karin": EXT + r"karin\Karin_ver1.00.fbx",
    "kipfel": EXT + r"kipfel\Kipfel.fbx",
    "manuka": EXT + r"manuka\MANUKA.fbx",
    "nitco": EXT + r"nitco\nitco.fbx",
    "plum": EXT + r"plum\Plum.fbx",
    "rindo": EXT + r"rindo\RINDO.fbx",
    "selestia": EXT + r"selestia\SELESTIA.fbx",
}


def probe(tag, path):
    t0 = time.time()
    orig = bpy.context.window.scene
    sc = bpy.data.scenes.new("SKS_probe")
    bpy.context.window.scene = sc
    before = set(bpy.data.objects)
    try:
        bpy.ops.import_scene.fbx(filepath=path)
        new = [o for o in bpy.data.objects if o not in before]
        o = [o for o in new if o.type == 'MESH' and o.name.split('.')[0] == 'Body' and o.data.shape_keys][0]
        me = o.data; n = len(me.vertices)
        M = np.array(o.matrix_world); R = M[:3, :3]
        kb = me.shape_keys.key_blocks
        base = np.empty(n * 3); kb[0].data.foreach_get("co", base); base = base.reshape(n, 3)
        bw = base @ R.T + M[:3, 3]
        out = {"verts": n, "keys": {}}
        tmp = np.empty(n * 3)
        for k in kb[1:]:
            k.data.foreach_get("co", tmp)
            d = (tmp.reshape(n, 3) - base) @ R.T
            m = np.linalg.norm(d, axis=1); mx = float(m.max())
            if mx < 1e-6:
                out["keys"][k.name] = [0]; continue
            sel = m > mx * 0.1
            w = m[sel]
            c = (bw[sel] * w[:, None]).sum(0) / w.sum()
            dv = d[sel].mean(0)
            px = float(m[bw[:, 0] > 0].sum() / m.sum())
            ax = np.abs(bw[sel, 0])
            inn = ax <= np.median(ax); outr = ~inn
            ds = d[sel]; sx = np.sign(bw[sel, 0]); sx[sx == 0] = 1
            def st(mask):
                if not mask.any(): return [0, 0]
                return [round(float(ds[mask, 2].mean()), 5), round(float((ds[mask, 0] * sx[mask]).mean()), 5)]
            out["keys"][k.name] = [int(sel.sum()), round(mx, 5)] + [round(float(x), 4) for x in c] + \
                [round(float(x), 5) for x in dv] + [round(px, 3)] + st(inn) + st(outr)
        out["bbox"] = [bw.min(0).round(4).tolist(), bw.max(0).round(4).tolist()]
        os.makedirs(OUT, exist_ok=True)
        json.dump(out, open(os.path.join(OUT, tag + ".json"), "w", encoding="utf-8"), ensure_ascii=False)
        return {"tag": tag, "keys": len(kb) - 1, "sec": round(time.time() - t0, 1)}
    finally:
        for ob in [o for o in bpy.data.objects if o not in before]:
            bpy.data.objects.remove(ob, do_unlink=True)
        bpy.context.window.scene = orig
        bpy.data.scenes.remove(sc)
        for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images, bpy.data.actions):
            for b in list(coll):
                if b.users == 0: coll.remove(b)


def run(tags=None):
    res = []
    for tag, pat in AVATARS.items():
        if tags and tag not in tags:
            continue
        hits = glob.glob(pat)
        if not hits:
            res.append({"tag": tag, "error": "missing " + pat}); continue
        try:
            res.append(probe(tag, hits[0]))
        except Exception as e:
            res.append({"tag": tag, "error": repr(e)[:200]})
    return res


result = run()
print(result)
