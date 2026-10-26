-- Appended after the actor instance fixture. Discovery and published rows stay enabled.
local before_read=adapter.read
local reads=0
adapter.read=function(...) reads=reads+1;return before_read(...) end
adapter.skip_empty_actors=true
adapter.actor_of=function(face) return face.parent==a and "leon" or "ada" end
options.enabled=true;enabled=true
local c=actor("empty", "Unmapped_", .4, 0)
actors={c.face}
-- c has no matching binding, profile target or static preset.
M.init(adapter)
for frame=600,670 do M.tick(frame,options);M.prepare() end
check(#M.state.instances==1 and M.state.instances[1].channels==0,"empty actor remains in published instance list")
check(reads==0 and c.mesh.writes==0,"empty actor skips signal reads and writes")
Dr.actor_values.ada={[norm("Unmapped_size")]={name="Unmapped_size",value=.65}}
for frame=671,710 do M.tick(frame,options);M.prepare() end
check(math.abs((c.mesh.values[3] or 0)-.65)<1e-9,"new external driver wakes an empty actor")
Dr.actor_values.ada=nil
M.tick(711,options)
check(c.mesh.values[3]==0,"driver release restores the channel before sleeping")
local before=reads
for frame=712,719 do M.tick(frame,options);M.prepare() end
check(reads==before,"actor returns to idle after restoring its driver")
profile("profile_empty","Unmapped_");P.load_all();options.profile="profile_empty"
for frame=720,800 do M.tick(frame,options);M.prepare() end
check(M.state.instances[1].channels>0 and reads>before,"profile changes wake matching channels without removing the actor")
print("IDLE_ACTOR_WAKE_PASS")
