-- sentinel/tests/run_offline.lua
-- Offline test harness with mock Sylvannas APIs (combat-only)
-- Usage: lua sentinel/tests/run_offline.lua

-- Mock Sylvannas global API (placeholder - Sylvannas uses core.* not _G.SentinelCore)
-- These are no longer used by runtime_action.lua which now uses core.quests.* and core.input.*
_G.SentinelCore = {
    -- Deprecated APIs - kept as stubs for backward compatibility
}

-- Mock core namespace (Sylvannas API compliant)
_G.core = {
    -- Sylvannas core.object_manager APIs
    object_manager = {
        get_local_player = function()
            return {
                is_valid = function() return true end,
                is_unit = function() return true end,
                is_dead = function() return false end,
                is_game_object = function() return false end,
                get_position = function() return { x = 0, y = 0, z = 0 } end,
                get_npc_id = function() return nil end,
                get_entry_id = function() return nil end,
                get_level = function() return 1 end,
                get_class = function() return "Warrior" end,
                get_race = function() return "Human" end,
                get_health = function() return 100 end,
            }
        end,
        get_all_objects = function() return {} end,
        get_object_from_guid = function(guid) return nil end,
        GetUnits = function() return {} end,
    },
    -- Sylvannas core.input APIs
    input = {
        interact_with_object = function(obj) return true end,
        use_item = function(item_id) return true end,
        release_spirit = function() return true end,
        resurrect_corpse = function() return true end,
        move_forward_start = function() return true end,
        move_forward_stop = function() return true end,
        strafe_left_start = function() return true end,
        strafe_left_stop = function() return true end,
        jump = function() return true end,
        disable_movement = function() end,  -- For input blocking tests
    },
    -- Sylvannas core.quests APIs
    quests = {
        is_quest_flagged_completed = function(quest_id) return false end,
        is_on_quest = function(quest_id) return false end,
        accept_quest = function() return true end,
        complete_quest = function() return true end,
        get_quest_reward = function(choice) return true end,
        get_num_quest_log_entries = function() return 0 end,
        get_quest_log_title = function(idx) return nil end,
        select_gossip_option = function(id) return true end,
    },
    -- Sylvannas core.inventory APIs
    inventory = {
        get_gold = function() return 0 end,
        get_items_in_bag = function(bag_id) return {} end,
        sell_greys = function() return true end,
        repair_all_items = function(use_guild) return true end,
    },
    -- Sylvannas core.time API (replaces forbidden GetTime)
    time = function() return os.clock() end,
    game_time = function() return os.clock() * 1000 end,
    geometry = {
        distance = function(p1, p2)
            if not p1 or not p2 then return math.huge end
            return math.sqrt((p2.x-p1.x)^2 + (p2.y-p1.y)^2 + (p2.z-p1.z)^2)
        end,
    },
    http_get = function(url)
        -- Mock HTTP responses
        if url:match("/health") then
            return '{"status":"ok"}'
        elseif url:match("/api/v1/quests/search") then
            return '{"results":[{"id":33,"title":"Wolves Across the Border","level":1,"zone":"Northshire"}]}'
        elseif url:match("/api/v1/quests/") then
            return '{"id":33,"title":"Wolves Across the Border","level":1,"zone":"Elwynn"}'
        elseif url:match("/api/v1/npcs/search") then
            return '{"results":[{"entry":197,"name":"Marshal McBride","zone":"Northshire"}]}'
        elseif url:match("/api/v1/npcs/") then
            return '{"entry":197,"name":"Marshal McBride","zone":"Northshire","position":{"x":-8912.5,"y":-132.3,"z":83.2}}'
        else
            return nil
        end
    end,
    event_bus = {
        on = function(event, callback) return function() end end,
        off = function(event, handler) end,
        send = function(event, ...) end,
        publish = function(event, ...) end,
    },
}

