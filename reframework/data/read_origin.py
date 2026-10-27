import json

with open(r'F:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\reframework\data\ShapeKeySystem\Origin.json', 'r', encoding='utf-8') as f:
    origin = json.load(f)

print("Origin.json summary:")
for k in origin.keys():
    print(" -", k, type(origin[k]))

if "facs_channels" in origin:
    print("\nFACS channels in Origin.json with peak > 0.01:")
    for ch in origin["facs_channels"]:
        if ch.get("peak_max", 0) > 0.01 or ch.get("span", 0) > 0.01:
            print(f"  {ch['name']:30s}: peak={ch.get('peak_max'):.4f}, span={ch.get('span'):.4f}")

if "active_channels" in origin:
    print("\nActive channels in Origin.json:")
    for ch, val in origin["active_channels"].items():
        print(f"  {ch:30s}: {val}")
