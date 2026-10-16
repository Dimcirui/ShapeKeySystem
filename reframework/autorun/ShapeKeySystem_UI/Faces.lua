-- ShapeKeySystem panel: face navigator styles. One style = a manifest
-- reframework/data/ShapeKeySystem/faces/<id>.json
--   { "name": "Q 版大头", "size": [600, 600], "images": "ShapeKeySystem/faces/<id>/",
--     "zones": { "brow": [[cx, cy, rx, ry], ...], "eye": [...], "cheek": [...], "mouth": [...] } }
-- plus images under reframework/images/<images>: face_lines.png and face_<zone>_<idle|hover|sel|glow>.png
-- (ellipses in image pixels). Drop in a new pair of manifest + folder to add a style; it is picked up
-- when scripts are reset.

local F = {}

F.DEFAULT = "portrait"

-- manifest zone -> expression region key; draw / hit-test order
local ZONE_ORDER = {
    { zone = "brow",  key = "brow" },
    { zone = "eye",   key = "eye" },
    { zone = "cheek", key = "nose_cheek" },
    { zone = "mouth", key = "mouth" },
}

local styles, by_id = {}, {}

local function ells_of(list)
    local out = {}
    for _, e in ipairs(type(list) == "table" and list or {}) do
        local cx, cy, rx, ry = tonumber(e[1]), tonumber(e[2]), tonumber(e[3]), tonumber(e[4])
        if cx and cy and rx and ry and rx > 0 and ry > 0 then out[#out + 1] = { cx, cy, rx, ry } end
    end
    return out
end

local function load_one(path, id)
    local ok, m = pcall(json.load_file, path)
    if not ok or type(m) ~= "table" then return nil end
    local size = type(m.size) == "table" and m.size or {}
    local w, h = tonumber(size[1]), tonumber(size[2])
    if not w or not h or w <= 0 or h <= 0 then return nil end
    local prefix = type(m.images) == "string" and m.images or ("ShapeKeySystem/faces/" .. id .. "/")
    if not prefix:find("[/\\]$") then prefix = prefix .. "/" end
    local zones = {}
    for _, z in ipairs(ZONE_ORDER) do
        local ells = ells_of(type(m.zones) == "table" and m.zones[z.zone])
        if #ells > 0 then zones[#zones + 1] = { key = z.key, img = z.zone, ells = ells } end
    end
    return { id = id, name = type(m.name) == "string" and m.name or id, w = w, h = h, prefix = prefix, zones = zones }
end

function F.refresh()
    styles, by_id = {}, {}
    local ok, files = pcall(fs.glob, "ShapeKeySystem\\\\faces\\\\[^\\\\]+\\.json")
    if ok and type(files) == "table" then
        for _, p in ipairs(files) do
            local id = p:match("([^\\/]+)%.json$")
            local s = id and load_one(p, id)
            if s then styles[#styles + 1] = s; by_id[id] = s end
        end
    end
    -- default first, the rest by name
    table.sort(styles, function(a, b)
        if (a.id == F.DEFAULT) ~= (b.id == F.DEFAULT) then return a.id == F.DEFAULT end
        return a.name < b.name
    end)
end

function F.list() return styles end

function F.image_paths()
    local paths = {}
    for _, style in ipairs(styles) do
        paths[#paths + 1] = style.prefix .. "face_lines.png"
        for _, zone in ipairs(style.zones) do
            for _, state in ipairs({ "idle", "hover", "sel", "glow" }) do
                paths[#paths + 1] = style.prefix .. "face_" .. zone.img .. "_" .. state .. ".png"
            end
        end
    end
    return paths
end

-- the style for a setting value; unknown / missing ids fall back to the default, then the first
function F.get(id)
    return by_id[id or F.DEFAULT] or by_id[F.DEFAULT] or styles[1]
end

F.refresh()

return F
