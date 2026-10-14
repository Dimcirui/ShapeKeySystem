-- ShapeKeySystem: one-shot diagnostic for the game's own blendshape hash table
-- (app.CharacterEditRegion._BlendShapeHashToIndexTable, reported by the SKS_Mocap session).
-- Question it answers before M2 relies on it: is the key murmur3 of the short channel name
-- ("eyeBlinkLeft") or of the full "node.target" name, and does the index agree with the mesh?
-- Writes reframework/data/ShapeKeySystem/hash_probe.txt. Read-only: nothing is written to the game.

local Scene = require("ShapeKeySystem_Core.Scene")
local W = require("ShapeKeySystem_Core.Writer")

local R = {}

local U = require("ShapeKeySystem_Core.Util")
R.murmur3 = U.murmur3   -- murmur3 x86 32-bit over the UTF-16LE bytes, seed 0xFFFFFFFF (Util)
local unbox = U.unbox

-- Entries of a managed Dictionary as { {key, value} }, trying the usual internal layouts.
local function dict_entries(d, out_log)
    local res = {}
    for _, fname in ipairs({ "_entries", "entries" }) do
        local ok = pcall(function()
            local arr = d:get_field(fname)
            local count = d:get_field("_count") or d:get_field("count") or arr:call("get_Length")
            for i = 0, (arr:call("get_Length") or 0) - 1 do
                if i >= count then break end
                local e = arr:call("GetValue(System.Int32)", i) or arr:get_element(i)
                if e then
                    local k = e:get_field("key")
                    local v = e:get_field("value")
                    res[#res + 1] = { k, v }
                end
            end
        end)
        if ok and #res > 0 then out_log[#out_log + 1] = "dictionary layout: " .. fname; return res end
        res = {}
    end
    out_log[#out_log + 1] = "dictionary layout not recognised"
    return res
end

function R.run(path)
    local log = {}
    local function p(fmt, ...) log[#log + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    local ok, err = pcall(function()
        local root = Scene.master_root()
        if not root then p("no master player"); return end
        -- our view of the hunter parts: name -> { names, n }
        local parts = {}
        local c = root:call("get_Child")
        while c do
            local name = Scene.go_name(c)
            local mesh
            pcall(function() mesh = c:call("get_GameObject"):call("getComponent(System.Type)", W.MESH_TYPE) end)
            local n = mesh and (W.M_CN:call(mesh) or 0) or 0
            if n > 0 then
                local names = {}
                local listed = Scene.channel_names(mesh)
                for i = 0, n - 1 do names[i] = listed[i + 1] or "" end
                parts[#parts + 1] = { id = name, names = names, n = n }
            end
            c = c:call("get_Next")
        end
        p("parts with blendshapes: %d", #parts)
        -- hash -> (part, index, variant) from the names we read
        local by_hash = {}
        for _, part in ipairs(parts) do
            for i = 0, part.n - 1 do
                local full = part.names[i]
                local short = full:match("^[^%.]+%.(.+)$") or full
                by_hash[R.murmur3(full)] = by_hash[R.murmur3(full)] or { part.id, i, "full", full }
                if short ~= full then
                    by_hash[R.murmur3(short)] = by_hash[R.murmur3(short)] or { part.id, i, "short", short }
                end
            end
        end
        local cerr = root:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("app.CharacterEditRegionRoot"))
        if not cerr then p("no app.CharacterEditRegionRoot on the master player"); return end
        local tbl = cerr:get_field("_Table")
        for _, e in ipairs(dict_entries(tbl, log)) do
            local region = e[2]
            local bst = region and region:get_field("_BlendShapeHashToIndexTable")
            if bst then
                local entries = dict_entries(bst, log)
                local stats = { full = 0, short = 0, miss = 0, idx_ok = 0, idx_bad = 0 }
                local part_hits = {}
                local samples = {}
                for _, kv in ipairs(entries) do
                    local h, idx = unbox(kv[1]), unbox(kv[2])
                    local m = h and by_hash[h & 0xFFFFFFFF]
                    if m then
                        stats[m[3]] = stats[m[3]] + 1
                        part_hits[m[1]] = (part_hits[m[1]] or 0) + 1
                        if idx == m[2] then stats.idx_ok = stats.idx_ok + 1 else stats.idx_bad = stats.idx_bad + 1 end
                        if #samples < 4 then samples[#samples + 1] = string.format("%s -> %s (mesh %d)", m[4], tostring(idx), m[2]) end
                    else
                        stats.miss = stats.miss + 1
                    end
                end
                local best, bn = "?", 0
                for id, n in pairs(part_hits) do if n > bn then best, bn = id, n end end
                p("region %s: %d entries | short %d, full %d, unmatched %d | index agrees %d, differs %d | part %s",
                    tostring(unbox(e[1]) or e[1]), #entries, stats.short, stats.full, stats.miss, stats.idx_ok, stats.idx_bad, best)
                for _, s in ipairs(samples) do p("    %s", s) end
            end
        end
    end)
    if not ok then p("error: %s", tostring(err)) end
    collectgarbage("collect")
    local f = io.open(path, "w")
    if f then f:write(table.concat(log, "\n"), "\n"); f:close() end
    return log
end

return R
