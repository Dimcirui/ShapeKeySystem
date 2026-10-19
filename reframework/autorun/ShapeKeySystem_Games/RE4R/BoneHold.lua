-- Native Leon/Ada expression joints. Eyeballs, neck, scalp and ear attachments stay animated.
-- Resolve exact native names so replacement hair and accessory joints remain independent.
local H = {}
local NAMES = [[
C_Chin
C_D_Chin
C_D_Forehead
C_D_Jaw
C_Depressor
C_Jaw
C_LowerLip
C_LowerLipThickness
C_LowerLip_A
C_Mouth
C_Nose
C_NoseTip
C_U_Chin
C_U_Forehead
C_U_Nose
C_UpperLip
C_UpperLipThickness
C_UpperLip_A1
FacialDef_Face
FacialDef_Fit_L_D_Eyelid3
FacialDef_Fit_L_U_Eyelid3
FacialDef_Fit_R_D_Eyelid3
FacialDef_Fit_R_U_Eyelid3
FacialDef_MouthFit
L_Cheek
L_Cheek01
L_Cheek02
L_Cheek03
L_Cheek04
L_DI_Eyebag
L_DI_Eyebrow_01
L_DI_Eyebrow_02
L_DO_Eyebag
L_DO_Eyebrow_01
L_DO_Eyebrow_02
L_D_Chin
L_D_Eyebag
L_D_Eyelid01
L_D_Eyelid02
L_D_Eyelid03
L_D_Eyelid04
L_D_Eyelid1
L_D_Eyelid2
L_D_Eyelid3
L_D_Eyelid4
L_D_Jaw
L_D_MouthCornerInner
L_DepressorAnguliOris
L_DepressorSupercilii
L_EyelidFurrow
L_I_EyeCorner
L_I_Eyebrow
L_I_EyelidFurrow
L_LLSAN
L_LevatorAnguliOris01
L_LevatorAnguliOris02
L_LevatorAnguliOris03
L_LowerLip01
L_LowerLip01Thickness
L_LowerLip02
L_LowerLip02Thickness
L_LowerLip03
L_LowerLip03Thickness
L_LowerLip_A1
L_LowerLip_A2
L_LowerLip_A3
L_MouthCorner
L_MouthCornerInner
L_MouthCornerThickness
L_MouthCorner_A1
L_Nasalis
L_NasalisThickness
L_Nasalis_corner
L_Nasolabial01
L_Nasolabial02
L_Nasolabial03
L_Nasolabial03_base
L_Nasolabial04
L_NasolabialLine01
L_NasolabialLine02
L_NoseCorner
L_O_EyeCorner
L_O_Eyebrow
L_O_EyelidFurrow
L_Risorius
L_Temporalis
L_UI_Eyebag
L_UI_Eyebrow_01
L_UI_Eyebrow_02
L_UO_Eyebag
L_UO_Eyebrow_01
L_UO_Eyebrow_02
L_U_Chin
L_U_Eyebag
L_U_Eyelid01
L_U_Eyelid02
L_U_Eyelid03
L_U_Eyelid04
L_U_Eyelid1
L_U_Eyelid2
L_U_Eyelid3
L_U_Eyelid4
L_U_MouthCornerInner
L_U_Nose
L_UpperLip01
L_UpperLip01Thickness
L_UpperLip02
L_UpperLip02Thickness
L_UpperLip03
L_UpperLip03Thickness
L_UpperLip_A1
L_UpperLip_A2
L_UpperLip_A3
L_cheek05
R_Cheek
R_Cheek01
R_Cheek02
R_Cheek03
R_Cheek04
R_DI_Eyebag
R_DI_Eyebrow_01
R_DI_Eyebrow_02
R_DO_Eyebag
R_DO_Eyebrow_01
R_DO_Eyebrow_02
R_D_Chin
R_D_Eyebag
R_D_Eyelid01
R_D_Eyelid02
R_D_Eyelid03
R_D_Eyelid04
R_D_Eyelid1
R_D_Eyelid2
R_D_Eyelid3
R_D_Eyelid4
R_D_Jaw
R_D_MouthCornerInner
R_DepressorAnguliOris
R_DepressorSupercilii
R_EyelidFurrow
R_I_EyeCorner
R_I_Eyebrow
R_I_EyelidFurrow
R_LLSAN
R_LevatorAnguliOris01
R_LevatorAnguliOris02
R_LevatorAnguliOris03
R_LowerLip01
R_LowerLip01Thickness
R_LowerLip02
R_LowerLip02Thickness
R_LowerLip03
R_LowerLip03Thickness
R_LowerLip_A1
R_LowerLip_A2
R_LowerLip_A3
R_MouthCorner
R_MouthCornerInner
R_MouthCornerThickness
R_MouthCorner_A1
R_Nasalis
R_NasalisThickness
R_Nasalis_corner
R_Nasolabial01
R_Nasolabial02
R_Nasolabial03
R_Nasolabial03_base
R_Nasolabial04
R_NasolabialLine01
R_NasolabialLine02
R_NoseCorner
R_O_EyeCorner
R_O_Eyebrow
R_O_EyelidFurrow
R_Risorius
R_Temporalis
R_UI_Eyebag
R_UI_Eyebrow_01
R_UI_Eyebrow_02
R_UO_Eyebag
R_UO_Eyebrow_01
R_UO_Eyebrow_02
R_U_Chin
R_U_Eyebag
R_U_Eyelid01
R_U_Eyelid02
R_U_Eyelid03
R_U_Eyelid04
R_U_Eyelid1
R_U_Eyelid2
R_U_Eyelid3
R_U_Eyelid4
R_U_MouthCornerInner
R_U_Nose
R_UpperLip01
R_UpperLip01Thickness
R_UpperLip02
R_UpperLip02Thickness
R_UpperLip03
R_UpperLip03Thickness
R_UpperLip_A1
R_UpperLip_A2
R_UpperLip_A3
R_cheek05
Tongue01
Tongue02
Tongue03
Tongue04
Tongue05
]]
local function call(obj, method, ...)
    if not obj then return end
    local ok, value = pcall(function(...) return obj:call(method, ...) end, ...)
    if ok then return value end
end
function H.joints(face)
    local out = {}
    for name in NAMES:gmatch("%S+") do
        local joint = call(face, "getJointByName(System.String)", name)
        if joint then out[#out + 1] = {joint = joint, name = name} end
    end
    return out
end
function H.layers(face)
    local go = call(face, "get_GameObject")
    local motion = call(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local count = call(motion, "getLayerCount")
    if type(count) ~= "number" or count < 0 or count > 64 then return end
    local layers = {}
    for i = 0, count - 1 do
        local layer = call(motion, "getLayer(System.UInt32)", i)
        if layer then layers[#layers + 1] = layer end
    end
    if #layers > 0 then return layers end
end
return H
