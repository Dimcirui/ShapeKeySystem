"""English for the builtin data files: profile names / descriptions, channel notes, signal notes.

The Chinese stays the source text. note_en(zh) translates a channel note sentence by sentence
(split at "。"): a sentence is matched against PATTERNS first, then looked up in FRAG. A sentence
with no English raises KeyError, so a new Chinese note cannot ship without its translation.
Shape-key names inside notes (eye_ウインク2_L, 上, ...) are identifiers and stay as they are.
Used by tools/i18n/add_en.py (adds the *_en fields in place) and tools/vrc_profiles/gen.py.
"""
import re

PROFILE_EN = {
    "airi": ("Airi", "Airi's native shape keys (eye_mabataki_L, eye_zitome_1_L, mouth_smile_1_L, eyebrow_angry_1_L, ...). Mappings marked guessed need testing in game."),
    "arkit": ("ARKit 52", "Apple ARKit's 52 standard shape keys, plus the common left / right split versions (BrowInnerUpLeft/Right, CheekPuffLeft/Right) and the iris slides (Look*)."),
    "chocolat": ("Chocolat family (Komado: Chocolat / Plum / Lime)", "Native shape keys shared by Komado's Chocolat, Plum and Lime (eye_blink_1_L, jitome_1_L, mouth_smile_1_L, eyebrow_angry_1_L, ...); Lime's other spellings (eye_brink_1_L, A / U) are fallback names. Mappings marked guessed need testing in game."),
    "eku": ("EKU", "EKU's native shape keys (eyebrow_up_L, mouth_niya_3_L, vrc.v_aa, ...), for the EKU face. Mappings marked guessed need testing in game."),
    "kaguya": ("Kaguya", "Kaguya's native shape keys (blink_L, zito_L, brow_angry_L, m_a, Iris_up_L, ...). Mappings marked guessed need testing in game."),
    "karin": ("Karin", "Karin's native shape keys (blink_L, jitome_L, kuchi_smile_1_L, mayu_angry_1_L, LookUp, ...). vrc.blink_left and the like are empty keys and are not used. Mappings marked guessed need testing in game."),
    "kipfel": ("Kipfel", "Kipfel's native shape keys (eye_close_left, eye_jitome_left, mouth_smile2_left, eyebrow_angry_left, ...; the side suffixes are _left / _right). Mappings marked guessed need testing in game."),
    "mafuyu": ("Mafuyu", "Mafuyu's native Japanese shape keys (eye_ウインク2_L, eye_ジト目_L, eyebrow_怒り_L, mouth_あ, ...). Mappings marked guessed need testing in game."),
    "manuka": ("Manuka family (studio jingo: Manuka / Kumaly / Rindo / Selestia)", "Native shape keys shared by studio jingo's Manuka, Kumaly, Rindo and Selestia (eye_close_L, eye_jito_L, brow_anger_L, mouth_smile_L, ...). Where a key deforms differently between them the channel note says so; mappings marked guessed need testing in game."),
    "maya": ("Maya", "Maya's native Japanese shape keys (ウィンク２, ジト目_L, 口角上げL, 瞳上, ...). The brow keys cover both sides. Mappings marked guessed need testing in game."),
    "milltina": ("Milltina", "Milltina's native shape keys (brow_up_L, eye_zitome_1_L, mouth_happy_1_L, ...), for the Milltina face. The gaze left / right does not copy EKU's horizontal flip and needs checking in game; mappings marked guessed need testing."),
    "mmd": ("MMD basic morphs", "Common expressions for PMX models (a safe minimum): upper lids, mouth corners, mouth open, stretch, narrow, brows. Each channel takes the first name of its any list that exists on the mesh; full-width / half-width, case and spaces are ignored. If a wrong key is picked, save a profile that extends mmd with the any order changed and bind it to this part."),
    "moko": ("Moko", "Moko's native shape keys (eye_wink2_L, eye_scornful_L, mouth_raise_L, eyebrow_negative_L, pupil_up, ...). Mappings marked guessed need testing in game."),
    "nitco": ("nitco", "nitco's native shape keys (eye_blink_left, eye_zitome, mouth_fun, eyebrows_angry, VRM_lookup, ...). The VRChat keys Blink Left / Lowerlid Left and the like are empty and not used. Mappings marked guessed need testing in game."),
    "sairou": ("sairou", "sairou's native Japanese shape keys (ウィンク２, ジト目, 怒まゆ左, 視線上, ...). Mappings marked guessed need testing in game."),
    "shinano": ("Shinano native keys", "Shinano's own expression shape keys (eye_close_L, mouth_smile_L, ...), for Shinano faces without ARKit keys. Left / right split versions come first; mappings marked guessed need testing in game."),
}

