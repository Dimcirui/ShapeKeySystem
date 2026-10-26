"""Runtime-cache, actor-selection and input-source regression checks with the REFramework mock."""
import os
from pathlib import Path

import lupa.lua54 as lupa

HERE = Path(os.path.dirname(os.path.abspath(__file__)))
REPO = HERE.parent
os.environ.setdefault("SKS_REFRAMEWORK", str(REPO / "reframework"))

# Reuse the fixture bootstrap without dispatching the full game suite.
runner = HERE / "run.py"
namespace = {"__file__": str(runner)}
exec(runner.read_text(encoding="utf-8").split('if "--instances-only"')[0], namespace)


def source(name):
    return (HERE / name).read_text(encoding="utf-8")


def boot():
    runtime, _, _ = namespace["boot"](namespace["data"])
    runtime.execute(source("mock_sks.lua"))
    return runtime


fixture = source("tests_re4r.lua")
assert "local native_writes=0" in fixture and "local ah=A.bind" in fixture
boot().execute(fixture.split("local native_writes=0")[0] + "\n" + source("tests_re4r_layout.lua"))
boot().execute(fixture.split("local ah=A.bind")[0] + "\n" + source("tests_re4r_actor_tabs.lua")
               + "\n" + source("tests_re4r_background_profile.lua"))
boot().execute(source("tests_actor_instances.lua") + "\n" + source("tests_re4r_idle_actors.lua"))

for name in ("tests_re4r_rules.lua", "tests_re4r_demand.lua", "tests_re4r_pose_subset.lua",
             "tests_re4r_deform_route.lua", "tests_re4r_deform_cache.lua"):
    runtime, _, _ = namespace["boot"](namespace["data"])
    runtime.globals().arg = runtime.table_from([str(REPO)])
    runtime.execute('package.path = arg[1] .. "/reframework/autorun/?.lua;" .. package.path')
    runtime.execute(source(name))

# RE9 shares the strict write path, so the same operations run with its channel checks too.
for game in ("re4", "re9"):
    states = {}
    for variant in ("reference", "B"):
        runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
        runtime.globals().arg = runtime.table_from([str(REPO), variant, game])
        lines = []
        runtime.globals().print = lambda *values: lines.append("\t".join(map(str, values)))
        runtime.execute(source("tests_sculpt_active.lua"))
        states[variant] = [line for line in lines if line.startswith("STATE:")]
    assert states["reference"] == states["B"], game
    print("SCULPT_ACTIVE_EQUIVALENCE_PASS", game, len(states["B"]), "operation states")
print("RE4R_PERFORMANCE_REGRESSIONS_PASS")
