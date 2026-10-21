-- Exercise the bulk RE9 configuration through real readers and the Core writer.
return function(c)
    local check,Signals,R,Hash=c.check,c.Signals,c.R,c.Hash
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
    for _,rules in ipairs({data.bone_fallbacks,data.expression_fallbacks,data.native_output_rules})do
        for _,rule in pairs(rules)do collect(rule.terms)end
    end
    for _,terms in ipairs(data.vowels.features)do collect(terms)end
    local function rest()
        for k in pairs(c.poses)do c.poses[k]=nil end
        for name,p in pairs(neutrals)do
            c.poses[name]={base=clone(p.base),value=clone(p.base),
                position=clone(p.base_position),base_position=clone(p.base_position)}
        end
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
    check(Signals.configure(data,'bones_first',true),'the entire native bulk configuration is accepted together')
    rest()
    local requested={}
    for _,rules in ipairs({data.bone_fallbacks,data.expression_fallbacks,data.native_output_rules})do
        for label in pairs(rules)do requested[#requested+1]=assert(Signals.raw.parse(label))end
    end
    for v in ('AIUEO'):gmatch('.')do requested[#requested+1]=assert(Signals.raw.parse('re9Vowel'..v))end
    check(#requested==142 and Signals.raw.parse('jawOpen')==3,'all 142 declared inputs retain the original raw key identities')
    local h=Signals.bind(ARMOR,requested,'bones_first');local P={}
    Signals.read(h,P,1)
    local valid,zero=true,true
    for _,k in ipairs(requested)do
        valid=valid and type(P[k])=='number'and P[k]==P[k]and P[k]>=0 and P[k]<=1
        zero=zero and math.abs(P[k])<1e-7
    end
    check(valid and zero and h.motion_requests==0,'all bulk outputs are finite and zero at native rest without any Motion reads')
    check(not Signals.raw.parse('tongueOut')and not Signals.raw.parse('re9.native.Unknown'),
        'unobserved or invented native outputs are not declared')
    for j,v in ipairs({'A','I','U','E','O'})do
        local w={0,0,0,0,0};w[j]=1;shape(w)
        local result=Vowels.read(R.find(),false,nil,nil,{})
        local correct=result~=nil
        for k=1,5 do correct=correct and math.abs(result[k]-w[k])<1e-5 end
        check(correct,'authored native '..v..' mouth shape recovers its own basis without another vowel')
    end
    shape({.5,.5,0,0,0})
    local frame={};local result=Vowels.read(R.find(),false,nil,nil,frame)
    local cached=Vowels.read(R.find(),false,function()error('cached vowels must not reread')end,nil,frame)
    check(math.abs(result[1]-.5)<1e-5 and math.abs(result[2]-.5)<1e-5 and cached==result,
        'mixed mouth shapes recover together and five consumers share one frame solution')
    shape({0,0,0,0,1});Signals.read(h,P,1)
    check(math.abs(P[Signals.raw.parse('re9VowelO')]-1)<1e-5 and h.motion_requests==0,
        'the full reader publishes the O basis using physical bones only')
    rest()
    local native_label,native_rule=next(data.native_output_rules)
    local removed=native_rule.terms[1].bone;local saved=c.poses[removed];c.poses[removed]=nil
    local native_name=native_rule.native_parameters[1]
    local old_position,old_rotation,old_count=c.motion.getCalculatedLocalPosition,c.motion.getCalculatedLocalRotation,c.motion.get_JointCount
    local old_hash=c.motion.getJointIndexByNameHash
    local scalar_reads=0;local scalar=.42
    c.motion.getJointIndexByNameHash=function(_,hash)return hash==Hash.hash(native_name)and 0 or -1 end
    c.motion.get_JointCount=function()return 1 end
    c.motion.getCalculatedLocalPosition=function()scalar_reads=scalar_reads+1;return scalar and{x=scalar,y=0,z=0}end
    c.motion.getCalculatedLocalRotation=function()return nil end
    local single=Signals.bind(ARMOR,{Signals.raw.parse(native_label)},'bones_first')
    Signals.read(single,P,1)
    check(P[single.keys[1]]==.42 and single.sources[native_label]=='motion_native'and scalar_reads==1,
        'missing physical and same-name Motion poses permit the exact allowlisted native scalar fallback')
    scalar=0;Signals.read(single,P,1)
    check(P[single.keys[1]]==0 and single.sources[native_label]=='motion_native',
        'an exact native scalar zero remains a valid sample')
    scalar=nil;Signals.read(single,P,1)
    check(P[single.keys[1]]==0 and single.sources[native_label]=='unavailable',
        'a failed scalar clears the prior value instead of retaining it')
    c.poses[removed]=saved
    local before=scalar_reads;Signals.read(single,P,1)
    check(P[single.keys[1]]==0 and single.sources[native_label]=='bones'and scalar_reads==before,
        'a physical rest pose wins over native Motion even after a previous fallback')
    c.motion.getCalculatedLocalPosition,c.motion.getCalculatedLocalRotation,c.motion.get_JointCount=
        old_position,old_rotation,old_count
    c.motion.getJointIndexByNameHash=old_hash
    local bad=clone(data);bad.native_output_rules[native_label].native_parameters={'HeadSkinned_blendShape.Unknown'}
    check(not Signals.configure(bad,'bones_first',true),'native output aliases cannot authorize a different scalar source')
    bad=clone(data);bad.vowels.solvers[2].ids=clone(bad.vowels.solvers[1].ids)
    bad.vowels.solvers[2].inverse=clone(bad.vowels.solvers[1].inverse)
    check(not Vowels.configure(bad.vowels),'duplicate active sets are rejected instead of silently changing mouth fitting')
    check(Signals.configure(data,'bones_first',false),'the entire expansion can be disabled in one configuration')
    local disabled=Signals.bind(ARMOR,{Signals.raw.parse('re9VowelO'),Signals.raw.parse(native_label)},'bones_first')
    Signals.read(disabled,P,1)
    check(P[disabled.keys[1]]==0 and P[disabled.keys[2]]==0 and disabled.motion_requests==0,
        'disabled bulk inputs produce zero and make no Motion requests')
    check(Signals.configure(data,'bones_first',true),'bulk configuration restores after diagnostic rejection and opt-out')
    rest()
    local eyes=Eyes.bind(ARMOR)
    check(eyes.L and eyes.R and math.abs(Eyes.angles(eyes.L)or 99)<1e-7,'eye descriptors resolve the current native rest pose')
    local eye=c.poses.L_Eye
    eye.value=multiply(eye.base,{x=0,y=math.sin(.1),z=0,w=math.cos(.1)})
    local yaw,pitch=Eyes.angles(eyes.L)
    check(type(yaw)=='number'and math.abs(yaw)>.1 and math.abs(pitch)<1e-7
        and Eyes.diagnostics().L.motion_requests==0,'native eye rotation drives gaze without opening Motion')
    local stale=clone(eyes.L);stale.identity='expired'
    check(Eyes.angles(stale)==nil,'stale eye descriptors cannot drive a replacement head')
    rest()
    local names={'い','う','え','お','目上','目下','口横狭め左','口横狭め右','びっくり左','びっくり右','怒り左','怒り右'}
    local index={}
    for _,name in ipairs(names)do CHANNELS[#CHANNELS+1]=name;index[name]=#CHANNELS-1 end
    c.refresh_channels()
    c.SKS.call('rescan',{});c.ticks(100)
    local ok,code,why=c.SKS.call('set_profile',{id='re9_mmd'});c.ticks(100)
    check(ok and c.SKS.state.expression.profile.id=='re9_mmd','the real Core compiles every bulk MMD expression: '..tostring(code)..' '..tostring(why))
    shape({0,0,0,0,1});c.ticks(4)
    check((WEIGHTS[index['お']]or 0)>.99 and (WEIGHTS[13]or 0)<1e-5,
        'the O receiver is written through Core without retaining a full jaw-open receiver')
    check((WEIGHTS[index['口横狭め左']]or 0)<1e-5 and (WEIGHTS[index['口横狭め右']]or 0)<1e-5,
        'native O suppresses duplicate narrowing on both independent mouth receivers')
    rest();c.ticks(4)
    local released=true;for _,i in pairs(index)do released=released and math.abs(WEIGHTS[i]or 0)<1e-7 end
    check(released,'all newly matched model receivers release when the input returns to rest')
end
