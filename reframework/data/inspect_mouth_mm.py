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

obj = bpy.data.objects.get("Group_0_Sub_2__Face_Mat")
basis = obj.data.shape_keys.key_blocks.get("Basis")

# Let's inspect where vertices move for:
# 'あ', 'あ２', 'ワ', 'ワ1', 'え', 'お'
keys = ['あ', 'あ２', 'ワ', 'ワ1', 'え', 'お', '口上', '口下']
details = {}
for k in keys:
    kb = obj.data.shape_keys.key_blocks.get(k)
    if not kb: continue
    
    # Let's find the vertex with the maximum downward displacement (bottom of lower lip)
    # and the vertex with maximum upward displacement (top of upper lip)
    max_down_idx = -1
    max_down_val = 0
    max_up_idx = -1
    max_up_val = 0
    
    for i in range(len(obj.data.vertices)):
        dz = kb.data[i].co.z - basis.data[i].co.z
        if dz < max_down_val:
            max_down_val = dz
            max_down_idx = i
        if dz > max_up_val:
            max_up_val = dz
            max_up_idx = i
            
    details[k] = {
        'max_down_dz': round(max_down_val * 1000, 2), # in mm
        'max_up_dz': round(max_up_val * 1000, 2),     # in mm
        'total_opening_mm': round((max_up_val - max_down_val) * 1000, 2),
        'lower_lip_vidx': max_down_idx,
        'upper_lip_vidx': max_up_idx
    }

result = details
""")

data = res.get('result', {})
print("Mouth Opening Measurements on MMD Face:")
for k, v in data.items():
    print(f"Key: {k:8s} | Lower Lip: {v['max_down_dz']:6.2f} mm | Upper Lip: +{v['max_up_dz']:5.2f} mm | Total Opening: {v['total_opening_mm']:5.2f} mm")
