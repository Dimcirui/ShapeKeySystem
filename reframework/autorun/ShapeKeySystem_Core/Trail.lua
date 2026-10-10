-- ShapeKeySystem: crash-proof event trail. Every line is flushed to
-- reframework/data/ShapeKeySystem/trail.log at once, so after a crash the last lines show what
-- SKS (and the game state it saw) was doing. Only rare events are written, never per frame.

local T = {}

local PATH = "ShapeKeySystem\\trail.log"
local f = nil
local lines = 0
T.frame = 0

function T.open()
    f = io.open(PATH, "w")
    lines = 0
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " trail start\n"); f:flush() end
end

function T.event(fmt, ...)
    if not f then return end
    local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    f:write(string.format("%s f%06d %s\n", os.date("%H:%M:%S"), T.frame, text))
    f:flush()
    lines = lines + 1
    if lines > 5000 then T.open() end   -- keep the file small; the tail is what matters
end

function T.close()
    if f then f:close(); f = nil end
end

return T
