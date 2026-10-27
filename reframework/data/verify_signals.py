import json

signals_path = 'c:/Users/Motoka/RE9-LHandIKForceEnable/ShapeKeySystem/reframework/data/ShapeKeySystem/builtin/re9/signals.json'
with open(signals_path, 'r', encoding='utf-8') as f:
    signals_data = json.load(f)

valid_signals = set(s['name'] for s in signals_data.get('signals', []))

print("Valid signals count:", len(valid_signals))

# Check specific signals:
check_keys = [
    'stretch.L', 'stretch.R', 'smile.L', 'smile.R', 'frown.L', 'frown.R',
    'upperLipUp.L', 'upperLipUp.R', 'lowerLipDown.L', 'lowerLipDown.R',
    'funnel.L', 'funnel.R', 'funnelTogether.L', 'funnelTogether.R',
    'jawOpen', 'JwOpn_00_L', 'JwOpn_00_R', 'Pkr_01_L', 'Pkr_01_R',
    'Pkr_03_L', 'Pkr_03_R', 'LpPush_00_L', 'LpPush_00_R', 'LpRolIn_04_L',
    'LpRolIn_04_R', 'CrnDprs_00_L', 'CrnDprs_00_R', 'CrnDprs_02_L',
    'CrnDprs_02_R', 'UprLpRs_01_L', 'UprLpRs_01_R', 'UprLpRs_05_L',
    'UprLpRs_05_R', 'Strtch_04_L', 'Strtch_04_R', 'CrnPl_04_L', 'CrnPl_04_R',
    'LwrLpDprs_00_L', 'LwrLpDprs_00_R'
]

for k in check_keys:
    if k not in valid_signals:
        print("INVALID:", k)
    else:
        print("VALID:", k)