-- Mock JSON module — a real, round-trippable JSON encoder/decoder pair.
-- `stringify(x)` emits valid JSON; `parse(stringify(x))` must reproduce `x`
-- for the table/array/string/number/boolean/nested shapes used by
-- runtime_profile.lua's persistence save/load (RE9).
_G.JSON = {}

local function json_escape(str)
    return (str:gsub('[%z\1-\31"\\]', function(c)
        if c == '"' then return '\\"'
        elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r"
        elseif c == "\t" then return "\\t"
        else return string.format("\\u%04x", string.byte(c))
        end
    end))
end

local function json_encode_value(val)
    local t = type(val)
    if t == "string" then
        return '"' .. json_escape(val) .. '"'
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        local is_array = true
        local max_key = 0
        local count = 0
        for k in pairs(val) do
            count = count + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_array = false
            elseif k > max_key then
                max_key = k
            end
        end
        if is_array and max_key == count then
            local parts = {}
            for i = 1, max_key do
                parts[i] = json_encode_value(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. json_escape(tostring(k)) .. '":' .. json_encode_value(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function json_skip_ws(str, pos)
    local _, e = str:find("^%s*", pos)
    return e + 1
end

local function json_decode_string(str, pos)
    -- `pos` points at the opening quote.
    pos = pos + 1
    local parts = {}
    while true do
        local c = str:sub(pos, pos)
        if c == "" then
            error("Unterminated JSON string")
        elseif c == '"' then
            return table.concat(parts), pos + 1
        elseif c == "\\" then
            local nc = str:sub(pos + 1, pos + 1)
            if nc == "n" then parts[#parts + 1] = "\n"; pos = pos + 2
            elseif nc == "t" then parts[#parts + 1] = "\t"; pos = pos + 2
            elseif nc == "r" then parts[#parts + 1] = "\r"; pos = pos + 2
            elseif nc == '"' then parts[#parts + 1] = '"'; pos = pos + 2
            elseif nc == "\\" then parts[#parts + 1] = "\\"; pos = pos + 2
            elseif nc == "/" then parts[#parts + 1] = "/"; pos = pos + 2
            elseif nc == "u" then
                local hex = str:sub(pos + 2, pos + 5)
                parts[#parts + 1] = string.char(tonumber(hex, 16) % 256)
                pos = pos + 6
            else
                parts[#parts + 1] = nc; pos = pos + 2
            end
        else
            parts[#parts + 1] = c
            pos = pos + 1
        end
    end
end

local function json_decode_value(str, pos)
    pos = json_skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then
        return json_decode_string(str, pos)
    elseif c == "{" then
        local obj = {}
        pos = json_skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = json_skip_ws(str, pos)
            local key
            key, pos = json_decode_string(str, pos)
            pos = json_skip_ws(str, pos)
            assert(str:sub(pos, pos) == ":", "expected ':' in JSON object")
            pos = pos + 1
            local val
            val, pos = json_decode_value(str, pos)
            obj[key] = val
            pos = json_skip_ws(str, pos)
            local sep = str:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "}" then
                return obj, pos + 1
            else
                error("expected ',' or '}' in JSON object")
            end
        end
    elseif c == "[" then
        local arr = {}
        pos = json_skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "]" then return arr, pos + 1 end
        local i = 0
        while true do
            local val
            val, pos = json_decode_value(str, pos)
            i = i + 1
            arr[i] = val
            pos = json_skip_ws(str, pos)
            local sep = str:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "]" then
                return arr, pos + 1
            else
                error("expected ',' or ']' in JSON array")
            end
        end
    elseif c:match("[%-%d]") then
        local _, e, num = str:find("^(%-?%d+%.?%d*[eE]?[%-%+]?%d*)", pos)
        return tonumber(num), e + 1
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        error("Unexpected JSON token at position " .. pos .. ": " .. str:sub(pos, pos + 10))
    end
end

-- Back the harness JSON with the SHIPPED parser (core/JSON) rather than the local encoder above.
-- The runtime uses core/JSON in-game (the Sylvannas sandbox has no global JSON), so a separate
-- harness implementation meant tests exercised a parser production never runs — which is exactly
-- how the "runtime cannot load any profile in-game" bug stayed invisible. One implementation,
-- exercised by both. The local json_* helpers remain as the fallback if core/JSON is unavailable.
-- Resolved lazily: this block runs BEFORE package.path is configured below, so an eager
-- require would silently fail and leave the harness on its own encoder — reintroducing the very
-- test/production split this is meant to remove.
local CoreJson, core_json_checked = nil, false
local function core_json()
    if not core_json_checked then
        core_json_checked = true
        local ok, mod = pcall(require, "core/JSON")
        if ok and type(mod) == "table" and mod.decode and mod.encode then CoreJson = mod end
    end
    return CoreJson
end

_G.JSON.stringify = function(tbl)
    local J = core_json()
    if J then
        local ok, str = pcall(J.encode, tbl)
        if ok and str then return str end
    end
    return json_encode_value(tbl)
end

_G.JSON.parse = function(str)
    if type(str) ~= "string" then return nil end
    local J = core_json()
    if J then
        local ok, result = pcall(J.decode, str)
        if ok then return result end
        return nil
    end
    local ok, result = pcall(json_decode_value, str, 1)
    if ok then return result end
    return nil
end

-- Mock core data file APIs
_G.core.read_data_file = function(path)
    return nil, "Mock: file not found"
end

_G.core.write_data_file = function(path, content)
    return true, nil
end

-- Set up package path for sentinel modules
package.path = table.concat({
    "sentinel/?.lua",
    "sentinel/?/?.lua",
    "sentinel/?/?/?.lua",
    "sentinel/?/?/?/?.lua",
    "sentinel/?/?/?/?/?.lua",
    package.path,
}, ";")

-- Run test modules (combat + core + infrastructure + questing)
-- ---------------------------------------------------------------------------
-- Publish `_G.Sentinel` for plugin tests
-- ---------------------------------------------------------------------------
-- Plugins reach the kernel through `_G.Sentinel` and nothing else -- that is the whole point of the
-- require audit. So a test that exercises `rotations/mage_frost/*` needs a published surface, the
-- same way it needs the mocked `core` above. Building it here rather than in each test file keeps
-- the plugin tests free of kernel wiring, which is exactly the coupling the audit forbids.
--
-- This is the REAL surface with the REAL libraries, not a stub: `Api.build` with the kernel pieces a
-- rotation actually touches. A stubbed surface would let the plugin pass against a shape the kernel
-- does not have.
do
    local Api = require("kernel/api")
    local SpellCatalog = require("kernel/catalogs/spell")
    local Spells = require("kernel/spells")
    local Units = require("kernel/units")
    local Timing = require("kernel/timing")
    local SpellHelper = require("shared/spell_helper")
    local AoeHelper = require("shared/aoe_helper")

    _G.Sentinel = Api.build({
        spell_catalog = SpellCatalog:new(),
        units = Units:new(),
        spells = Spells:new({ spell_helper = SpellHelper, spell_prediction = AoeHelper }),
        timing = Timing:new(),
    })
end

local test_modules = {
    -- The instrument itself. Registered FIRST because every figure below is its output: if the
    -- runner's own contract is broken, no other number in this report means anything.
    "tests/harness/test_suite_runner",

    -- Harness (offline-only; exercises _G.JSON mocked above)
    "tests/harness/test_json_mock",
    -- ADR 09b §7 / U1: the fake window. Registered beside the other instruments because every
    -- assertion the IDE's render tests make is this file's output -- a fake that records nothing
    -- turns "the hover treatment was drawn" into a tautology.
    "tests/ui/test_fake_window",

    -- Entry point (main.lua diagnostics sink, C4)
    "tests/test_main_diagnostics",
    -- ADR 09a W12: the host surface for Recording Mode -- the `_G.Sentinel` verbs an operator drives
    -- through the debug bridge, and the measurement that no menu element is constructed inside a
    -- render callback (a Sylvannas rule that fails in the injector and nowhere else).
    "tests/test_main_recording_verbs",
    -- ADR 09a W13: the host surface that closes the loop -- resolve a saved recording through
    -- QueryServer and run the plan it returns, from `_G.Sentinel` or from the menu, without the
    -- author leaving the client to curl the file by hand.
    "tests/test_main_resolve_verbs",

    -- Core
    "tests/core/test_event_bus",
    "tests/core/test_blackboard",
    "tests/core/test_bt",
    "tests/core/test_geometry",
    "tests/core/test_error_boundary",
    -- ADR 09a §1.5: the versioned event contract, as a pure module.
    "tests/core/test_event_schema",

    -- Kernel (ADR 08 Phase 1: scheduler, frozen snapshot, intent queue, tick clock)
    "tests/kernel/test_truth",
    "tests/kernel/test_cadence_meter",
    "tests/kernel/test_tick_clock",
    "tests/kernel/test_snapshot",
    "tests/kernel/test_snapshot_source",
    "tests/kernel/test_intent_queue",
    "tests/kernel/test_scheduler",

    -- Kernel (ADR 08 Phase 2: bands, ControlBroker, ActivityStack, enforced revocation)
    "tests/kernel/test_bands",
    "tests/kernel/test_movement_release",
    "tests/kernel/test_control_broker",
    "tests/kernel/test_activity_stack",
    "tests/kernel/test_arbitration_pipeline",

    -- Kernel (ADR 08 Phase 3: API surface, manifest, capability resolution, lifecycle)
    "tests/kernel/test_semver",
    "tests/kernel/test_manifest",
    "tests/kernel/test_capabilities",
    "tests/kernel/test_plugin_registry",
    "tests/kernel/test_rotation_discovery",
    "tests/kernel/test_taxi_nodes",
    "tests/kernel/test_taxi_paths",
    -- The third DBC-derived catalog, and the first with a spawn index behind it: `creature` has no
    -- zone column and `creature_zone` is empty, so zones.lua/zones.json/spawn_zones.json are the
    -- only answer to "what lives here" -- and the Rust QueryServer serves /zone/{id}/spawns from
    -- the same generated bytes this pins.
    "tests/kernel/test_zone_catalog",
    "tests/kernel/test_api",
    -- Phase 4c D1: the capability list stops being free text. Every entry in
    -- KERNEL_CAPABILITIES must resolve to something callable on the published surface.
    "tests/kernel/test_capability_resolution",
    -- Phase 4c D3: one fault-counting implementation in the tree, structurally and behaviourally.
    "tests/kernel/test_one_fault_tracker",
    -- Phase 4d D1: the blackboard stops holding the IZI bridge. Characterization pins for all six
    -- readers, written BEFORE the migration -- each reader fell back to a non-forecast branch, so
    -- deleting the write first would have turned the gating off with the suite still green.
    "tests/kernel/test_forecast_service",
    -- Phase 4e D5: the catalog's two GCD flags, pinned against tbcmangos.sqlite. Four of the 64
    -- entries carrying ids were wrong, and `ogcd` is one authority of the two-authority bypass
    -- rule -- so a wrong entry here is one word in a rotation away from an illegal packet.
    "tests/kernel/test_spell_catalog_gcd_truth",
    -- The other half of the same problem. test_spell_catalog_gcd_truth pins the GCD flags; this
    -- pins the RANK ARRAYS, which no test covered at all -- and four of them disagreed with
    -- tbcmangos.sqlite, seal_of_righteousness in both catalogs at once. A wrong array cannot
    -- raise: the resolvers walk it high-first through has_spell, so an unreachable id is skipped
    -- in silence and a level-70 character casts a lower rank with the suite green.
    "tests/kernel/test_catalog_rank_chains",
    "tests/kernel/test_rotation_lib",
    -- The three Phase 4b audits. They share tests/kernel/audit_scope so they cannot disagree
    -- about what they cover.
    "tests/kernel/test_plugin_require_audit",
    "tests/kernel/test_blackboard_namespace_audit",
    "tests/kernel/test_plugin_core_access_audit",
    "tests/kernel/test_log",
    "tests/kernel/test_timing",
    "tests/kernel/test_intent_executors",

    -- Phase 4b D3. Five tracks worked in parallel worktrees off one baseline commit and were
    -- forbidden from touching this file, so every suite below is registered in a single pass
    -- after the merge. That is deliberate: a track that registers its own tests verifies them
    -- against a suite that contains only itself, and a mutant killed in isolation can survive
    -- once other tests exist to mask it.
    "tests/kernel/test_blackboard_handle_guard",  -- the structural guard; the .object audit above
                                                  -- is now its backstop, not the primary defence
    "tests/kernel/test_cond_fraction",            -- the 0-1 pin, on both the threshold and the
                                                  -- SOURCE side
    "tests/kernel/test_cond",
    "tests/kernel/test_nav_under_broker",         -- uses a NAV double; the input double in
                                                  -- test_movement_release cannot see this hole

    -- Integrations
    "tests/integrations/test_izi_bridge",

    -- Infrastructure (runtime sensors, nav, module registry)
    "tests/runtime/test_sensor_hub",
    "tests/runtime/test_nav_adapter",
    "tests/runtime/test_module_registry",
    "tests/runtime/test_tick_isolation",
    "tests/runtime/test_app_tick",
    "tests/runtime/test_callback_bridge",
    -- ADR 09a W7: the producers for recorder.lua's eight `game:*` topics. Every one of them is
    -- DERIVED from a state diff because the SDK has no quest-lifecycle callback, so the derivation
    -- rules are the product and this suite is where they are pinned.
    "tests/runtime/test_world_observer",

    -- Combat module
    "tests/modules/combat/test_spell_catalog",
    "tests/modules/combat/test_spell_catalog_known_rank",
    "tests/modules/combat/test_condition_spell_available",
    "tests/modules/combat/test_registry",
    "tests/modules/combat/test_spell_dispatcher",
    "tests/modules/combat/test_target_selector",
    "tests/modules/combat/test_module",
    "tests/modules/combat/test_module_unsupported_class",
    "tests/modules/combat/test_helper_call_shapes",
    "tests/modules/combat/test_seal_policy",
    "tests/modules/combat/test_seal_availability",
    "tests/modules/combat/test_swing_tracker",
    "tests/modules/combat/test_combat_zone_detector",
    "tests/modules/combat/test_pvp_target_selector",
    "tests/modules/combat/test_retribution_tbc",
    "tests/modules/combat/test_warlock_affliction_tbc",
    "tests/modules/combat/test_context_builder_distance",

    -- Combat profiles
    "tests/rotations/mage_frost/test_frost_conditions",
    "tests/rotations/mage_frost/test_frost_actions",
    "tests/rotations/mage_frost/test_maintenance_tree",
    "tests/rotations/mage_frost/test_aoe_tree",
    "tests/rotations/mage_frost/test_frost_tbc",
    "tests/rotations/mage_frost/test_frost_gcd_priority",
    "tests/rotations/mage_frost/test_pet_controller",
    "tests/rotations/mage_frost/test_frost_item_intents",
    -- Phase 4c D4: the cast path, pinned on outcomes so the same assertions run against both the
    -- dispatcher era and the intent era.
    "tests/rotations/mage_frost/test_frost_cast_intents",

    -- Questing module
    "tests/modules/questing/test_runtime_action",
    "tests/modules/questing/test_runtime_profile",
    "tests/modules/questing/test_runner_state",
    -- ADR 09a §1.5: the event contract as _log_event emits it, and the proof that the three
    -- pre-v1 consumers of the same entry (cockpit, save file, questing:log) still read it.
    "tests/modules/questing/test_event_contract",
    "tests/modules/questing/test_module_control",
    "tests/modules/questing/test_runtime_persistence",
    "tests/modules/questing/test_profile_chain",
    "tests/modules/questing/test_vendor_maintenance",
    "tests/modules/questing/test_runtime_nav",
    "tests/modules/questing/test_runtime_arch_polish",
    "tests/modules/questing/test_quest_objectives",
    "tests/modules/questing/test_kill_pursuit",
    "tests/modules/questing/test_quest_log_space",
    "tests/modules/questing/test_effect_verification",
    "tests/modules/questing/test_recorder",
    -- ADR 09a W12: recorder OWNERSHIP. test_recorder proves the recorder is correct and
    -- test_recording_pipeline proves the producer feeds it; neither could see that nothing in the
    -- tree ever constructed one, so Recording Mode had no way to start, stop, or reach disk.
    "tests/modules/questing/test_recording_control",
    -- ADR 09a W13: the record -> resolve -> run link. Recording Mode wrote a campaign and
    -- POST /resolve lowered one, and nothing joined them; this pins the join, the asynchrony of
    -- `core.http_post`, and the three failure modes the endpoint keeps apart.
    "tests/modules/questing/test_resolve_control",
    -- W8 / ADR 09 §6.2: the executor stops incrementing an index and starts following the
    -- resolver's edge guards. Registered next to the event-contract suite because the two share
    -- the same hard constraint -- the addition must leave every pre-plan profile running as-is.
    "tests/modules/questing/test_execution_plan",

    -- ADR 09b U1: the in-game IDE's design system and widget library. These suites drive the
    -- render path through the fake window registered above, which is the only way an
    -- immediate-mode UI can be observed outside the injector.
    "tests/ui/test_theme",
    "tests/ui/test_widgets",
    -- The one widget with no stock element behind it: it reads `core.input` directly, and two of
    -- the calls it needs are undocumented. Registered right after `test_widgets` because a break
    -- here must read as a widget bug, not as an Explorer search that stopped working. The
    -- view-model goes first: a broken buffer must fail as a buffer, not as a widget that appears
    -- not to draw.
    "tests/ui/test_text_input",
    "tests/ui/test_text_input_widget",
    -- ADR 09b U2: the shell. `test_shell_state` is the whole of the unit's decision-making;
    -- `test_shell` drives the real render path and counts `core.menu.*` constructions per phase,
    -- which is the only offline signal for a Sylvannas rule that otherwise fails in the injector
    -- alone. `test_shell` re-requires `ui/shell` against an instrumented menu, so it restores
    -- `package.loaded` and `_G.core` itself rather than relying on ordering.
    "tests/ui/test_shell_state",
    "tests/ui/test_shell",
    -- The poll-until-resolved primitive every data panel fetches through, plus the harness half
    -- that makes an in-flight request observable offline. Registered BEFORE the panels: a panel
    -- that freezes on a pending fetch must fail as a slot bug here first, not as four panel bugs.
    "tests/ui/test_async_slot",
    -- The :3031 campaign transport the Graph and Explorer authoring commands write through.
    -- Registered next to the slot suite because it answers the same pending contract and is the
    -- other half of "a write that was never issued must not read as a write that succeeded".
    "tests/ui/test_editor_client",
    -- ADR 09b U5: the Runner panel. Registered after the widget suites because it is built
    -- entirely out of them -- a widget regression must fail as a widget bug, not as this panel's.
    "tests/ui/test_runner_panel",
    -- ADR 09b U6: the Explorer panel (quest browser). Registered after the widget suites and
    -- the Runner panel because it follows the same architecture pattern and shares the widgets.
    "tests/ui/test_explorer_panel",
    -- ADR 09b U7: the Properties panel (NPC Inspector, Vendor/Condition/Inventory editors).
    -- Registered after the Explorer because it shares the same widget and test patterns.
    "tests/ui/test_properties_panel",
    -- Phase 3: the Graph panel (campaign graph editor, waypoint/escort/combat tools).
    -- Registered after the Properties panel; follows the same panel architecture pattern.
    "tests/ui/test_graph_panel",
    -- Phase 4: the Database panel (Spawn Scanner F9, Grinding Area Generator F13).
    -- Registered after the Graph panel; follows the same panel architecture pattern.
    "tests/ui/test_database_panel",
    -- ADR 09b U2b: the seam between them. Registered after BOTH, because a failure here is only
    -- meaningful once the shell and the panel are each known good -- U2 and U5 were individually
    -- green while nothing registered the panel and every control on it was inert.
    "tests/ui/test_ide_panels",
    -- F15 end to end: a walked path becomes editable Waypoint/Wait nodes in a campaign. After the
    -- IDE panels suite, because it drives the real Graph binding and only means anything once the
    -- binding itself is known good.
    "tests/ui/test_escort_round_trip",
    -- Phase 5: shell extensions (F12 Travel Editor, F19 Auto Validation, F20 Profile Statistics).
    -- Registered after the IDE panels suite because the extensions integrate with it.
    "tests/ui/test_shell_extensions",
    -- The WIRING of two of those extensions (F12 travel capture/estimate, F20 stats counts).
    -- Separate from the suite above because that one drives the view-models directly and stayed
    -- green while `IdePanels.install` reached neither of them; these cases drive the installed shell.
    "tests/ui/test_travel_stats",
    -- Fixture-shape verification: every Lua fixture MUST mirror Rust serde field names (PR12).
    -- Registered after the panel suites (so panel fixtures are all loaded and known) and
    -- before the offline-loadable guard (so fixture drift is caught before the surface is blanked).
    "tests/ui/test_fixture_shapes",
    -- The guard on ui/* staying loadable with no Sylvannas API present. It blanks `_G.core` for
    -- the duration, so it is registered AFTER the suites that consume the real mocked surface.
    "tests/ui/test_offline_loadable",

    -- Shared libs
    "tests/shared/test_compat",
    "tests/shared/test_humanization",
    "tests/shared/test_class_names",
    "tests/shared/test_aoe_helper",
    -- The QueryServer endpoint is installer-configurable (hosted vs local); this pins that the
    -- runtime's QueryClient reads sentinel/config/query_server.lua, that explicit args still win
    -- (EditorClient depends on that to pin :3031), and that a bad/absent config degrades to the
    -- historical 127.0.0.1:3030 rather than breaking a default dev box.
    "tests/shared/test_query_client_config",

    -- Integration
    "tests/integration/test_combat_dummy",
    -- ADR 09a W7: Recording Mode, connected. test_recorder drives `observe()` by hand and so stayed
    -- green while nothing in the tree published eight of the nine topics it subscribes to; this
    -- suite drives the real producers through a real bus instead.
    "tests/integration/test_recording_pipeline",
    -- Phase 4c D5: one real path, end to end. A real SentinelApp through real ticks, with doubles
    -- at the SDK boundary and nowhere else. Registered LAST because it replaces `_G.core` for the
    -- duration -- it restores it, but running it late keeps that blast radius as small as possible.
    "tests/integration/test_kernel_end_to_end",
}

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------
-- The discovery/execution/counting rules live in `tests/harness/suite_runner.lua`, which is itself
-- under test (`tests/harness/test_suite_runner.lua`, registered first above). Until Phase 4e that
-- logic lived inline here, where nothing could observe it -- and it was wrong in two ways that both
-- understated failure: a `run()` suite was one pcall whose first `error` hid every case after it,
-- and `run()` was preferred over `test*` even when a suite exported both.
--
-- WHAT THIS FILE STILL CANNOT SEE, beyond suite_runner's own list: the `test_modules` table above
-- is hand-maintained. A suite that exists on disk and is registered nowhere does not run, does not
-- fail, and does not appear -- so the totals below are a count of what was ASKED for, never of what
-- exists.
local SuiteRunner = require("tests/harness/suite_runner")

local report = SuiteRunner.run_all(test_modules)
print(SuiteRunner.format_report(report))

if report.failed > 0 or report.opaque_failed > 0 then
    os.exit(1)
else
    os.exit(0)
end