# signals.json: "<fcParam joint> <meaning>" -> the meaning part
SIGNAL_EN = {
    "闭眼": "eye close", "睁大（推测）": "eye wide (guess)", "眯眼": "squint", "皱眉肌": "brow pinch (corrugator)",
    "压眉": "brow lowerer", "眉心上提": "inner brow raiser", "眉尾上提": "outer brow raiser",
    "提上唇鼻翼肌": "sneer (levator labii alaeque nasi)", "提上唇肌": "upper lip raiser (levator labii)",
    "颧小肌": "zygomaticus minor", "颧大肌": "smile (zygomaticus major)", "颊肌": "dimple (buccinator)",
    "颈阔肌": "stretch (platysma)", "降口角肌": "mouth corner down (depressor anguli oris)",
    "降下唇肌": "lower lip down (depressor labii)", "嘟嘴（漏斗）": "pucker (funnel)", "抿嘴": "lip press",
    "嘴左移": "mouth left", "嘴右移": "mouth right", "（含义推测）": "(meaning guessed)", "颏肌上提": "chin raiser",
    "张嘴": "jaw open", "吸颊": "cheek suck", "上唇内卷": "upper lip roll", "下唇内卷": "lower lip roll",
    "鼓腮": "cheek puff", "笑+闭眼修正（推测）": "smile + eye-close corrective (guess)",
    "嘟嘴+双唇合拢（推测为 pucker）": "pucker + lips together (guessed to be pucker)", "双唇合拢": "lips together",
}


def signal_note_en(note):
    """'L_EyeClose 闭眼' -> 'L_EyeClose eye close'; 'MouthMove_Upper（含义推测）' -> '... (meaning guessed)'"""
    m = re.match(r"^([A-Za-z0-9_]+)\s*(.*)$", note)
    head, rest = (m.group(1), m.group(2)) if m else ("", note)
    if not rest:
        return note
    if rest not in SIGNAL_EN:
        raise KeyError(f"signal note without English: {note!r}")
    return (head + " " + SIGNAL_EN[rest]).strip()


# gen.py slot descriptions (tools/vrc_profiles/gen.py SLOTS) and other plain sentences
DESC = {
    "眉毛上移": "Brow up",
    "眉毛下压": "Brow down",
    "眉头上提": "Inner brow up",
    "眉头下压（皱眉）": "Inner brow down (frown)",
    "闭眼": "Eye closed",
    "上眼睑下降、眼裂缩小": "Upper lid lowers, eye narrows",
    "睁大眼": "Eye wide open",
    "下眼睑上提（笑眼下睑分量）": "Lower lid raised (the lower-lid part of a smiling eye)",
    "脸颊鼓起": "Cheek puffed",
    "张嘴": "Mouth open",
    "u 口型（嘴唇收拢）": "\"u\" mouth shape (lips rounded)",
    "嘴角上扬": "Mouth corner up",
    "嘴角下垂": "Mouth corner down",
    "嘴角向外、嘴变宽": "Mouth corner out, mouth wider",
    "嘴角向内、嘴变窄": "Mouth corner in, mouth narrower",
    "抿嘴（嘴角收紧）": "Lips pressed (corners tightened)",
    "嘴整体移向角色左侧": "Whole mouth to the character's left",
    "嘴整体移向角色右侧": "Whole mouth to the character's right",
    "嘴整体上移": "Whole mouth up",
    "嘴整体下移": "Whole mouth down",
    "虹膜上移": "Iris up",
    "虹膜下移": "Iris down",
    "虹膜移向角色左侧": "Iris to the character's left",
    "虹膜移向角色右侧": "Iris to the character's right",
}
GAZE_NOTE_EN = "Gaze direction converted as measured in game on Shinano: iris toward the character's own left (+X) = yaw +1"
SIDE_EN = {"左": "left", "右": "right"}
JOINT_EN = "one key for both sides, half of each side's signal"

