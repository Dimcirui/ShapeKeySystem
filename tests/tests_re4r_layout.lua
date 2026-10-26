-- Appended to the RE4 fixture: A is the real adapter, with its SDK types initialized.
local id, accesses = 100000, {}
local function object(methods)
    id=id+1;local addr=id
    methods.get_address=function() return addr end
    methods.call=function(self,name,...)
        local f=self[name:match("^([^%(]+)")]
        if f then return f(self,...) end
    end
    return methods
end
local function node(label,channels)
    local tr=object({});tr.label=label
    local hash=object({})
    local resource=object({get_ResourcePath=function() return label..".mesh" end})
    local mm=channels and object({get_BlendShapeChannelNum=function(self) return self.count end,
        getMesh=function() return resource end,get_ChannelNameHash=function() return hash end})
    if mm then mm.count=channels end
    tr.mm=mm
    tr.get_GameObject=function()
        accesses[label]=(accesses[label] or 0)+1
        return object({get_Name=function() return label end,getComponent=function() return tr.mm end})
    end
    tr.get_Child=function() return tr.child end;tr.get_Next=function() return tr.next end
    return tr
end
local root=node("other_actor")
local parts,nodes={},{}
for i=1,48 do
    local tr=node(i<=3 and "part"..i or "weapon"..i,i<=3 and 20 or 0)
    nodes[i]=tr;if i>1 then nodes[i-1].next=tr else root.child=tr end
    if i<=3 then parts[i]={mesh=tr.mm,n=20} end
end
local full=A.signature(root)
local layout=A.capture_layout(root,nodes[1],parts)
assert(layout and #layout.routes==3)
accesses={};assert(A.layout_valid(root,layout))
for name in pairs(accesses) do assert(not name:find("weapon"),"unrelated weapon queried during runtime validation") end
local old=nodes[2].mm;nodes[2].mm=node("replacement",20).mm
assert(not A.layout_valid(root,layout),"replaced component must fail before writing")
nodes[2].mm=old;old.count=21;assert(not A.layout_valid(root,layout));old.count=20
root.child=nodes[2];assert(not A.layout_valid(root,layout),"removed child must invalidate its recorded route")
root.child=nodes[1]
assert(A.layout_valid(root,layout))
nodes[48].next=node("new_shape_part",15)
assert(A.layout_valid(root,layout),"existing targets remain valid until discovery")
assert(A.signature(root)~=full,"periodic full discovery must detect new shape-key parts")
nodes[48].next=nil
nodes[48].label="changed weapon"
assert(A.signature(root)==full,"zero-channel parts must not trigger shape-key rebinding")
assert(not A.layout_valid(node("new_root"),layout))
print("TARGET_LAYOUT_PASS", "48 meshes, 3 live target routes, replacement/removal/count/root/new-part checks")
