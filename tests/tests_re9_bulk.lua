-- Exercise the builtin RE9 data through the real readers and the Core writer.
return function(c)
    local check,Signals,R,near=c.check,c.Signals,c.R,c.near
    local data=json.load_file('ShapeKeySystem/builtin/re9/leon.json')
    local Vowels=require('ShapeKeySystem_Games.RE9.Vowels')
    local Eyes=require('ShapeKeySystem_Games.RE9.Eyes')
    local function clone(x)
        if type(x)~='table'then return x end
        local y={};for k,v in pairs(x)do y[k]=clone(v)end;return y
    end
    local function vec(a)return{x=a[1],y=a[2],z=a[3],w=a[4]}end
    local neutrals={}
    local function collect(terms)
        for _,t in ipairs(terms)do
            local p=neutrals[t.bone]or{}
            p.base=vec(t.motion_neutral or{0,0,0,1})
            p.base_position=t.motion_neutral_position and vec(t.motion_neutral_position)or p.base_position or{x=0,y=0,z=0}
            neutrals[t.bone]=p
        end
    end
    for _,rules in ipairs({data.bone_fallbacks,data.expression_fallbacks})do
        for _,rule in pairs(rules)do collect(rule.terms)end
    end
    for _,terms in ipairs(data.vowels.features)do collect(terms)end
    for _,side in ipairs({'L','R'})do
        neutrals[side..'_Eye']={base=vec(data.eye_neutrals[side].rotation),base_position={x=0,y=0,z=0}}
    end
    local function rest()
        for k in pairs(c.poses)do c.poses[k]=nil end
        for name,p in pairs(neutrals)do
            c.poses[name]={base=clone(p.base),value=clone(p.base),
                position=clone(p.base_position),base_position=clone(p.base_position)}
        end
        for k in pairs(NATIVE)do NATIVE[k]=0 end
        for k in pairs(CLIP)do CLIP[k]=nil end
    end
    local function multiply(a,b)
        return{x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
            y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
            z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
            w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z}
    end
    local function shape(weights)
        rest()
        for i,terms in ipairs(data.vowels.features)do
            local v=0;for j=1,5 do v=v+data.vowels.matrix[i][j]*(weights[j]or 0)end
            v=v*data.vowels.scales[i]
            for _,t in ipairs(terms)do
                local p=c.poses[t.bone]
                if t.kind=='pos'then
                    for j,axis in ipairs({'x','y','z'})do
                        if t.axis[j]~=0 then p.position[axis]=p.base_position[axis]+t.axis[j]*v/1000 end
                    end
                else
                    local a=math.rad(v)/2
                    p.value=multiply(p.base,{x=t.axis[1]*math.sin(a),y=t.axis[2]*math.sin(a),z=t.axis[3]*math.sin(a),w=math.cos(a)})
                end
            end
        end
    end
    check(Signals.configure(data),'the entire builtin configuration is accepted')
    rest()
    local requested,seen={},{}
    local function want(label)
        local key=assert(Signals.raw.parse(label),label)
        if not seen[key]then seen[key]=true;requested[#requested+1]=key end
    end
    for label,list in pairs(data.taps)do if #list>0 then want(label)end end
    for _,rules in ipairs({data.bone_fallbacks,data.expression_fallbacks})do for label in pairs(rules)do want(label)end end
    for _,name in ipairs(data.native_names)do
        local suffix=name:match('^HeadSkinned_blendShape%.([%w_]+)$')
        if suffix and not suffix:find('_LOD%d+$')then want('re9.native.'..suffix)end
    end
    for v in ('AIUEO'):gmatch('.')do want('re9Vowel'..v)end
    check(#requested>=140 and Signals.raw.parse('jawOpen')==3,'every declared input parses: '..#requested)
    local h=Signals.bind(c.FACE,requested);local P={}
    Signals.read(h,P,1)
    local valid,zero=true,true
    for _,k in ipairs(requested)do
        valid=valid and type(P[k])=='number'and P[k]==P[k]and P[k]>=0 and P[k]<=1
        zero=zero and math.abs(P[k])<1e-7
    end
    check(valid and zero,'all outputs are finite and zero at rest')
    for j,v in ipairs({'A','I','U','E','O'})do
        local w={0,0,0,0,0};w[j]=1;shape(w)
        local result=Vowels.read(R.find(),false,nil,nil,{})
        local correct=result~=nil
        for k=1,5 do correct=correct and math.abs(result[k]-w[k])<1e-5 end
        check(correct,'authored '..v..' mouth shape recovers its own basis without another vowel')
    end
    shape({.5,.5,0,0,0})
    local frame={};local result=Vowels.read(R.find(),false,nil,nil,frame)
    local cached=Vowels.read(R.find(),false,function()error('cached vowels must not reread')end,nil,frame)
    check(math.abs(result[1]-.5)<1e-5 and math.abs(result[2]-.5)<1e-5 and cached==result,
        'mixed mouth shapes recover together and five consumers share one frame solution')
    rest()
    local eyes=Eyes.bind(c.FACE)
    check(eyes.L and eyes.R and math.abs(Eyes.angles(eyes.L)or 99)<1e-7,'eye descriptors resolve the current rest pose')
    local eye=c.poses.L_Eye
    eye.value=multiply(eye.base,{x=0,y=math.sin(.1),z=0,w=math.cos(.1)})
    local yaw,pitch=Eyes.angles(eyes.L)
    check(type(yaw)=='number'and math.abs(yaw)>.1 and math.abs(pitch)<1e-7,'eye rotation drives gaze')
    local stale=clone(eyes.L);stale.identity='expired'
    check(Eyes.angles(stale)==nil,'stale eye descriptors cannot drive a replacement face')
    rest()
    -- RE9 MMD profile: natives without parameter joints arrive from the clips through Core
    local wink=#CHANNELS;CHANNELS[wink+1],CHANNELS[wink+2],CHANNELS[wink+3]='ウィンク２','あ','お'
    json.dump_file('ShapeKeySystem/mods/names/re9_test.json',{schema='sks.names/1',names={
        'eyeBlinkLeft','eyeBlinkRight','jawOpen','SKS_RE9_Test_NoseForward','BodyKey','ウィンク２','あ','お'}})
    c.refresh_channels()
    c.SKS.call('rescan',{});c.ticks(100)
    local ok,code,why=c.SKS.call('set_profile',{id='re9_mmd'});c.ticks(100)
    check(ok and c.SKS.state.expression.profile.id=='re9_mmd','the RE9 MMD profile compiles through Core: '..tostring(code)..' '..tostring(why))
    CLIP['HeadSkinned_blendShape.UprLdDn_05_L']=1;c.ticks(4)
    check(near(WEIGHTS[wink] or 0,1),'a native sampled from the clips drives an MMD key: '..tostring(WEIGHTS[wink]))
    rest();c.ticks(4)
    check(math.abs(WEIGHTS[wink]or 0)<1e-7,'the MMD key releases when the native returns to rest')
end