FRAG = {
    "视线方向按 Shinano 游戏实测换算：虹膜移向角色自身左侧(+X) 对应 yaw +1": GAZE_NOTE_EN,
    "整条眉毛上移": "Whole brow up",
    "捏脸区的嘴位置键": "Mouth position key from the face-customization keys",
    "仅 Plum 有": "Plum only",
    "已逐项观察虹膜及眼睑向命名方向移动；沿用原配置角度节点和已确认的水平反转": "Each key checked: iris and lids move in the named direction; keeps the original profile's angle nodes and the confirmed horizontal flip",
    "Blender 测量：eye_look_left 虹膜移向角色自身左侧(+X)、eye_look_right 移向右侧，与 Shinano 同向；按 Shinano 游戏实测换算（虹膜移向角色左侧 = yaw +1）": "Blender measurement: eye_look_left moves the iris to the character's own left (+X), eye_look_right to the right, same as Shinano; converted as measured in game on Shinano (iris to the character's left = yaw +1)",
    "须游戏核实": "Needs checking in game",
    "整条眉毛上移，会带眉头": "Whole brow up, the inner brow comes along",
    "游戏里没有对应信号": "No matching game signal",
    "游戏里没有舌头信号": "The game has no tongue signal",
    "游戏里没有对应信号（fcParam 053-056 可能是下巴横移，待实测）": "No matching game signal (fcParam 053-056 may be the jaw moving sideways, to be measured)",
    "Plum 有 eyebrow_outer_up（只提眉尾）；Chocolat / Lime 用 eyebrow_up，整条眉毛上移": "Plum has eyebrow_outer_up (outer brow only); Chocolat / Lime use eyebrow_up, the whole brow up",
    "形变很小（约 1mm）": "Very small deformation (about 1 mm)",
    "u 口型带张嘴": "\"u\" shape with the mouth open",
    "已观察单侧眉毛整体上移；此键不是纯眉尾上提，会带眉头一起上移": "Observed: one brow moves up as a whole; not a pure outer-brow raise, the inner brow comes along",
    "已观察眉头上提、眉尾稍下垂；对应眉心上提": "Observed: inner brow up, outer brow slightly down; used for the inner brow raise",
    "已观察自然单侧闭眼；0.8 留缝，1.0 闭合": "Observed: natural one-eye close; 0.8 leaves a gap, 1.0 closes",
    "沿用小幅眨眼 gamma 0.3，输出上限 1；不叠加其他闭眼键": "Keeps the small-blink gamma 0.3, output capped at 1; no other eye-close key stacked",
    "已观察单侧上眼睑降低、眼裂缩小；": "Observed: one upper lid lowers, the eye narrows",
    "形态已观察为单侧睁大；eyeWide 的游戏语义由词典标为推测，需游戏实测": "Observed as a one-eye widen; the dictionary marks eyeWide's game meaning as a guess, needs testing in game",
    "已观察单侧下眼睑上提": "Observed: one lower lid rises",
    "作为笑眼下睑分量；cheekSquint 游戏语义为推测，需游戏实测": "Used as the lower-lid part of a smiling eye; cheekSquint's game meaning is a guess, needs testing in game",
    "已观察单侧脸颊鼓起；顶点位移也确认对应侧脸颊向外扩": "Observed: one cheek puffs; vertex offsets confirm that side's cheek moves outward",
    "已观察单侧嘴角上扬；其他 grin/niya/smile 变体不再自动驱动": "Observed: one mouth corner rises; the other grin/niya/smile variants are no longer driven automatically",
    "已观察单侧嘴角向外移动、嘴宽增加": "Observed: one mouth corner moves out, the mouth widens",
    "已观察单侧嘴角向内移动、嘴宽缩小；funnelTogether 游戏语义为推测，需游戏实测": "Observed: one mouth corner moves in, the mouth narrows; funnelTogether's game meaning is a guess, needs testing in game",
    "使用已截图核对的最大权重 0.4，双侧平均": "Uses the maximum weight 0.4 checked on screenshots, both sides averaged",
    "近似颊肌收紧：Blender 观察对应侧嘴角向内收、形成收紧嘴形；不生成真实酒窝": "Approximates a cheek-muscle tightening: in Blender that side's mouth corner pulls in to a tight mouth shape; no real dimple",
    "近似抿嘴：Blender 观察对应侧闭口收紧、嘴角出现紧绷折角；不是精确唇面压缩": "Approximates a lip press: in Blender that side closes tight with a taut fold at the corner; not an exact lip compression",
    "不是纯平移": "Not a pure shift",
    "brow_tare：眉头上提为主": "brow_tare: mostly the inner brow up",
    "单眼闭眼键（ウインク2）；双眼合一的 eye_まばたき 不驱动，避免重复": "One-eye close key (ウインク2); the both-eyes eye_まばたき is not driven, to avoid doubling",
    "Kumaly 有 brow_tail_up（只提眉尾）；其余成员用 brow_up，整条眉毛上移，会带眉头": "Kumaly has brow_tail_up (outer brow only); the others use brow_up, the whole brow up, the inner brow comes along",
    "Kumaly 用 brow_head_up（眉头上提）；Manuka / Rindo 的 brow_tare 眉头上提、眉尾下垂；Selestia 的 brow_tare 只压眉尾，眉头不动": "Kumaly uses brow_head_up (inner brow up); Manuka / Rindo's brow_tare raises the inner brow and lowers the outer brow; Selestia's brow_tare only lowers the outer brow, the inner brow stays",
    "Kumaly / Rindo 外侧上睑略升约 1mm；Manuka / Selestia 几乎看不出睁大": "Kumaly / Rindo: the outer upper lid rises about 1 mm; Manuka / Selestia barely widen",
    "Kumaly / Selestia 嘴角下压；Manuka 是唇中上拱的 ∩ 形，嘴角本身几乎不降": "Kumaly / Selestia: mouth corners down; Manuka: a ∩ shape with the lip centre arched up, the corners barely drop",
    "嘴角向内收紧，近似抿嘴": "Mouth corners tighten inward, close to a lip press",
    "仅 Kumaly 有；是歪嘴口型（嘴角扭曲、收拢），不是纯平移": "Kumaly only; a crooked mouth (corners twisted and drawn in), not a pure shift",
    "MMD 式单眼闭眼键：ウィンク２ 是角色左眼、ｳｨﾝｸ２右 是右眼（Blender 已确认）": "MMD-style one-eye close keys: ウィンク２ is the character's left eye, ｳｨﾝｸ２右 the right (confirmed in Blender)",
    "MMD 式单眼闭眼键：ウィンク２ 是角色左眼（Blender 已确认）": "MMD-style one-eye close key: ウィンク２ is the character's left eye (confirmed in Blender)",
    "用おっとり（外侧上睑下垂）近似；ジト目_L 测得外侧上睑反而上移，没有使用": "Approximated with おっとり (outer upper lid droops); ジト目_L measured with the outer upper lid moving up instead, not used",
    "Blender 已观察单侧整条眉毛上移；近似眉尾上提，会带动眉头": "Blender: the whole brow on one side moves up; approximates an outer brow raise, the inner brow comes along",
    "Blender 已观察单侧眉毛整体下压": "Blender: the brow on one side moves down as a whole",
    "Blender 已观察眉头明显上提、眉尾略下垂": "Blender: inner brow clearly up, outer brow slightly down",
    "近似皱眉：Blender 观察眉头下压及怒眉弧度；眉心横向聚拢很小，不是纯合拢": "Approximates a frown: in Blender the inner brow lowers with an angry arch; the brows barely draw together, not a pure pinch",
    "避开带明显折皱的 anger_4/5": "Avoids anger_4/5, which crease visibly",
    "Blender 已观察自然单侧闭眼，权重 0.5 为半闭、1 为闭合；线性响应，不沿用 EKU gamma": "Blender: natural one-eye close, weight 0.5 half closed, 1 closed; linear response, EKU's gamma not used",
    "Blender 已观察对应侧上睑下降、眼裂缩小": "Blender: that side's upper lid lowers, the eye narrows",
    "Blender 已观察对应侧睁大眼；eyeWide 游戏语义在词典中为推测": "Blender: that side's eye opens wide; eyeWide's game meaning is a guess in the dictionary",
    "Blender 已观察对应侧下眼睑上提；近似笑眼下睑分量，cheekSquint 游戏语义为推测": "Blender: that side's lower lid rises; approximates the lower-lid part of a smiling eye, cheekSquint's game meaning is a guess",
    "Blender 正面和侧面已观察对应侧脸颊外鼓": "Blender, front and side views: that side's cheek puffs out",
    "Blender 已观察对应侧嘴角上扬；两个笑信号只接到本键，合成上限 1": "Blender: that side's mouth corner rises; both smile signals go to this key only, combined up to 1",
    "Blender 已观察对应侧嘴角下压": "Blender: that side's mouth corner goes down",
    "Blender 已观察对应侧嘴角向外移动、嘴宽增加": "Blender: that side's mouth corner moves out, the mouth widens",
    "Blender 已观察对应侧嘴宽缩小；游戏 funnelTogether 语义为推测": "Blender: that side of the mouth narrows; the game's funnelTogether meaning is a guess",
    "近似颊肌收紧：Blender 已观察对应侧嘴角向内收、唇线折角；不形成真实酒窝": "Approximates a cheek-muscle tightening: in Blender that side's corner pulls in with a fold in the lip line; no real dimple",
    "近似抿嘴：Blender 已观察对应侧闭口紧绷和嘴角收紧；不是精确唇面压缩，也不保证抵消张嘴键": "Approximates a lip press: in Blender that side closes taut and the corner tightens; not an exact lip compression, and not guaranteed to cancel the mouth-open key",
    "近似偏嘴：Blender 已观察对应方向非对称嘴形；主要是口角扭曲和收拢，唇中心横向平移极小，不是纯嘴整体平移": "Approximates a mouth shift: in Blender an asymmetric mouth toward that side; mostly a twisted, drawn-in corner, the lip centre barely moves sideways, not a pure whole-mouth shift",
    "eyebrow_lower 名字是“下”，实测是眉头上提、眉尾下垂": "eyebrow_lower is named \"lower\", but measures as inner brow up, outer brow down",
    "单眼闭眼键（wink2）": "One-eye close key (wink2)",
    "困りまゆ：眉头微升、眉尾下垂，并向内收": "困りまゆ: inner brow slightly up, outer brow down, drawn inward",
    "没有直接对应的信号": "No directly matching signal",
    "笑眼，用笑+闭眼修正信号（推测）": "Smiling eyes, from the smile + eye-close corrective signal (guess)",
    "没有直接对应的信号（眨眼已由 eye_close 驱动）": "No directly matching signal (blinking is driven by eye_close)",
    "按观察者的左右（2026-10-10 游戏内实测：原先按角色自身映射，方向反了）": "By the viewer's left / right (measured in game 2026-10-10: mapping by the character's own side came out reversed)",
    "鼓腮（推测 pout 是鼓腮）": "Cheek puff (pout guessed to be a cheek puff)",
    "元音口型，没有直接对应的信号": "Vowel mouth shape, no directly matching signal",
    "已观察单侧眉毛整体下压": "Observed: one brow moves down as a whole",
    "已观察双眉向眉心移动；左右皱眉信号平均后只驱动本键": "Observed: both brows move toward the centre; the left and right frown signals are averaged into this key only",
    "EKU 无已验证的单侧合拢键，无法独立左右合拢": "EKU has no verified one-side pinch key, left and right cannot pinch separately",
    "已观察 aa 张嘴口型；按用户偏好保留本键和小信号响应曲线，未使用 mouth_a_1": "Observed: aa open-mouth shape; kept with its small-signal response curve as the user prefers, mouth_a_1 not used",
    "已观察双侧嘴唇收拢、形成小圆形开口": "Observed: both lips draw in to a small round opening",
    "已观察双侧嘴角下垂；虽然键名为 angry，实际用于降口角": "Observed: both mouth corners drop; named angry, used to lower the corners",
    "此模型无已验证的独立左右下垂键": "This model has no verified separate left / right drop keys",
    "近似皱鼻：Blender 观察鼻部上移；不提上唇、不产生鼻翼皱褶": "Approximates a nose wrinkle: in Blender the nose moves up; no upper-lip raise, no nostril creases",
    "双侧键无法独立左右": "A both-sides key, left and right cannot move separately",
    "近似提上唇：Blender 观察上唇升高、露上齿，同时下唇下降且嘴变宽；不是纯提唇": "Approximates an upper-lip raise: in Blender the upper lip rises and shows the upper teeth while the lower lip drops and the mouth widens; not a pure lip raise",
    "近似降下唇：Blender 观察下唇下降，同时上唇轻微上提，嘴张开": "Approximates a lower-lip drop: in Blender the lower lip drops while the upper lip rises a little and the mouth opens",
    "近似角色左移：Blender 顶点确认上下唇中心 X 增加；画面中向右偏移，同时嘴角轻微上扬": "Approximates a shift to the character's left: Blender vertices confirm the lip centre X increases; on screen it moves right, and the corners rise slightly",
    "近似角色右移：Blender 顶点确认上下唇中心 X 减少；画面中向左偏移，同时嘴角轻微上扬": "Approximates a shift to the character's right: Blender vertices confirm the lip centre X decreases; on screen it moves left, and the corners rise slightly",
    "Blender 已观察嘴整体上移并稍向前；游戏 mouthMove.up 的语义在词典中仍为推测": "Blender: the whole mouth moves up and slightly forward; the game's mouthMove.up meaning is still a guess in the dictionary",
    "Blender 已观察嘴整体下移并稍向后；由整体嘴部位置键近似运动": "Blender: the whole mouth moves down and slightly back; a whole-mouth position key approximates the motion",
    "近似颏肌上提：Blender 观察下巴向上缩短，顶点位移最大约 0.00179 局部单位；不产生颏肌皱褶": "Approximates a chin raise: in Blender the chin shortens upward, vertex offsets up to about 0.00179 local units; no chin creases",
    "近似吸腮：Blender 观察脸颊轮廓向中线收窄；是横向缩窄，不是脸颊向内凹陷": "Approximates sucked-in cheeks: in Blender the cheek outline narrows toward the midline; a sideways narrowing, not a hollow cheek",
    "近似内卷：Blender 观察双唇整体后缩（局部 Y 增加），不产生真实内卷；上下唇无法独立，仅取较强输入驱动一个键": "Approximates rolled-in lips: in Blender both lips pull back (local Y increases), no real roll; the upper and lower lips cannot move separately, the stronger input drives one key",
    "近似双唇合拢：Blender 观察闭口、唇线中央拱起，带双弧形唇线；不保证抵消其他张嘴键，双侧平均": "Approximates lips together: in Blender the mouth closes with the lip-line centre arched, a double-arc lip line; not guaranteed to cancel other mouth-open keys, both sides averaged",
    "捏脸区的脸颊键，双侧一起鼓": "Cheek key from the face-customization keys, both sides puff together",
    "a 口型张嘴幅度不大": "\"a\" shape, the mouth does not open far",
    "Blender 已观察张嘴及口腔，当前捏脸状态下张嘴也已测试；先采用线性响应": "Blender: mouth opening and the mouth interior checked, also tested with the current sculpt values; linear response for now",
    "Blender 已观察双唇收拢、圆形开口；左右平均到同一个键": "Blender: both lips draw in to a round opening; left and right averaged into one key",
    "近似皱鼻：Blender 观察鼻部上提，并附带少量口周移动；没有鼻翼皱褶，无法独立左右": "Approximates a nose wrinkle: in Blender the nose lifts with a little movement around the mouth; no nostril creases, left and right cannot move separately",
    "近似提上唇：Blender 已核对 0.4 权重的上唇上提与露齿；会附带下唇下降和张嘴": "Approximates an upper-lip raise: checked in Blender at weight 0.4, the upper lip rises and the teeth show; the lower lip drops and the mouth opens with it",
    "左右平均、总输出最高 0.4": "Left and right averaged, total output at most 0.4",
    "近似降下唇：Blender 已核对 0.4 权重的下唇下拉及开口；也提上唇，左右平均、总输出最高 0.4": "Approximates a lower-lip drop: checked in Blender at weight 0.4, the lower lip pulls down and the mouth opens; also raises the upper lip, left and right averaged, total output at most 0.4",
    "Blender 已观察嘴整体上移；游戏 mouthMove.up 语义仍为推测": "Blender: the whole mouth moves up; the game's mouthMove.up meaning is still a guess",
    "Blender 已观察嘴整体下移": "Blender: the whole mouth moves down",
    "近似颏肌上提：Blender 侧面已观察下巴向上缩短；不形成颏肌皱褶": "Approximates a chin raise: Blender side view shows the chin shortening upward; no chin creases",
    "近似吸腮：Blender 正侧面已观察脸下部轮廓横向收窄；不形成真实脸颊内凹": "Approximates sucked-in cheeks: Blender front and side views show the lower face outline narrowing sideways; no real hollow cheek",
    "近似内卷：Blender 侧面已观察嘴整体后缩；不是唇缘内卷，上下唇无法独立，取较强输入": "Approximates rolled-in lips: Blender side view shows the whole mouth pulling back; not a lip roll, the upper and lower lips cannot move separately, the stronger input wins",
    "近似闭唇：Blender 已观察嘴中央收紧、口隙减小；不保证抵消张嘴键": "Approximates closed lips: in Blender the mouth centre tightens and the gap narrows; not guaranteed to cancel the mouth-open key",
    "vrc.v_pp 在此模型近乎无变化，故没有使用": "vrc.v_pp barely changes on this model, so it is not used",
    "左眼闭眼（模型自己的左侧）": "Left eye closed (the model's own left)",
    "没有 ウィンク２ 时用 ウィンク（部分模型是笑眼形状，仍然会闭眼）": "Uses ウィンク when there is no ウィンク２ (a smiling-eye shape on some models, it still closes the eye)",
    "右眼闭眼": "Right eye closed",
    "双眼闭眼，只在没有左右 wink 键时使用": "Both eyes closed, used only when there are no left / right wink keys",
    "上眼皮半闭；闭眼时自动减弱，避免和闭眼叠加压穿": "Upper lid half closed; fades while the eye closes so the two do not stack and clip through",
    "下眼皮上抬（附加，多数模型没有）": "Lower lid raised (extra, most models lack it)",
    "嘟嘴": "Pucker",
    "嘴角上扬（对称键，没有左右版时使用）": "Mouth corners up (symmetric key, used when there is no left / right version)",
    "嘴角下撇（对称键，没有左右版时使用）": "Mouth corners down (symmetric key, used when there is no left / right version)",
    "嘴横拉": "Mouth stretched wide",
    "嘴收窄": "Mouth narrowed",
    "上唇上提（附加）": "Upper lip raised (extra)",
    "下唇下拉（附加）": "Lower lip pulled down (extra)",
    "眉上": "Brows up",
    "眉下": "Brows down",
    "眉心上提": "Inner brows up",
    "皱眉（部分模型的 怒り 也会动眼睛）": "Frown (on some models 怒り also moves the eyes)",
    "唇中上拱的 ∩ 形，嘴角略降": "A ∩ shape with the lip centre arched up, the corners drop slightly",
    "左右合一的“上”，整条眉毛上移": "The combined \"上\" key, the whole brow up",
    "ほほ上げ：脸颊和下眼睑一起上提": "ほほ上げ: cheeks and lower lids rise together",
    "すぼめ：嘴角向内收拢": "すぼめ: mouth corners draw inward",
    "张嘴 × 嘟嘴": "Mouth open × pucker",
    "眨眼时按闭眼程度减弱：和闭眼键叠加会让睫毛陷进脸里":
        "Fades as a blink closes the eye: stacked with the blink key, her lashes sink into the face",
    "笑眼（^^）：下眼睑上提 × 同侧嘴角上扬，开心 1 多在 0.3–0.5、开心 2 约 0.75；战吼眯眼时没有笑，不会触发":
        "Smiling eyes (^^): lower lid lift × that side's mouth corner up, mostly 0.3-0.5 in happy 1 and about 0.75 in happy 2; the battle cry squint has no smile, so it does not fire",
    "嘴角几乎完全向外时张开成露齿笑：左右嘴角向外的平均值过 0.6 后线性到 0.5（开心 2）":
        "Opens into a toothy grin once the corners are almost fully outward: the left / right outward average past 0.6, linear up to 0.5 (happy 2)",
}

