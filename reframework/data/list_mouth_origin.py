import json

origin = json.load(open(r'F:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\reframework\data\ShapeKeySystem\Origin.json', 'r', encoding='utf-8'))

mouth_channels = []
for ch in origin.get('facs_channels', []):
    name = ch.get('name', '')
    # Check if mouth, lip, jaw, chin, crn, pkr, fnl, etc.
    if any(k in name.lower() for k in ['jw', 'lip', 'lp', 'crn', 'chn', 'mou', 'pkr', 'fnl', 'nek', 'str']):
        mouth_channels.append(ch)

print(f"Total mouth channels in Origin.json: {len(mouth_channels)}")
print(f"{'Channel Name':25s} | {'Peak':7s} | {'Span':7s} | {'Avg':7s} | {'BaseMin':7s} | {'Description'}")
print("-" * 80)
for ch in mouth_channels:
    print(f"{ch['name']:25s} | {ch['peak_max']:7.4f} | {ch['span']:7.4f} | {ch['average']:7.4f} | {ch['baseline_min']:7.4f} | {ch.get('description', '')}")
