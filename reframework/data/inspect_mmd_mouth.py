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
import mathutils

obj = bpy.data.objects.get("Group_0_Sub_2__Face_Mat")
basis = obj.data.shape_keys.key_blocks.get("Basis")

# Find mouth vertices on Basis
# In this model, mouth center is around Y ~ -0.07, Z ~ 1.279
mouth_sks = [
    'あ', 'あ２', 'あ3', 'あ4', 'あ5', 'あ6', 'あ7', 'あ8', 'あ9', 'あ10',
    'ワ', 'ワ1', 'ワ2', 'い', 'い1', 'い2', 'う', 'う1', 'う2', 'え', 'お', 'お1',
    '▲', '□', '□1', '口上', '口下', '口角上げ', '口角下げ', '口横広げ', '口横缩げ'
]

results = {}
for sk_name in mouth_sks:
    kb = obj.data.shape_keys.key_blocks.get(sk_name)
    if not kb:
        continue
    
    # Calculate displacement stats
    max_d = 0.0
    vert_count = 0
    max_dz_down = 0.0 # how much lower lip moves DOWN (Z decrease)
    max_dz_up = 0.0   # how much upper lip moves UP (Z increase)
    max_dy_open = 0.0 # mouth opening
    
    for i in range(len(obj.data.vertices)):
        co_b = basis.data[i].co
        co_k = kb.data[i].co
        delta = co_k - co_b
        d = delta.length
        if d > 0.0005:
            vert_count += 1
            if d > max_d:
                max_d = d
            if delta.z < max_dz_down:
                max_dz_down = delta.z
            if delta.z > max_dz_up:
                max_dz_up = delta.z
                
    results[sk_name] = {
        'verts': vert_count,
        'max_d': round(max_d, 5),
        'max_down_z': round(max_dz_down, 5), # lower lip downward opening
        'max_up_z': round(max_dz_up, 5),     # upper lip upward opening
    }

result = results
""")

data = res.get('result', {})
print(f"{'ShapeKey':12s} | {'Verts':5s} | {'MaxDist':8s} | {'MaxDown(LowerLip)':17s} | {'MaxUp(UpperLip)':17s}")
print("-" * 70)
for k, v in data.items():
    print(f"{k:12s} | {v['verts']:5d} | {v['max_d']:8.4f} | {v['max_down_z']:17.4f} | {v['max_up_z']:17.4f}")