# sentence patterns: (regex on the Chinese sentence, function(match) -> English)
PATTERNS = [
    (re.compile(r"^最大位移 ([\d.]+)mm（(.+)）$"), lambda m: f"Max displacement {m.group(1)} mm ({m.group(2)})"),
    (re.compile(r"^Blender 测量：无形变$"), lambda m: "Blender measurement: no deformation"),
    (re.compile(r"^网格里没有 (.+) 时用 (.+)$"), lambda m: f"Uses {m.group(2)} when the mesh has no {m.group(1)}"),
    (re.compile(r"^形变很小（嘴角(向内|上移|下移)约 ([\d.]+)mm）$"),
     lambda m: "Very small deformation (mouth corner {} about {} mm)".format(
         {"向内": "in by", "上移": "up by", "下移": "down by"}[m.group(1)], m.group(2))),
    (re.compile(r"^(.+?)：眉头上提、眉尾下垂$"), lambda m: f"{m.group(1)}: inner brow up, outer brow down"),
    (re.compile(r"^游戏动作表情由面部骨骼驱动：同时读骨骼信号 (.+)，取较大者$"),
     lambda m: f"Gameplay emotes move the face bones: also reads the bone signal {m.group(1)}, the larger wins"),
]


def sentence_en(s):
    """one Chinese sentence (no 。) -> English"""
    if s in FRAG:
        return FRAG[s]
    if s in DESC:
        return DESC[s]
    for rx, fn in PATTERNS:
        m = rx.match(s)
        if m:
            return fn(m)
    # gen.py composites: <desc>（左侧）/（右侧） and <desc>；左右合一的键，左右信号各取一半
    m = re.match(r"^(.+)（(左|右)侧）$", s)
    if m and m.group(1) in DESC:
        return f"{DESC[m.group(1)]} ({SIDE_EN[m.group(2)]})"
    m = re.match(r"^(.+)；左右合一的键，左右信号各取一半$", s)
    if m and m.group(1) in DESC:
        return f"{DESC[m.group(1)]}; {JOINT_EN}"
    raise KeyError(f"no English for note sentence: {s!r}")


def note_en(note):
    """a Chinese channel note -> English, sentence by sentence"""
    parts = note.split("。")
    trailing = parts[-1] == ""
    if trailing:
        parts = parts[:-1]
    out = [sentence_en(p.strip()) for p in parts if p.strip()]
    text = ". ".join(out)
    if trailing and not text.endswith((".", ";")):
        text += "."
    return text
