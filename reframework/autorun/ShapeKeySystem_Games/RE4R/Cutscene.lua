-- ShapeKeySystem: read RE4R timeline playback state for the cutscene drive setting.
-- Manager entries are resolved per sample; no timeline objects survive between frames.
local L = require("ShapeKeySystem_Core.I18n")
local C = {}
local list_field, status_method
local active = {}

function C.init()
    local manager = sdk.find_type_definition("chainsaw.TimelineEventManager")
    local info = sdk.find_type_definition("chainsaw.TimelineEventPlayerInfo")
    local status = sdk.find_type_definition("chainsaw.TimelineEventPlayer.Status")
    list_field = manager and manager:get_field("_PlayerInfoList")
    status_method = info and info:get_method("get_CurrentStatus()")
    if not list_field or not status_method or not status then
        return false, "找不到 RE4R 过场播放状态接口"
    end
    active = {}
    for _, name in ipairs({"Play", "Pausing", "Pause", "Resume", "Skip"}) do
        local field = status:get_field(name)
        local value = field and field:get_data(nil)
        if type(value) ~= "number" then return false, L.f("找不到 RE4R 过场状态 %s", name) end
        active[value] = true
    end
    return true
end

function C.playing()
    local ok, result = pcall(function()
        local manager = sdk.get_managed_singleton("chainsaw.TimelineEventManager")
        if not manager then return nil end
        local list = list_field:get_data(manager)
        if not list then return nil end
        for i = 0, list:call("get_Count") - 1 do
            local info = list:call("get_Item", i)
            if info and active[status_method:call(info)] then return true end
        end
        return false
    end)
    if ok then return result end
end

return C
