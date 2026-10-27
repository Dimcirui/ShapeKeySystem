import json
import copy

profile_path = 'c:/Users/Motoka/RE9-LHandIKForceEnable/ShapeKeySystem/reframework/data/ShapeKeySystem/builtin/re9/profiles/re9_mmd.json'

with open(profile_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

# Define the upgraded mouth channels
new_mouth_channels = {
  "あ": {
    "name": "あ",
    "group": "mouth",
    "any": [
      "あ", "あ２", "あ2", "あ3", "あ4", "あ5", "あ6", "あ7", "あ8", "あ9", "あ10", "あ1", "ア"
    ],
    "note": "A元音：垂直自然张嘴（融合双下颌原生形态键与物理下巴骨骼，说话开口清晰自然饱满）",
    "max": [
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
  },
  "ワ": {
    "name": "ワ",
    "group": "mouth",
    "any": [
      "ワ", "ワ1", "ワ2", "大口"
    ],
    "note": "极限大张嘴/吼叫口型（日常说话不触发，仅在重度喊叫/大口喘息时触发）",
    "max": [
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
  },
  "い": {
    "name": "い",
    "group": "mouth",
    "any": [
      "い", "い1", "い2", "イ"
    ],
    "note": "I元音：嘴角横拉咧嘴露齿（融合嘴角横拉与微笑信号，说话发音I清晰）",
    "max": [
      {
        "sum": [
          { "s": "mouthStretchLeft", "k": 0.6 },
          { "s": "mouthStretchRight", "k": 0.6 }
        ]
      },
      {
        "sum": [
          { "s": "Strtch_04_L", "k": 15.0 },
          { "s": "Strtch_04_R", "k": 15.0 }
        ]
      },
      {
        "sum": [
          { "s": "mouthSmileLeft", "k": 0.4 },
          { "s": "mouthSmileRight", "k": 0.4 }
        ]
      }
    ]
  },
  "う": {
    "name": "う",
    "group": "mouth",
    "any": [
      "う", "う1", "う2", "ウ"
    ],
    "note": "U元音：嘴唇向前圆拢收聚（由嘟嘴Pkr与嘴唇前突LpPush驱动）",
    "max": [
      {
        "max": [
          { "s": "Pkr_01_L" },
          { "s": "Pkr_01_R" },
          { "s": "Pkr_03_L" },
          { "s": "Pkr_03_R" }
        ],
        "curve": {
          "deadzone": 0.025,
          "gain": 3.2
        }
      },
      {
        "max": [
          { "s": "LpPush_00_L" },
          { "s": "LpPush_00_R" }
        ],
        "curve": {
          "deadzone": 0.05,
          "gain": 0.8
        }
      },
      {
        "s": "mouthPucker",
        "k": 1.2
      }
    ]
  },
  "え": {
    "name": "え",
    "group": "mouth",
    "any": [
      "え", "え1", "え2", "え3", "エ"
    ],
    "note": "E元音：半开露齿微展（张嘴与横展结合）",
    "min": [
      {
        "max": [
          { "s": "JwOpn_00_L" },
          { "s": "JwOpn_00_R" }
        ],
        "curve": {
          "deadzone": 0.020,
          "gain": 12.0
        }
      },
      {
        "max": [
          {
            "sum": [
              { "s": "mouthStretchLeft", "k": 0.8 },
              { "s": "mouthStretchRight", "k": 0.8 }
            ]
          },
          {
            "sum": [
              { "s": "mouthSmileLeft", "k": 0.7 },
              { "s": "mouthSmileRight", "k": 0.7 }
            ]
          },
          {
            "const": 0.65
          }
        ]
      }
    ]
  },
  "お": {
    "name": "お",
    "group": "mouth",
    "any": [
      "お", "お1", "お2", "お3", "オ"
    ],
    "note": "O元音：圆管漏斗开度（张嘴伴随嘴唇收拢前突）",
    "min": [
      {
        "max": [
          { "s": "JwOpn_00_L" },
          { "s": "JwOpn_00_R" }
        ],
        "curve": {
          "deadzone": 0.020,
          "gain": 12.0
        }
      },
      {
        "max": [
          {
            "max": [
              { "s": "Pkr_01_L" },
              { "s": "Pkr_01_R" },
              { "s": "Pkr_03_L" },
              { "s": "Pkr_03_R" }
            ],
            "curve": {
              "deadzone": 0.02,
              "gain": 3.0
            }
          },
          {
            "max": [
              { "s": "LpRolIn_04_L" },
              { "s": "LpRolIn_04_R" }
            ],
            "curve": {
              "deadzone": 0.02,
              "gain": 2.5
            }
          },
          {
            "s": "mouthFunnel",
            "k": 1.5
          }
        ]
      }
    ]
  },
  "口横広げ": {
    "name": "口横広げ",
    "group": "mouth",
    "any": [
      "口横広げ", "口横広げる", "口横伸ばし"
    ],
    "note": "嘴唇纯横向展宽",
    "max": [
      {
        "sum": [
          { "s": "mouthStretchLeft", "k": 0.6 },
          { "s": "mouthStretchRight", "k": 0.6 }
        ]
      },
      {
        "sum": [
          { "s": "Strtch_04_L", "k": 15.0 },
          { "s": "Strtch_04_R", "k": 15.0 }
        ]
      }
    ],
    "unless": [
      "口横広げ左",
      "口横広げ右"
    ]
  },
  "口横狭く": {
    "name": "口横狭く",
    "group": "mouth",
    "any": [
      "口横缩げ", "口横狭く", "口横狭め"
    ],
    "note": "嘴唇横向收窄与前突",
    "max": [
      {
        "max": [
          { "s": "Pkr_03_L" },
          { "s": "Pkr_03_R" }
        ],
        "curve": {
          "deadzone": 0.02,
          "gain": 2.8
        }
      },
      {
        "max": [
          { "s": "LpPush_00_L" },
          { "s": "LpPush_00_R" }
        ],
        "curve": {
          "deadzone": 0.05,
          "gain": 0.8
        }
      }
    ],
    "unless": [
      "口横狭め左",
      "口横狭め右"
    ]
  },
  "口上": {
    "name": "口上",
    "group": "mouth",
    "any": [
      "口上", "上唇上げ"
    ],
    "note": "RE9 原生形态键：上唇抬起01/05",
    "max": [
      {
        "sum": [
          { "s": "UprLpRs_01_L", "k": 20.0 },
          { "s": "UprLpRs_01_R", "k": 20.0 }
        ]
      },
      {
        "sum": [
          { "s": "UprLpRs_05_L", "k": 20.0 },
          { "s": "UprLpRs_05_R", "k": 20.0 }
        ]
      },
      {
        "sum": [
          { "s": "mouthUpperUpLeft", "k": 0.8 },
          { "s": "mouthUpperUpRight", "k": 0.8 }
        ]
      }
    ]
  },
  "口下": {
    "name": "口下",
    "group": "mouth",
    "any": [
      "口下", "下唇下げ"
    ],
    "note": "RE9 原生形态键：下唇下拉",
    "max": [
      {
        "sum": [
          { "s": "mouthLowerDownLeft", "k": 0.8 },
          { "s": "mouthLowerDownRight", "k": 0.8 }
        ]
      },
      {
        "max": [
          { "s": "LwrLpDprs_00_L" },
          { "s": "LwrLpDprs_00_R" }
        ],
        "k": 10.0
      }
    ]
  },
  "にやり２": {
    "name": "にやり２",
    "group": "mouth",
    "max": [
      { "s": "CrnPl_04_L", "k": 3.0 },
      { "s": "mouthSmileLeft", "k": 1.0 }
    ],
    "any": [
      "にやり２", "にやり２左", "にやり左", "口角上左", "左口角上げ"
    ],
    "note": "RE9 原生形态键：左嘴角上翘"
  },
  "にやり２1": {
    "name": "にやり２1",
    "group": "mouth",
    "max": [
      { "s": "CrnPl_04_R", "k": 3.0 },
      { "s": "mouthSmileRight", "k": 1.0 }
    ],
    "any": [
      "にやり２1", "にやり２右", "にやり右", "口角上右", "右口角上げ"
    ],
    "note": "RE9 原生形态键：右嘴角上翘"
  },
  "口角上げ": {
    "name": "口角上げ",
    "group": "mouth",
    "max": [
      { "s": "CrnPl_04_L", "k": 3.0 },
      { "s": "CrnPl_04_R", "k": 3.0 },
      { "s": "mouthSmileLeft", "k": 1.0 },
      { "s": "mouthSmileRight", "k": 1.0 }
    ],
    "any": [
      "にやり２2", "にやり２3", "口角上げ", "口角上", "にやり"
    ],
    "unless": [
      "にやり２", "にやり２1"
    ],
    "note": "RE9 原生形态键：双嘴角上提"
  },
  "口角下げ": {
    "name": "口角下げ",
    "group": "mouth",
    "max": [
      {
        "max": [
          { "s": "CrnDprs_02_L" },
          { "s": "CrnDprs_02_R" },
          { "s": "CrnDprs_00_L" },
          { "s": "CrnDprs_00_R" }
        ],
        "curve": {
          "deadzone": 0.045,
          "gain": 18.0
        }
      },
      {
        "max": [
          { "s": "mouthFrownLeft" },
          { "s": "mouthFrownRight" }
        ],
        "k": 1.2
      }
    ],
    "any": [
      "口角下げ1", "口角下げ", "口角下げ2"
    ],
    "unless": [
      "口角下げ左", "口角下げ右"
    ],
    "note": "RE9 原生形态键：嘴角下压(悲伤/严肃)"
  }
}

# Update only mouth channels, preserving exact order and ALL other channels (brow, eye, etc.) untouched
new_channels = []
for ch in data.get('channels', []):
    name = ch.get('name')
    group = ch.get('group')
    if group == 'brow':
        # MUST PRESERVE BROW UNTOUCHED!
        new_channels.append(ch)
    elif group == 'mouth' and name in new_mouth_channels:
        new_channels.append(new_mouth_channels[name])
    else:
        new_channels.append(ch)

data['channels'] = new_channels

# Write to workspace and game folder
with open(profile_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

game_profile_path = 'F:/SteamLibrary/steamapps/common/RESIDENT EVIL requiem BIOHAZARD requiem/reframework/data/ShapeKeySystem/builtin/re9/profiles/re9_mmd.json'
with open(game_profile_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("Successfully updated re9_mmd.json in workspace and game dir!")
print(f"Total channels: {len(new_channels)}")
