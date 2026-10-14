-- ShapeKeySystem: every game adapter, required while scripts load (REFramework resolves modules
-- only then). pick() chooses one by REFramework's game name; nothing else in Core or UI asks
-- which game is running.

local R = {}

-- parenthesised: require also returns the loader data, which would become a list entry
R.list = {
    (require("ShapeKeySystem_Games.Wilds.Adapter")),
}

-- "mhwilds", ...; nil when REFramework does not tell. Both call forms are tried: which one this
-- REFramework build accepts is not pinned down.
function R.game_name()
    local ok, n = pcall(function() return reframework.get_game_name() end)
    if ok and type(n) == "string" then return n end
    ok, n = pcall(function() return reframework:get_game_name() end)
    return ok and type(n) == "string" and n or nil
end

function R.pick(game)
    for _, A in ipairs(R.list) do
        if A.id == game then return A end
    end
    return nil
end

return R
