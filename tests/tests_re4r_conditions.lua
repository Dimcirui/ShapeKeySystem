-- RE4R merged conditions: derivation from the old booleans, migration of old rules, hidden defs.
local Cnd = require("ShapeKeySystem_Core.Conditions")
local RC = require("ShapeKeySystem_Games.RE4R.Conditions")
local CondExpr = require("ShapeKeySystem_Core.CondExpr")
local fails, asserts = 0, 0
local function check(ok, what)
    asserts = asserts + 1
    if not ok then fails = fails + 1; print("FAIL [re4r-cond] " .. what) end
end

Cnd.install(RC)
local V = Cnd.V
local function clear() for k in pairs(V) do V[k] = nil end end

-- every group: all combinations of its booleans; first true tier wins, none true is 0
for _, g in ipairs(RC.GROUPS) do
    local n = #g
    for mask = 0, (1 << n) - 1 do
        clear()
        local want = 0
        for i, tier in ipairs(g) do
            local on = (mask >> (i - 1)) & 1 == 1
            V[tier[2]] = on
            if on and want == 0 then want = tier[1] end
        end
        RC.derive(V)
        check(V[g.id] == want, g.id .. " mask " .. mask .. " -> " .. tostring(V[g.id]) .. ", want " .. want)
    end
    clear(); RC.derive(V)
    check(V[g.id] == nil, g.id .. ": nothing read stays nil")
end

-- migration: the old and the rewritten condition agree on every flag combination of the group
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
local migrated = 0
for _, g in ipairs(RC.GROUPS) do
    local n = #g
    for _, tier in ipairs(g) do
        for _, value in ipairs({ true, false }) do
            local old = { type = tier[2], value = value }
            local new = copy(old)
            if RC.migrate(new) then
                migrated = migrated + 1
                check(new.type == g.id, tier[2] .. " migrates into " .. g.id)
                for mask = 0, (1 << n) - 1 do
                    clear()
                    for i, t in ipairs(g) do V[t[2]] = (mask >> (i - 1)) & 1 == 1 end
                    -- is_holding covers aiming and wheeling: a mask with them on and it off cannot happen
                    local possible = not (g.id == "hold_state" and V.is_holding == false
                        and (V.is_aiming or V.is_wheel))
                    -- the HP change flags come from one sample and never hold together
                    if g.id == "hp_change" and V.hp_decreased and V.hp_increased then possible = false end
                    if possible then
                        RC.derive(V)
                        check(Cnd.eval_condition(old) == Cnd.eval_condition(new),
                            tier[2] .. "=" .. tostring(value) .. " mask " .. mask .. " agrees after migration")
                    end
                end
            else
                check(new.type == tier[2], tier[2] .. " is left as it is")
            end
        end
    end
end
-- top tier of 10 groups plus is_holding, true and false each
check(migrated == 22, "22 old conditions migrate (" .. migrated .. ")")
check(not RC.migrate({ type = "is_pull_trigger", value = true }), "is_pull_trigger stays independent")

-- a loaded set is migrated in memory; a migrated condition is not migrated again
local d = CondExpr.normalize({ states = { { clip = "a", rules = { { conditions = {
    { type = "is_aiming", value = true }, { type = "is_holding", value = false }, { type = "is_run", value = true } } } } } } })
local c = d.states[1].rules[1].conditions
check(c[1].type == "hold_state" and c[1].op == "==" and c[1].value == 1, "is_aiming=true -> hold_state == 1")
check(c[2].type == "hold_state" and c[2].op == "==" and c[2].value == 0, "is_holding=false -> hold_state == 0")
check(c[3].type == "is_run" and c[3].value == true, "a lower tier keeps its old id")
CondExpr.normalize(d)
check(c[1].type == "hold_state" and c[1].value == 1 and c[2].value == 0, "normalizing again changes nothing")

-- the old booleans stay defined (old rules, cond() in driver formulas) but are not listed
local hidden, shown = {}, {}
for _, def in ipairs(RC.defs) do if def.hidden then hidden[def.id] = true else shown[def.id] = true end end
check(hidden.is_aiming and hidden.is_holding and hidden.hp_decreased and Cnd.defs.is_aiming ~= nil,
    "merged booleans are hidden but still defined")
check(shown.hold_state and shown.hp_change and shown.is_pull_trigger and shown.is_burning and shown.weapon_kind,
    "merged and independent conditions are listed")
clear()

print("RE4R CONDITIONS " .. asserts .. " assertions; FAILS: " .. fails)
