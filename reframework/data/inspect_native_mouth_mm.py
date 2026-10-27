import socket
import json

def run_blender_code(code_str):
    s = socket.socket()
    s.connect(('localhost', 9876))
    req = {'type': 'execute', 'code': code_str, 'strict_json': True}
    s.sendall(json.dumps(req).encode('utf-8') + b'\0')
    
    buf = b''
    while b'\0' not in buf:
        chunk = s.recv(8192)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.rstrip(b'\0').decode('utf-8'))

res = run_blender_code("""
import bpy

obj = bpy.data.objects.get("Group_0_Sub_0__Face_Mat")
basis = obj.data.shape_keys.key_blocks.get("Basis")

keys = [
    'HeadSkinned_blendShape.JwOpn_00_L',
    'HeadSkinned_blendShape.JwOpn_00_R',
    'HeadSkinned_blendShape.CrnPl_JwOpn_L',
    'HeadSkinned_blendShape.CrnPl_JwOpn_R',
    'HeadSkinned_blendShape.Strtch_JwOpn_L',
    'HeadSkinned_blendShape.Strtch_JwOpn_R',
    'HeadSkinned_blendShape.CrnPl_LwrLpDprs_L',
    'HeadSkinned_blendShape.CrnPl_LwrLpDprs_R',
    'HeadSkinned_blendShape.UprLpRs_01_L',
    'HeadSkinned_blendShape.UprLpRs_01_R',
    'HeadSkinned_blendShape.UprLpRs_05_L',
    'HeadSkinned_blendShape.UprLpRs_05_R',
    'HeadSkinned_blendShape.Fnl_04_L',
    'HeadSkinned_blendShape.Fnl_04_R',
    'HeadSkinned_blendShape.Pkr_01_L',
    'HeadSkinned_blendShape.Pkr_01_R',
    'HeadSkinned_blendShape.CrnPl_01_L',
    'HeadSkinned_blendShape.CrnPl_01_R',
    'HeadSkinned_blendShape.CrnPl_04_L',
    'HeadSkinned_blendShape.CrnPl_04_R',
]

details = {}
for k in keys:
    kb = obj.data.shape_keys.key_blocks.get(k)
    if not kb: continue
    
    max_down_val = 0
    max_up_val = 0
    max_d = 0
    
    for i in range(len(obj.data.vertices)):
        delta = kb.data[i].co - basis.data[i].co
        d = delta.length
        if d > max_d: max_d = d
        dz = delta.z
        if dz < max_down_val: max_down_val = dz
        if dz > max_up_val: max_up_val = dz
            
    details[k.replace('HeadSkinned_blendShape.', '')] = {
        'max_dist_mm': round(max_d * 1000, 2),
        'max_down_dz': round(max_down_val * 1000, 2), # in mm
        'max_up_dz': round(max_up_val * 1000, 2),     # in mm
        'total_opening_mm': round((max_up_val - max_down_val) * 1000, 2)
    }

result = details
""")

data = res.get('result', {})
print("Native Leon ShapeKey Measurements:")
for k, v in data.items():
    print(f"Key: {k:22s} | MaxDist: {v['max_dist_mm']:5.2f} mm | Down: {v['max_down_dz']:6.2f} mm | Up: +{v['max_up_dz']:5.2f} mm | Total: {v['total_opening_mm']:5.2f} mm")
