import json

mmd_path = 'c:/Users/Motoka/RE9-LHandIKForceEnable/ShapeKeySystem/reframework/data/ShapeKeySystem/builtin/profiles/mmd.json'
with open(mmd_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

for ch in data.get('channels', []):
    if ch.get('name') == 'あ':
        ch['max'] = [
            {
                "max": [
                    { "s": "JwOpn_00_L" },
                    { "s": "JwOpn_00_R" }
                ],
                "curve": {
                    "deadzone": 0.020,
                    "gain": 16.0
                }
            },
            {
                "s": "jawOpen",
                "curve": {
                    "deadzone": 0.030,
                    "gain": 3.2
                }
            }
        ]
        if 's' in ch: del ch['s']
    elif ch.get('name') == 'ワ':
        ch['max'] = [
            {
                "s": "JwOpn_00_L",
                "curve": {
                    "deadzone": 0.060,
                    "gain": 15.0
                }
            },
            {
                "s": "jawOpen",
                "curve": {
                    "deadzone": 0.35,
                    "gain": 2.5
                }
            }
        ]
        if 's' in ch: del ch['s']

with open(mmd_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

game_mmd_path = 'F:/SteamLibrary/steamapps/common/RESIDENT EVIL requiem BIOHAZARD requiem/reframework/data/ShapeKeySystem/builtin/profiles/mmd.json'
with open(game_mmd_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("Updated mmd.json in workspace and game dir!")
