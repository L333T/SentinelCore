--- Sentinel Runtime Profile Executor
--- Loads and executes a RuntimeProfile (compiled from sentinel-questing/compiler)
--- Uses Blackboard for state, EventBus for events

local RuntimeAction = require("modules/questing/runtime_action")
local Blackboard = require("core/blackboard")
local Compat = require("shared/compat")
local QueryClient = require("shared/query_client")
local Geometry = require("core/geometry")
local EventBus = require("core/event_bus")
local NavAdapter = require("integrations/nav_client/adapter")
local EventSchema = require("core/event_schema")
local ExecutionPlan = require("modules/questing/execution_plan")

-- UnitHelper is exposed from RuntimeAction for object lookup (Sylvannas API compliant)
local UnitHelper = RuntimeAction.UnitHelper

-- JSON access. The Sylvannas sandbox provides NO global `JSON` and no usable `load`, so the old
-- `JSON and JSON.parse(...)` / `load("return "..json)()` path meant the runtime could not parse a
-- compiled profile in-game at all (it failed with "attempt to call a nil value"). Prefer the
-- shipped pure-Lua parser so the in-game path is the one tests exercise too; fall back to an
-- injected global only if some harness supplies one.
local JsonLib = (function()
    local ok, mod = pcall(require, "core/JSON")
    if ok and type(mod) == "table" and mod.decode and mod.encode then
        return mod
    end
    return nil
end)()

local function json_parse(str)
    if type(str) ~= "string" then return nil end
    if JsonLib then
        local ok, value = pcall(JsonLib.decode, str)
        if ok then return value end
        return nil
    end
    if JSON and JSON.parse then
        local ok, value = pcall(JSON.parse, str)
        if ok then return value end
    end
    return nil
end

local function json_stringify(value)
    if JsonLib then
        local ok, str = pcall(JsonLib.encode, value)
        if ok then return str end
        return nil
    end
    if JSON and JSON.stringify then
        local ok, str = pcall(JSON.stringify, value)
        if ok then return str end
    end
    return nil
end

-- ============================================================================
-- Named constants for proximity checks (W3.1, W3.2, W3.6)
-- ============================================================================
local INTERACT_RANGE = 5.0   -- Talking to NPCs, looting, interacting
local LOOT_RANGE = 5.0       -- Looting objects
local COMBAT_RANGE = 30.0     -- Spell / melee range
local ARRIVAL_TOLERANCE = 5.0 -- Close enough to destination

-- ============================================================================
-- Recovery state machine constants (W4.1, W4.4)
-- ============================================================================
local MAX_RETRIES_PER_ACTION = 5        -- Max retry attempts for one action
local MAX_CONSECUTIVE_FAILURES = 3      -- Max failures before profile stops
local NAV_TIMEOUT = 30.0                -- Seconds before navigation is considered timed out
local GHOST_TIMEOUT = 300.0             -- Seconds before ghost recovery is abandoned — must
                                        -- cover a REAL corpse run (graveyard → corpse can be
                                        -- minutes at ghost speed), not just an in-place res
local GHOST_RETRY_INTERVAL = 5.0        -- Seconds between death state checks
local MAX_DEATHS_PER_OPERATION = 3      -- Deaths at one operation before it is abandoned
local MAX_CONDITION_WAIT = 300.0        -- Seconds a Completion-role Condition gate may hold before forced advance
local NAV_RECHECK_INTERVAL = 2.0        -- Seconds between "is this trip still needed?" checks while
                                        -- navigating (the state ticks at frame rate; the check walks
                                        -- the quest log)
local RELOAD_CHECK_INTERVAL = 5.0       -- Seconds between hot-reload polls (each poll reads+hashes the profile)
local MAX_LOG_ENTRIES = 500             -- In-memory execution log ring-buffer cap (oldest dropped)
local SAVE_LOG_ENTRIES = 100            -- Newest log entries persisted in the save file

-- Sylvannas `unit:get_class()` returns a numeric class_id, not a string. Map it to the
-- Title-Case class name so ClassIs conditions (compiled from RestedXP's Title-Case class
-- tails, e.g. "Warrior/Paladin", "!Rogue") compare correctly. B8: this used to be a private
-- copy of the map; it now defers to shared/class_names.lua, the one authority shared with
-- combat (which upper-cases at its own boundary for `player.class_name`).
local ClassNames = require("shared/class_names")
local CLASS_ID_TO_NAME = ClassNames.CLASS_ID_TO_NAME

local RuntimeProfile = {}
RuntimeProfile.__index = RuntimeProfile

--- `event_bus`/`blackboard` are injected by QuestingModule so the executor shares the APP's bus.
--- Without that, publishing an engage request lands on a private bus the combat module never
--- subscribed to, and the bot walks up to a mob and stands there.
function RuntimeProfile:new(json_path, dry_run, event_bus, blackboard)
    local o = setmetatable({}, RuntimeProfile)
    o._json_path = json_path
    o._dry_run = dry_run == true
    o._profile = nil
    o._blackboard = blackboard or Blackboard:new()
    -- No explicit host/port: reads sentinel/config/query_server.lua so a hosted QueryServer works
    -- without a code change (falls back to 127.0.0.1:3030 when the config is absent).
    o._query = QueryClient:new()
    o._current_operation_idx = 1
    o._current_op_id = nil              -- Tracks identity for retry reset
    o._variables = {}
    o._event_bus = event_bus or EventBus:new()  -- W3.3 (shared bus when injected)
    -- B4: shared adapter keyed by event_bus -- same instance SentinelApp/combat hold
    -- when this event_bus is the shared app bus (see integrations/nav_client/adapter.lua).
    o._nav = NavAdapter.get_shared(o._event_bus) -- W3.3

    -- Recovery state machine (W4.1–W4.5)
    o._state = "running"                -- "running" | "navigating" | "ghost" | "failed" | "finished"
    o._current_action_retries = 0       -- Per-action retry count (W4.1)
    o._consecutive_failures = 0         -- Across-action failure count (W4.4)
    o._current_action_idx = 1           -- Current action index within operation (W1.1)
    o._nav_start_time = nil             -- When navigation began (W4.2)
    o._ghost_start_time = nil           -- When death was detected (W4.3)
    o._last_blocked_action = nil        -- Copy of the action that triggered blocked
    o._execution_log = {}               -- Structured log entries (W4.5), ring-buffered
    o._log_total = 0                    -- Total events ever logged; entry.seq stays meaningful
                                        -- after the ring buffer drops the oldest entries
    o._run_id = nil                     -- ADR 09a §1.5 run identity, minted by _log_event on the
                                        -- first event of a seq sequence (see reset())
    o._wait_started_at = nil            -- When the current Completion-role Condition gate started waiting
    o._wait_action_key = nil            -- Identity of the action currently being waited on
    o._wait_level_progress = nil        -- "level:xp" snapshot for LevelAtLeast gates (XP1);
                                        -- any change resets the bounded-wait clock, like kills
    o._level_gate_grind = false         -- True while WE raised module.combat.auto_engage_world
                                        -- for a holding LevelAtLeast gate (XP1)

    -- Hot reload (T16)
    o._json_mtime = nil                  -- Last known mtime for hot reload polling

    -- Persistence (W5.2, W5.3)
    o._save_path = o:_compute_save_path()
    o._dirty = false                    -- Track unsaved changes

    -- Route reconciliation: operations already rewound to once this session (backward
    -- jumps to a ready turn-in are one-shot per target op — see _apply_reconciliation).
    o._rewound_ops = {}

    -- Extended state for v2 persistence (T18)
    o._completed_quests = {}            -- { [quest_entry] = true }
    o._temporary_variables = {}         -- Runtime-only variables
    o._visited_vendors = {}             -- Vendor entries visited
    o._known_flight_paths = {}          -- Flight path nodes discovered
    o._known_hearth_location = nil      -- Last known hearth position

    -- Dry-run simulation tracking
    o._sim_result = nil

    return o
end

-- ====================================================================
-- Persistence helpers (W5.2)
-- ====================================================================

--- Identify the logged-in character, so save state never crosses characters. Two characters
--- running the same profile used to share ONE save file keyed only by profile path, so
--- logging into character B resumed at character A's step. Returns a filesystem-safe
--- lowercase name, or nil when no player is readable (offline harness, load screens).
--- Cached once seen — a character cannot change mid-session.
function RuntimeProfile:_character_key()
    if self._char_key then return self._char_key end
    local player = UnitHelper.get_local_player()
    if player and player.get_name then
        local ok, name = pcall(player.get_name, player)
        if ok and type(name) == "string" then
            local key = name:lower():gsub("[^%w]", "")
            if key ~= "" then
                self._char_key = key
                return key
            end
        end
    end
    return nil
end

--- Derive the save file path from the profile JSON path AND the character identity.
--- e.g. "profiles/mage.json" → "profiles/mage.arthas.save.json"
--- Falls back to the legacy character-less name only when no player is readable
--- (offline tests); in-game, saves are always per-character.
function RuntimeProfile:_compute_save_path()
    local path = self._json_path or "questing"
    local char = self:_character_key()
    local suffix = char and ("." .. char .. ".save.json") or ".save.json"
    if path:match("%.json$") then
        return path:gsub("%.json$", suffix)
    end
    return path .. suffix
end

--- Serialize current execution state for persistence.
function RuntimeProfile:_serialize_state()
    return {
        version = 2,
        -- Identity of the character this save belongs to; _load_save refuses saves
        -- written by anyone else.
        character = self:_character_key(),
        profile_fingerprint = (self._profile and self._profile.content_hash) or "",
        current_operation_idx = self._current_operation_idx,
        variables = self._variables,
        saved_at = (core and core.time and core.time()) or 0,
        -- v2 additions (T18): full execution state
        current_action_idx = self._current_action_idx,
        completed_quests = self._completed_quests or {},
        temporary_variables = self._temporary_variables or {},
        visited_vendors = self._visited_vendors or {},
        known_flight_paths = self._known_flight_paths or {},
        known_hearth_location = self._known_hearth_location,
        execution_history = (function()
            -- Persist only the newest SAVE_LOG_ENTRIES — the save is a resume point,
            -- not an archive, and full-log saves grew without bound.
            local log = self._execution_log or {}
            if #log <= SAVE_LOG_ENTRIES then return log end
            local tail = {}
            for i = #log - SAVE_LOG_ENTRIES + 1, #log do
                tail[#tail + 1] = log[i]
            end
            return tail
        end)(),
    }
end

--- Persist execution state to disk.
--- Called on operation advance, variable change, stop, and reset.
function RuntimeProfile:_save()
    if self._dry_run then return false end
    -- Recompute: the constructor may have run before the player object was readable
    -- (load screen), leaving a character-less legacy path cached.
    self._save_path = self:_compute_save_path()
    local data = self:_serialize_state()
    local json = json_stringify(data)
    if not json then
        -- Manual serialization fallback (never leaves the save unwritten).
        json = self:_serialize_lua(data)
    end
    if not json then
        return false
    end
    -- Atomic-save journal: the sandbox has no rename, so the .tmp file is a completed-write
    -- journal — both files get the FULL contents, tmp first. A crash mid-write of the real
    -- save leaves the journal intact for _load_save to fall back to.
    if not self:_write_save_file(self._save_path .. ".tmp", json) then
        return false
    end
    if self:_write_save_file(self._save_path, json) then
        self._dirty = false
        return true
    end
    return false
end

--- Write `json` to `path` through the sandbox-viable mechanisms, in preference order.
function RuntimeProfile:_write_save_file(path, json)
    -- Sylvannas signature is core.write_data_file(filename, data) — NO self. Passing `core` as the
    -- first argument made every save fail, fall through to a non-existent core.write_file, and then
    -- to io.open, which does not exist in the sandbox: "attempt to index global 'io'" on every save.
    if core and core.write_data_file then
        -- The loader requires the data file to EXIST before it can be written; without this the
        -- save silently never lands, every run starts fresh, and the bot walks the whole route
        -- back to step 1. create_data_file is a no-op when the file is already there.
        if core.create_data_file then
            pcall(core.create_data_file, path)
        end
        local ok = pcall(core.write_data_file, path, json)
        if ok then
            return true
        end
    end
    if core and core.write_file then
        local ok = pcall(core.write_file, path, json)
        if ok then
            return true
        end
    end
    -- Offline/test fallback only: `io` is absent in the Sylvannas sandbox, so it must never be
    -- indexed unguarded.
    if type(io) == "table" and io.open then
        local f = io.open(path, "w")
        if f then
            f:write(json)
            f:close()
            return true
        end
    end
    return false
end

--- Attempt to restore execution state from a previous save file.
--- Returns true if state was restored, false if no save or fingerprint mismatch.
function RuntimeProfile:_load_save()
    if not (core and core.read_data_file) then
        return false
    end
    self._save_path = self:_compute_save_path()
    local json, err = core.read_data_file(self._save_path)
    local decoded = json and json_parse(json) or nil
    if not decoded or type(decoded) ~= "table" then
        -- A crash mid-write can truncate (or never create) the main save; the .tmp
        -- journal was fully written first and carries the same contents.
        local tmp = core.read_data_file(self._save_path .. ".tmp")
        decoded = tmp and json_parse(tmp) or nil
        if not decoded or type(decoded) ~= "table" then
            return false
        end
        self:_log_event("save_restored_from_journal", {})
    end
    -- Verify fingerprint matches current profile
    local profile_hash = self._profile and self._profile.content_hash or ""
    local save_fingerprint = decoded.profile_fingerprint or ""
    if profile_hash == "" or save_fingerprint == "" or save_fingerprint ~= profile_hash then
        return false -- Fingerprint mismatch or empty → start fresh
    end
    -- Per-character guard: a save written by another character must never drive this
    -- one's route position. When the current character is known, the save must name the
    -- SAME character — a legacy save with no character field is equally untrusted, since
    -- it may belong to any character on the account. Only the offline harness (no player
    -- readable) accepts character-less saves.
    local me = self:_character_key()
    if me and decoded.character ~= me then
        self:_log_event("save_rejected_wrong_character", {
            save_character = decoded.character,
            current_character = me,
        })
        return false
    end
    -- Restore state
    if type(decoded.current_operation_idx) == "number" then
        self._current_operation_idx = decoded.current_operation_idx
    end
    if type(decoded.variables) == "table" then
        self._variables = decoded.variables
    end

    -- v2 fields (T18) — restore with nil-safe defaults for v1 saves
    if decoded.version == 2 then
        if type(decoded.current_action_idx) == "number" then
            self._current_action_idx = decoded.current_action_idx
        end
        if type(decoded.completed_quests) == "table" then
            self._completed_quests = decoded.completed_quests
        end
        if type(decoded.temporary_variables) == "table" then
            self._temporary_variables = decoded.temporary_variables
        end
        if type(decoded.visited_vendors) == "table" then
            self._visited_vendors = decoded.visited_vendors
        end
        if type(decoded.known_flight_paths) == "table" then
            self._known_flight_paths = decoded.known_flight_paths
        end
        if decoded.known_hearth_location ~= nil then
            self._known_hearth_location = decoded.known_hearth_location
        end
        if type(decoded.execution_history) == "table" then
            self._execution_log = decoded.execution_history
            local last = self._execution_log[#self._execution_log]
            self._log_total = (last and last.seq) or #self._execution_log
        end
    end

    -- Always resume at the START of the restored operation, never mid-operation.
    --
    -- Actions are ordered Travel-then-work, so restoring a mid-operation action index drops the
    -- character straight onto (say) a Kill while standing wherever the last session left them —
    -- observed live: resumed at op 16 action 18 (a Kill) while physically at op 1's location, then
    -- sat there because no target was in range. Re-running the leading Travels is cheap: an
    -- already-satisfied Travel returns success immediately.
    self._current_action_idx = 1

    self._dirty = false
    self:_log_event("save_restored", {
        operation = self._current_operation_idx,
        variable_count = 0, -- table len unreliable for dict
        save_version = decoded.version or 1,
    })
    return true
end

--- Minimal Lua table serialization (compatible with load() parser).
--- Outputs Lua-like table literals that can be parsed by load("return ...").
function RuntimeProfile:_serialize_lua(t)
    if t == nil then return "nil" end
    if type(t) == "number" then return tostring(t) end
    if type(t) == "string" then return '"' .. t:gsub('"', '\\"') .. '"' end
    if type(t) == "boolean" then return t and "true" or "false" end
    if type(t) ~= "table" then return '"' .. tostring(t) .. '"' end
    -- Check if array-like (consecutive numeric keys starting at 1)
    local is_array = true
    local max_key = 0
    local count = 0
    for k, _ in pairs(t) do
        count = count + 1
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            is_array = false
            break
        end
        if k > max_key then max_key = k end
    end
    if is_array and max_key == count then
        local parts = {}
        for i = 1, max_key do
            parts[i] = self:_serialize_lua(t[i])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    -- Table with mixed/string keys
    local parts = {}
    for k, v in pairs(t) do
        local key_str = type(k) == "string"
            and '["' .. k:gsub('"', '\\"') .. '"]'
            or "[" .. tostring(k) .. "]"
        parts[#parts + 1] = key_str .. "=" .. self:_serialize_lua(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function RuntimeProfile:load()
    if core and core.read_data_file then
        local json, err = core.read_data_file(self._json_path)
        if not json then
            return nil, err or "file not found"
        end
        local decoded = json_parse(json)
        if not decoded then
            return nil, "profile JSON could not be parsed"
        end
        -- Two producers write this file now: the compiler (RuntimeProfile) and the resolver
        -- (ExecutionPlan, ADR 09a §1.4). Normalizing here means the branch lives at the ONE place
        -- a plan enters the runtime; everything past this line sees a single operation shape.
        self._profile = ExecutionPlan.is_plan(decoded) and ExecutionPlan.normalize(decoded) or decoded

        -- T17 — Initialize variables from profile defaults
        self._variables = {}
        if self._profile.variables then
            for _, v in ipairs(self._profile.variables) do
                self._variables[v.name] = v.default_value or 0
            end
        end

        -- W5.2 — Attempt to restore execution state from save file
        -- (restored values override default initializations)
        local restored = self:_load_save()
        if restored then
            self:_log_event("load_with_save", {
                operation = self._current_operation_idx,
            })
        else
            self:_log_event("load_fresh", {})
        end

        -- ADR 06 §8.1 route reconciliation: the game's per-character quest flags decide
        -- WHERE WE ARE; the save is at best a hint. Forward jumps are always taken; a
        -- certain verdict (ready turn-in) overrides the save even backwards — see
        -- _apply_reconciliation.
        local reconciled, certain, certain_idx = self:_reconcile_start_operation()
        self:_apply_reconciliation(reconciled, certain, certain_idx)

        return true
    end
    return nil, "no data file API"
end

--- The live client returns NUMBERS for quest-log flags (is_complete = 1, not true) —
--- verified in-game 2026-07-23 on `get_quest_log_title`. `== true` silently missed every
--- complete quest, and a bare truthiness check is equally wrong the other way: 0 is
--- truthy in Lua, so an incomplete quest would read as complete.
local function quest_flag(v)
    return v == true or v == 1
end

--- Is this quest sitting in the log with all objectives complete (ready to turn in)?
--- info.is_complete is the client's own verdict — reconcile, never count (ADR 06 §8.1).
local function quest_ready_in_log(quest_id)
    if not (core and core.quests and core.quests.get_num_quest_log_entries
        and core.quests.get_quest_log_title) then
        return false
    end
    local num = core.quests.get_num_quest_log_entries() or 0
    for i = 1, num do
        local ok, info = pcall(core.quests.get_quest_log_title, i)
        if ok and info and not info.is_header and info.quest_id == quest_id then
            return quest_flag(info.is_complete)
        end
    end
    return false
end

--- Classify one operation's observable quest work against LIVE game state.
--- The server persists quest flags per character across sessions, so these answers are
--- trustworthy for any character at any time (ADR 06 §8.1: reconcile, don't count).
---
--- Returns:
---   "satisfied"    — has quest work and ALL of it is done (accept: active or rewarded;
---                    turn-in: rewarded). Kill/Loot/etc. riding in the same operation are
---                    considered served by those quests and do not block.
---   "ready"        — every quest item is either done OR is a turn-in whose quest sits in
---                    the log with all objectives complete. The kills BEFORE this op are
---                    proven done; only the turn-in itself remains, so the route position
---                    is THIS op, not past it. (Live-caught: quest 7 was 8/8 kobolds but
---                    unrewarded, and the bot walked back to the kobold camp anyway.)
---   "unsatisfied"  — has quest work that is provably not done yet.
---   "unobservable" — no quest work to check (travel/kill/comment-only operation), or the
---                    quest APIs are unavailable.
function RuntimeProfile:_op_quest_status(op)
    if not (core and core.quests and core.quests.is_quest_flagged_completed) then
        return "unobservable"
    end
    local rewarded = core.quests.is_quest_flagged_completed
    local on_quest = core.quests.is_on_quest

    local saw_quest_work = false
    local ready_turnin = false
    local ctx = nil
    for _, a in ipairs(op.actions or {}) do
        local p = a.payload or {}

        -- CL4 class guards: an accept/turn-in gated to ANOTHER class is not this
        -- character's work and must never mark the operation unsatisfied — the Marshal
        -- McBride op carries six class-guarded accepts of which exactly one applies.
        local guard_met = true
        if a.guard then
            ctx = ctx or self:create_context()
            local ok_g, met = pcall(RuntimeAction.evaluate_condition, ctx, a.guard)
            guard_met = ok_g and met == true
        end

        if guard_met and a.type == "AcceptQuest" and p.quest_id ~= nil then
            saw_quest_work = true
            local ok_r, done = pcall(rewarded, p.quest_id)
            local ok_o, active = false, false
            if on_quest then ok_o, active = pcall(on_quest, p.quest_id) end
            -- Not yet accepted and not yet rewarded ⇒ there is real work here. The second
            -- return distinguishes a MISSED ACCEPT (observable, doable right now) from a
            -- turn-in whose kills may still be pending — only the former justifies
            -- rewinding a route that already moved past it.
            if not ((ok_r and done) or (ok_o and active)) then return "unsatisfied", true end
        elseif guard_met and a.type == "TurnInQuest" and p.quest_id ~= nil then
            saw_quest_work = true
            local ok_r, done = pcall(rewarded, p.quest_id)
            if not (ok_r and done) then
                if quest_ready_in_log(p.quest_id) then
                    ready_turnin = true
                else
                    return "unsatisfied", false
                end
            end
        end
    end
    if ready_turnin then return "ready" end
    return saw_quest_work and "satisfied" or "unobservable"
end

--- Is every piece of quest work in this operation already satisfied?
--- Used as the per-tick skip check before an operation's first action runs. Operations
--- without quest work are never "already done" — nothing here can observe kill-only or
--- travel-only progress, and wrongly skipping a step breaks the route while wrongly doing
--- one only costs time.
function RuntimeProfile:_operation_already_done(op)
    return self:_op_quest_status(op) == "satisfied"
end

--- An ObjectiveComplete gate for a quest the player NEITHER has active NOR has completed is
--- MOOT: the kills behind it serve a quest that isn't in the log, so the op can never make
--- progress and must be skipped rather than ground forever (live-caught: after finishing
--- Skirmish at Echo Ridge, reconciliation routed to a kill op gated on quest 6 — which the
--- character never accepted — and the bot kept killing entry 103 for a quest it could not
--- progress). Guides are linear (accept precedes kill), so "at a kill op without the quest"
--- means the quest was skipped/class-guarded, never that its accept is still ahead. Only
--- ObjectiveComplete gates can be moot; LevelAtLeast and the like are always relevant.
function RuntimeProfile:_objective_gate_moot(condition)
    if type(condition) ~= "table" or condition.type ~= "ObjectiveComplete" then
        return false
    end
    local quest_id = type(condition.payload) == "table" and condition.payload[1] or nil
    if not quest_id then return false end
    -- Mootness can only be judged against a live quest API. Without BOTH checks available
    -- and answering, default to NOT moot — never skip an op on missing information (the
    -- offline harness has no core.quests, and a cold API read must not fake "never took it").
    if not (core and core.quests and core.quests.is_on_quest
        and core.quests.is_quest_flagged_completed) then
        return false
    end
    local ok_on, on = pcall(core.quests.is_on_quest, quest_id)
    if ok_on and on == true then return false end -- active → not moot
    local ok_done, done = pcall(core.quests.is_quest_flagged_completed, quest_id)
    if ok_done and done == true then return false end -- rewarded → handled by the met path
    -- Only declare moot when BOTH reads succeeded and both were false.
    return ok_on and ok_done
end

--- The inverse of _operation_gate_already_met: a farm operation whose Completion gate
--- evaluates FALSE is provably PENDING — e.g. a kill op sitting at 3/10 that a failure
--- cascade or wait-timeout advanced past (live-caught: nav/combat deadlock churned op 24
--- forward with quest 15 unfinished, and the save then resumed at op 25). Quest-action
--- ops are excluded — they have their own classification.
function RuntimeProfile:_operation_gate_unmet(op, ctx)
    local saw_farm = false
    local saw_gate_unmet = false
    for _, a in ipairs(op.actions or {}) do
        if a.type == "AcceptQuest" or a.type == "TurnInQuest" then
            return false
        elseif a.type == "Kill" or a.type == "Grind" or a.type == "Loot" or a.type == "UseItem" then
            saw_farm = true
        elseif a.type == "Condition" then
            local p = a.payload or {}
            if p.role == "Completion" and p.condition then
                local ok, met = pcall(RuntimeAction.evaluate_condition, ctx, p.condition)
                -- A moot gate (quest the player never took) is NOT provably-pending — the op
                -- is skippable, not a rewind target.
                if not (ok and met == true) and not self:_objective_gate_moot(p.condition) then
                    saw_gate_unmet = true
                end
            end
        end
    end
    return saw_farm and saw_gate_unmet
end

--- Is this operation's own Completion gate ALREADY met before any of its actions ran?
---
--- Kill operations are compiled as Travel + Kill(quantity) + Condition(ObjectiveComplete).
--- The Kill action counts its own corpses from zero every session, so on a resume it
--- hunts the full quantity again even when the quest objective is already complete — and
--- the gate behind it never gets evaluated, because Kill holds "waiting" until ITS count
--- is satisfied (live-caught: the bot re-farmed wolves for a quest sitting at 8/8).
--- The objective state in the quest log is the real source of truth (ADR 06 §8.1), so:
--- if the operation carries at least one Completion-role gate, contains no quest
--- accept/turn-in actions (those have their own skip logic), and EVERY Completion gate
--- already evaluates true, the whole operation is done — skip it without moving.
function RuntimeProfile:_operation_gate_already_met(op, ctx)
    local saw_gate = false
    local saw_farm_work = false
    for _, a in ipairs(op.actions or {}) do
        if a.type == "AcceptQuest" or a.type == "TurnInQuest" then
            return false
        elseif a.type == "Kill" or a.type == "Grind" or a.type == "Loot" or a.type == "UseItem" then
            -- The re-farm problem only exists for work counted by zeroed local state.
            saw_farm_work = true
        elseif a.type == "Condition" then
            local p = a.payload or {}
            if p.role == "Completion" and p.condition then
                saw_gate = true
                local ok, met = pcall(RuntimeAction.evaluate_condition, ctx, p.condition)
                if not (ok and met == true) then
                    -- Unmet — but a gate for a quest the player never took is moot, and the
                    -- op should be skipped rather than farmed forever.
                    if not self:_objective_gate_moot(p.condition) then
                        return false
                    end
                end
            end
        end
    end
    -- Condition-only operations keep their normal per-action flow (their gates are
    -- cheap to evaluate in place); the skip exists to avoid REDOING expensive work.
    return saw_gate and saw_farm_work
end

--- Derive the starting operation from the character's REAL quest state instead of
--- trusting a save file. Guides are linear, so quest anchors dominate: an operation whose
--- Accept/TurnIn work is all satisfied proves every earlier operation done, and
--- unobservable operations (travel/kill-only) between two satisfied anchors ride along.
--- The scan stops at the first provably-unsatisfied anchor because unobservable work
--- before it (e.g. kills for that not-yet-turned-in quest) may still be needed.
---
--- This is what makes a relog — or a DIFFERENT character — land on the right step with no
--- save file at all: the server's per-character quest flags are the source of truth.
--- Returns (start_idx, certain). `certain` is true when the scan stopped AT a ready
--- turn-in: that is observable, mandatory pending work (a log-complete quest waiting to
--- be handed in), strong enough to override a save file even BACKWARDS — a save can
--- legitimately be ahead of what flags prove (kill-only progress is unobservable), but a
--- save that advanced past a failed turn-in is simply wrong, and the route would
--- otherwise never come back for the quest (live-caught: turn-in of quest 7 exhausted
--- its retries, the save recorded op 7, and the restart resumed there instead of at the
--- op-4 turn-in). A stop at an unsatisfied anchor stays uncertain: kills before it may
--- or may not be done, so the save keeps forward precedence there.
--- Returns (start_idx, certain, certain_idx).
--- start_idx: conservative forward position (first op not provably done).
--- certain + certain_idx: an op that is OBSERVABLY pending right now — a ready turn-in
--- or a missed accept — strong enough to rewind a route that already moved past it.
--- certain_idx can be LATER than start_idx (a missed accept sitting past unobservable
--- kills): forward movement uses start_idx, backward correction uses certain_idx, so an
--- accept verdict can never skip the kills in between.
function RuntimeProfile:_reconcile_start_operation()
    local operations = (self._profile and self._profile.operations) or {}
    local start_idx = 1
    local certain = false
    local certain_idx = nil
    local gate_ctx = nil
    for i, op in ipairs(operations) do
        local status, missed_accept = self:_op_quest_status(op)
        if status == "satisfied" then
            start_idx = i + 1
        elseif status == "ready" then
            -- The work feeding this turn-in is done; the turn-in itself is not.
            -- Jump straight TO this operation (skipping the kill ops before it).
            start_idx = i
            certain = true
            certain_idx = i
            break
        elseif status == "unsatisfied" then
            -- A missed accept (quest never taken, guard met) is observable pending work:
            -- if the route already moved past it, it must come back — live-caught as
            -- Accept 15 exhausting retries and the bot walking away with an empty log.
            if missed_accept then
                certain = true
                certain_idx = i
            end
            break
        else
            -- "unobservable" quest-wise — but farm ops carry their own truth in their
            -- Completion gate: met ⇒ proven done, advance past; unmet ⇒ provably
            -- pending (kill op at 3/10), a certain rewind target for a save that
            -- advanced past it.
            gate_ctx = gate_ctx or self:create_context()
            if self:_operation_gate_already_met(op, gate_ctx) then
                start_idx = i + 1
            elseif self:_operation_gate_unmet(op, gate_ctx) then
                certain = true
                certain_idx = i
                break
            end
        end
    end
    return start_idx, certain, certain_idx
end

--- Apply a reconciliation verdict to the current route position. Forward jumps are always
--- taken. Backward jumps are taken only when `certain` (a ready turn-in) and at most ONCE
--- per target operation per session — if the turn-in genuinely cannot complete (NPC gone,
--- bugged quest), the rewind guard stops an infinite advance→rewind loop.
function RuntimeProfile:_apply_reconciliation(reconciled, certain, certain_idx)
    local current = self._current_operation_idx
    if reconciled > current then
        self:_log_event("route_reconciled", {
            from_operation = current,
            to_operation = reconciled,
        })
        self._current_operation_idx = reconciled
        self._current_action_idx = 1
        return true
    end
    -- Backward correction targets certain_idx (the observably-pending op), NOT start_idx:
    -- for a missed accept the two differ, and rewinding to start_idx would redo the
    -- unobservable kill stretch in between for nothing.
    local rewind_to = certain and (certain_idx or reconciled) or nil
    if rewind_to and rewind_to < current then
        self._rewound_ops = self._rewound_ops or {}
        if not self._rewound_ops[rewind_to] then
            self._rewound_ops[rewind_to] = true
            self:_log_event("route_rewound", {
                from_operation = current,
                to_operation = rewind_to,
            })
            self._current_operation_idx = rewind_to
            self._current_action_idx = 1
            return true
        end
    end
    return false
end

-- ============================================================================
-- F3: context methods, defined ONCE at module load (shared prototype)
-- ============================================================================
-- These used to be defined INSIDE create_context() as `function ctx:method() end`
-- closures, which meant every call to create_context() (once or twice per tick, see
-- below) allocated ~20 fresh function objects — per-tick garbage on the hot path, purely
-- from method definitions that never actually vary between calls. None of them close over
-- the RuntimeProfile instance (they only ever touch their own `self`, i.e. the ctx table),
-- so they can be shared via a metatable __index instead of rebuilt every time.
local ContextMethods = {}
ContextMethods.__index = ContextMethods

-- ====================================================================
-- Navigation helpers (W3.1, W3.2, W3.3)
-- ====================================================================

--- Resolve player's current position.
--- Returns {x, y, z} table or nil.
function ContextMethods:_get_player_pos()
    if core and core.object_manager and core.object_manager.get_local_player then
        local player = core.object_manager.get_local_player()
        if player and player.get_position then
            local ok, pos = pcall(player.get_position, player)
            if ok and type(pos) == "table" then
                return pos
            end
        end
    end
    return nil
end

--- Check if a specific NPC entry is within interaction range.
--- @param entry number|string NPC ID
--- @param range number Override distance (default INTERACT_RANGE)
--- @return boolean
function ContextMethods:is_at_npc(entry, range)
    range = range or INTERACT_RANGE
    -- Use UnitHelper to find creature (Sylvannas API compliant)
    local npc = UnitHelper.get_nearest_creature({ entry })
    if npc and npc:is_valid() then
        -- Try precise distance check
        local player_pos = self:_get_player_pos()
        if player_pos and npc.get_position then
            local ok, npc_pos = pcall(npc.get_position, npc)
            if ok and npc_pos then
                return Geometry.distance(player_pos, npc_pos) <= range
            end
        end
        -- A10: get_nearest_creature scans the FULL visible range (get_all_objects), not just
        -- nearby — an NPC found here can be ~90yd away. Without an actual distance check
        -- there is no basis to claim "at" the NPC, so this must fail closed (routes callers
        -- to "blocked" -> navigate) instead of failing open into a doomed interaction retry.
        return false
    end
    return false
end

--- Check if a specific game object entry is within loot range.
--- @param entry number|string Object ID
--- @param range number Override distance (default LOOT_RANGE)
--- @return boolean
function ContextMethods:is_at_object(entry, range)
    range = range or LOOT_RANGE
    -- Use UnitHelper to find game object (Sylvannas API compliant)
    local obj = UnitHelper.get_nearest_game_object({ entry })
    if obj and obj:is_valid() then
        local player_pos = self:_get_player_pos()
        if player_pos and obj.get_position then
            local ok, obj_pos = pcall(obj.get_position, obj)
            if ok and obj_pos then
                return Geometry.distance(player_pos, obj_pos) <= range
            end
        end
        return true
    end
    return false
end

--- Check if player is at a destination position.
--- Accepts {x, y, z} table or a zone name string (resolved via get_zone_waypoint).
--- @param dest table|string Position or zone name
--- @param tolerance number Yards (default ARRIVAL_TOLERANCE)
--- @return boolean
function ContextMethods:is_at_destination(dest, tolerance)
    tolerance = tolerance or ARRIVAL_TOLERANCE
    local target_pos = dest
    if type(dest) == "string" then
        target_pos = self:get_zone_waypoint(dest)
        if not target_pos then
            return false -- Can't resolve zone to a position
        end
    end
    if type(target_pos) ~= "table" then
        return false
    end
    local player_pos = self:_get_player_pos()
    if not player_pos then
        return false
    end
    local dist = Geometry.distance(player_pos, target_pos)
    return dist <= tolerance
end

--- Resolve a zone name to a waypoint position.
--- Returns {x, y, z} or nil.
function ContextMethods:get_zone_waypoint(zone_name)
    -- Attempt to resolve via QueryServer
    if self.query and self.query.resolve_zone then
        local ok, result = pcall(self.query.resolve_zone, self.query, zone_name)
        if ok and type(result) == "table" then
            return result
        end
    end
    -- Fallback: check hardcoded zone centroids (small set of common zones)
    local zone_centroids = {
        ["Elwynn Forest"] = { x = -8949.95, y = -132.49, z = 83.53 },
        ["Dun Morogh"]    = { x = -5401.32, y = -2403.51, z = 400.09 },
        ["Teldrassil"]    = { x = 9947.52, y = 2054.02, z = 1329.63 },
        ["Mulgore"]       = { x = -2237.03, y = -438.46, z = -5.74 },
        ["Tirisfal Glades"] = { x = 1810.12, y = 227.96, z = -8.99 },
        ["Durotar"]       = { x = 259.65, y = -4749.60, z = 10.97 },
    }
    local centroid = zone_centroids[zone_name]
    if centroid then
        return { x = centroid.x, y = centroid.y, z = centroid.z }
    end
    return nil
end

-- ====================================================================
-- Quest log tracking (W2.3, W2.4)
-- ====================================================================

--- Refresh the quest log caches from Sylvannas APIs.
--- Called automatically on first access; can be called manually to force.
function ContextMethods:_refresh_quest_log()
    self._completed_quests = {}
    self._active_quests = {}

    -- Use core.quests.is_quest_flagged_completed for completed quests (Sylvannas API)
    if core and core.quests and core.quests.get_num_quest_log_entries then
        local num_entries = core.quests.get_num_quest_log_entries()
        for i = 1, num_entries do
            local info = core.quests.get_quest_log_title(i)
            if info and not info.is_header then
                if quest_flag(info.is_complete) then
                    self._completed_quests[tostring(info.quest_id)] = true
                else
                    self._active_quests[tostring(info.quest_id)] = true
                end
            end
        end
    end

    self._quest_log_dirty = false
end

function ContextMethods:is_quest_completed(quest_entry)
    -- A REWARDED quest stays "completed" after it leaves the log, but the log-derived
    -- _completed_quests cache below only knows quests still IN the log -- so it answered false
    -- for any turned-in quest, and the QuestCompleted / QuestRewarded gate handlers route
    -- through here (live symptom: "keeps going to wolves when we've long completed that quest").
    -- Consult the rewarded flag first, mirroring is_objective_complete.
    if core and core.quests and core.quests.is_quest_flagged_completed then
        local ok, done = pcall(core.quests.is_quest_flagged_completed, quest_entry)
        if ok and done == true then
            return true
        end
    end
    if self._quest_log_dirty then
        self:_refresh_quest_log()
    end
    return self._completed_quests[tostring(quest_entry)] == true
end

function ContextMethods:is_quest_active(quest_entry)
    if self._quest_log_dirty then
        self:_refresh_quest_log()
    end
    -- Also directly check Sylvannas API for active quests
    if core and core.quests and core.quests.is_on_quest then
        local ok, is_on = pcall(core.quests.is_on_quest, quest_entry)
        if ok and is_on then
            return true
        end
    end
    return self._active_quests[tostring(quest_entry)] == true
end

function ContextMethods:is_objective_complete(quest_entry, objective_idx)
    -- A REWARDED quest's objectives are trivially complete. Without this, kill operations
    -- gated on an already-turned-in quest re-farm forever: the quest is no longer in the
    -- log, so the leader-board walk below finds nothing and the old fallback (log-complete
    -- cache) said false — live-caught as "killing wolves with an empty quest log" (op 17
    -- gated on ObjectiveComplete for rewarded quest 7).
    if core and core.quests and core.quests.is_quest_flagged_completed then
        local ok, done = pcall(core.quests.is_quest_flagged_completed, quest_entry)
        if ok and done == true then
            return true
        end
    end
    -- Use core.quests.get_num_quest_leader_boards and get_quest_log_leader_board (Sylvannas API)
    if core and core.quests and core.quests.get_num_quest_leader_boards then
        -- Find quest log index for this quest
        if self._quest_log_dirty then
            self:_refresh_quest_log()
        end
        -- Try to find quest by ID in our cached log
        local num_entries = core.quests.get_num_quest_log_entries()
        for i = 1, num_entries do
            local info = core.quests.get_quest_log_title(i)
            if info and info.quest_id == quest_entry then
                local num_obj = core.quests.get_num_quest_leader_boards(i)
                if objective_idx <= num_obj then
                    -- Sylvannas returns a TABLE, not a string:
                    --   { objective_type = "item",
                    --     description = "Tough Wolf Meat: 0/8",
                    --     is_completed = false }
                    local board = core.quests.get_quest_log_leader_board(objective_idx, i)
                    if type(board) ~= "table" then
                        return false
                    end
                    -- is_completed is the client's own verdict — reconcile,
                    -- never count (ADR 06 §8.1). Trust it when it says done.
                    if quest_flag(board.is_completed) then
                        return true
                    end
                    -- Otherwise derive from the "Name: cur/need" counter. Note
                    -- there are NO parentheses in the live format.
                    local description = board.description
                    if type(description) == "string" then
                        local cur, max = string.match(description, "(%d+)%s*/%s*(%d+)")
                        if cur and tonumber(max) and tonumber(max) > 0 then
                            return tonumber(cur) >= tonumber(max)
                        end
                    end
                    return false
                end
                break
            end
        end
    end
    -- Fallback: check if quest is completed
    return self:is_quest_completed(quest_entry)
end

-- ====================================================================
-- Player stats facade (W2.5) - Sylvannas API compliant
-- ====================================================================

function ContextMethods:get_player_level()
    -- Use get_local_player():get_level() (Sylvannas API)
    local player = UnitHelper.get_local_player()
    if player and player.get_level then
        local ok, level = pcall(player.get_level, player)
        if ok and tonumber(level) then
            return level
        end
    end
    return 1
end

function ContextMethods:get_player_xp()
    -- unit:get_xp() (game-object.md): current experience points toward the next level.
    -- nil when the API (or a test mock) does not expose it — callers must treat nil as
    -- "no XP signal", never as zero.
    local player = UnitHelper.get_local_player()
    if player and player.get_xp then
        local ok, xp = pcall(player.get_xp, player)
        if ok and tonumber(xp) then
            return tonumber(xp)
        end
    end
    return nil
end

function ContextMethods:get_player_faction()
    -- Faction is NOT directly readable (ADR 07 §9 item 17) — but race is, and race determines
    -- faction by a static ten-entry map (shared/race_faction.lua). nil when the player object or
    -- race id is unavailable; callers must treat nil as "unknown", never default a side.
    local RaceFaction = require("shared/race_faction")
    local player = UnitHelper.get_local_player()
    if player and player.get_race_id then
        local ok, race = pcall(player.get_race_id, player)
        if ok then
            return RaceFaction.resolve(race)
        end
    end
    return nil
end

function ContextMethods:get_player_class()
    -- get_local_player():get_class() returns a numeric class_id (Sylvannas API);
    -- map it to the Title-Case class name that ClassIs conditions compare against.
    local player = UnitHelper.get_local_player()
    if player and player.get_class then
        local ok, class = pcall(player.get_class, player)
        if ok and class ~= nil then
            if type(class) == "number" then
                return CLASS_ID_TO_NAME[class] or "Unknown"
            end
            -- Defensive: some builds/mocks may already return a name string.
            return class
        end
    end
    return "Unknown"
end

function ContextMethods:get_player_race()
    -- Use get_local_player():get_race() (Sylvannas API)
    local player = UnitHelper.get_local_player()
    if player and player.get_race then
        local ok, race = pcall(player.get_race, player)
        if ok and race then
            return race
        end
    end
    return "Unknown"
end

function ContextMethods:get_player_faction()
    -- Fallback: derive from race
    local race = self:get_player_race()
    local alliance_races = { Human = true, Dwarf = true, NightElf = true, Gnome = true, Draenei = true }
    local horde_races = { Orc = true, Undead = true, Tauren = true, Troll = true, BloodElf = true }
    if alliance_races[race] then return "Alliance" end
    if horde_races[race] then return "Horde" end
    return "Neutral"
end

-- ====================================================================
-- Inventory facade (W2.5) - Sylvannas API compliant
-- ====================================================================

function ContextMethods:get_item_count(item_entry)
    -- Check player's equipped items for item count (Sylvannas API)
    local player = UnitHelper.get_local_player()
    if player and player.get_equipped_items then
        local ok, items = pcall(player.get_equipped_items, player)
        if ok and items then
            local count = 0
            for _, slot_info in ipairs(items) do
                if slot_info.object and slot_info.object.get_item_id then
                    local ok2, id = pcall(slot_info.object.get_item_id, slot_info.object)
                    if ok2 and tostring(id) == tostring(item_entry) then
                        count = count + 1
                    end
                end
            end
            return count
        end
    end
    -- Check bags for item count
    if core and core.inventory and core.inventory.get_items_in_bag then
        -- A2: docs/SylvannasAPI/dev/api/core.md:990 documents get_items_in_bag(id: integer)
        -- with NO self/method-call convention. Passing core.inventory as a leading arg put
        -- it in the `id` parameter and dropped bag_id, so bag item counts were always 0 and
        -- HasItem/ItemCountAtLeast blocked for the full MAX_CONDITION_WAIT.
        for bag_id = 0, 4 do
            local ok, items = pcall(core.inventory.get_items_in_bag, bag_id)
            if ok and items then
                for _, slot_info in ipairs(items) do
                    if slot_info.object and slot_info.object.get_item_id then
                        local ok2, id = pcall(slot_info.object.get_item_id, slot_info.object)
                        if ok2 and tostring(id) == tostring(item_entry) then
                            return 1
                        end
                    end
                end
            end
        end
    end
    return 0
end

function ContextMethods:get_money()
    -- Use core.inventory.get_gold() (Sylvannas API)
    if core and core.inventory and core.inventory.get_gold then
        local ok, copper = pcall(core.inventory.get_gold, core.inventory)
        if ok and tonumber(copper) then
            return copper
        end
    end
    return 0
end

-- ====================================================================
-- Skill / Reputation / Cooldown facade (W2.5) - Sylvannas API compliant
-- ====================================================================

function ContextMethods:get_skill_level(skill_name)
    -- Sylvannas doesn't have a direct skill level API, return 0
    return 0
end

function ContextMethods:is_item_ready(item_entry)
    -- Use object's get_item_cooldown method (Sylvannas API)
    local player = UnitHelper.get_local_player()
    if player and player.get_item_cooldown then
        local ok, cd = pcall(player.get_item_cooldown, player, item_entry)
        if ok and cd and tonumber(cd) and cd > 0 then
            return false
        end
    end
    return true -- Assume ready if no API or no cooldown
end

function ContextMethods:get_reputation(faction_id)
    -- Sylvannas doesn't have a direct reputation getter in core.quests
    -- Would need to use quest APIs or return 0
    return 0
end

--- Build (or refresh) this profile's execution context.
---
--- F3: this used to allocate a brand-new ctx table AND ~20 fresh method closures on every
--- call — once per tick from `_execute_running`/`_execute_dry_run`/`_confirm_nav_arrival`, and
--- a SECOND time in the same tick from `_resolve_nav_target`'s zone-destination branch when
--- called via `_handle_blocked`. The closures are now a shared prototype (`ContextMethods`,
--- above) attached once via metatable. The ctx table itself is now cached on the profile
--- instance (`self._ctx`) and reused across calls — only the fields that can legitimately
--- change are refreshed on each call:
---   - `persist` semantics are UNCHANGED: still `self._action_state`, lazily created once and
---     never replaced, so action state (e.g. kill tallies, in-flight chase target) still
---     survives across every call exactly as before.
---   - the quest-log cache (`_completed_quests`/`_active_quests`/`_quest_log_dirty`) is reset
---     to force a fresh `_refresh_quest_log()` on first access THIS call, preserving the
---     original "refresh at most once per execution" behavior.
function RuntimeProfile:create_context()
    self._action_state = self._action_state or { kill_counts = {} }

    local ctx = self._ctx
    if not ctx then
        ctx = setmetatable({}, ContextMethods)
        self._ctx = ctx
    end

    ctx.variables = self._variables
    ctx.query = self._query
    ctx.nav = self._nav                 -- W3.3: NavAdapter for movement
    -- Shared app bus, so a Kill action can request engagement from the combat module.
    ctx.event_bus = self._event_bus
    ctx.blackboard = self._blackboard
    -- Action state that must SURVIVE context recreation/reuse (see docstring above).
    ctx.persist = self._action_state

    -- Quest log tracking caches (W2.3, W2.4) — reset every call so a stale answer from a
    -- previous tick is never reused; _refresh_quest_log() lazily repopulates on first access.
    ctx._completed_quests = {}  -- { [quest_entry] = true }
    ctx._active_quests = {}     -- { [quest_entry] = true }
    ctx._quest_log_dirty = true -- refresh on next query

    return ctx
end

-- ============================================================================
-- Hot reload (T16)
-- ============================================================================

--- Get a change-detection signature for the profile JSON file.
--- A11: core.get_file_info is not a documented Sylvannas API and lfs is absent from the
--- sandbox — both branches were always nil in-game, so hot reload was dead everywhere except
--- the offline harness (which stubs core.get_file_info). Fall back to the one real,
--- sandbox-viable API: read the file's raw text via core.read_data_file (already used by
--- :load()/:_check_hot_reload()) and hash its content. Returns a change signature, not a real
--- timestamp — the caller (_check_hot_reload) must compare it for INEQUALITY, not ordering.
function RuntimeProfile:_get_file_mtime()
    if core and core.get_file_info then
        local ok, info = pcall(core.get_file_info, self._json_path)
        if ok and info and info.mtime then
            return info.mtime
        end
    end
    if core and core.read_data_file then
        local ok, text = pcall(core.read_data_file, self._json_path)
        if ok and type(text) == "string" then
            -- Cheap, deterministic checksum — sampled, not a full scan, so this stays cheap on
            -- large profiles while still catching any byte change.
            local hash = #text
            for i = 1, #text, 37 do
                hash = (hash * 31 + text:byte(i)) % 2147483647
            end
            return hash
        end
    end
    -- Fallback: LuaFileSystem if available (not present in the Sylvannas sandbox; kept for
    -- non-sandbox test/dev environments that do have it).
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.attributes then
        local attr = lfs.attributes(self._json_path)
        if attr and attr.modification then
            return attr.modification
        end
    end
    return nil
end

--- Check profile JSON for changes and hot-reload if detected.
--- Guard: only when state is "running".
--- On change: validate content_hash, swap profile preserving _variables.
function RuntimeProfile:_check_hot_reload()
    if self._dry_run then return end
    if self._state ~= "running" then return end

    -- _get_file_mtime reads and hashes the whole profile JSON — far too heavy for every
    -- tick. A 5s poll still catches an edited profile within human reaction time.
    local now = (core and core.time and core.time()) or 0
    if self._last_reload_check and (now - self._last_reload_check) < RELOAD_CHECK_INTERVAL then
        return
    end
    self._last_reload_check = now

    local mtime = self:_get_file_mtime()
    if not mtime then return end

    -- First check or signature unchanged? (A11: _get_file_mtime may now return a content
    -- checksum rather than a real timestamp, so compare for inequality, not ordering.)
    if self._json_mtime and mtime == self._json_mtime then return end

    -- Read file
    local json, err = core.read_data_file and core.read_data_file(self._json_path)
    if not json then
        self._json_mtime = mtime -- Update so we don't retry every tick
        return
    end

    local decoded = json_parse(json)
    if not decoded or type(decoded) ~= "table" then
        self._json_mtime = mtime
        return
    end

    -- Must have a content_hash to validate
    if not decoded.content_hash then
        self:_log_event("hot_reload_skip", { reason = "no content_hash" })
        self._json_mtime = mtime
        return
    end

    -- Same hash as already running? Update mtime cache only, skip
    if self._profile and self._profile.content_hash == decoded.content_hash then
        self._json_mtime = mtime
        return
    end

    -- Preserve current variables, swap profile, re-init with defaults
    local saved_variables = self._variables
    -- Hot reload is a load path, so it needs the same normalization :load() does. Without it an
    -- edited plan swaps in with raw 0-based `to_index` values and every branch lands one
    -- operation early — with the suite green, because nothing else reads that field.
    self._profile = ExecutionPlan.is_plan(decoded) and ExecutionPlan.normalize(decoded) or decoded

    -- Re-initialize variables from new profile defaults
    self._variables = {}
    if self._profile.variables then
        for _, v in ipairs(self._profile.variables) do
            self._variables[v.name] = v.default_value or 0
        end
    end

    -- Restore preserved variable values where the key still exists
    for name, value in pairs(saved_variables) do
        if self._variables[name] ~= nil then
            self._variables[name] = value
        end
    end

    self._json_mtime = mtime
    self:_log_event("hot_reload", { hash = decoded.content_hash })
end

-- ============================================================================
-- Recovery state machine methods (Wave 4)
-- ============================================================================

--- Main entry point, called each tick.
--- Dispatches to the current state machine state.
--- When dry_run is true, simulates execution without calling real APIs.
function RuntimeProfile:execute(dry_run)
    if dry_run == true then
        self._dry_run = true
    end

    if not self._profile then
        return "error", "profile not loaded"
    end

    if self._dry_run then
        return self:_execute_dry_run()
    end

    -- T16 — Check for hot reload at start of each tick
    self:_check_hot_reload()

    -- Death detection runs before every state (W4.3)
    local dead = self:_is_player_dead()
    if dead and self._state ~= "ghost" then
        self:_log_event("death_detected", { state = self._state })
        -- Death-loop guard: rez-and-retry against the same lethal action repeated forever
        -- (live-caught). After MAX_DEATHS_PER_OPERATION deaths at one operation, abandon
        -- it — the route position advances now; ghost recovery still runs to rez.
        local op_idx = self._current_operation_idx
        self._deaths_at_op = self._deaths_at_op or {}
        self._deaths_at_op[op_idx] = (self._deaths_at_op[op_idx] or 0) + 1
        if self._deaths_at_op[op_idx] >= MAX_DEATHS_PER_OPERATION then
            self._deaths_at_op[op_idx] = nil
            self:_log_event("death_loop_abandon", {
                operation = op_idx,
                deaths = MAX_DEATHS_PER_OPERATION,
            })
            local operations = (self._profile and self._profile.operations) or {}
            self:_advance_operation(operations[op_idx])
            self._current_action_idx = 1
        end
        self._state = "ghost"
        self._ghost_start_time = (core and core.time and core.time()) or 0
        return "running", "player dead, entering ghost recovery"
    end

    if self._state == "running" then
        return self:_execute_running()
    elseif self._state == "navigating" then
        return self:_execute_navigating()
    elseif self._state == "ghost" then
        return self:_execute_ghost()
    elseif self._state == "failed" then
        return "error", "profile failed after " .. self._consecutive_failures .. " consecutive failures"
    elseif self._state == "finished" then
        return "finished", "completed all operations"
    end
    return "error", "unknown state: " .. tostring(self._state)
end

-- ====================================================================
-- Dry-run simulation (no real API calls, no navigation, no persistence)
-- ====================================================================

--- Execute the entire profile in dry-run mode.
--- Conditions are evaluated normally (read-only ctx methods are safe). All other actions are
--- simulated as "success". Navigation, saves, and hot reload are skipped.
---
--- Over an ExecutionPlan this WALKS THE GRAPH instead of iterating the array: it follows the same
--- edge guards `_advance_operation` follows, so what it reports is the route the bot would
--- actually take, not every operation the plan happens to contain. That is the point of the
--- edit-then-simulate loop ADR 09a moves into phase 1 — an author needs to see which branch their
--- character takes and where it stops, with no client, no QueryServer and no NavServer.
---
--- Pre-plan profiles keep the array iteration verbatim: there are no edges to follow.
--- @return string, string "finished" status and summary message.
function RuntimeProfile:_execute_dry_run()
    local operations = self._profile.operations or {}
    local results = {
        operations_count = #operations,
        estimated_duration_seconds = 0,
        blocked_operations = 0,
        failed_actions = 0,
        skipped_conditions = 0,
        -- Plan-era additions. Present for legacy profiles too (as zeros and a linear path) so a
        -- consumer never has to ask which producer wrote the file it is looking at.
        unmet_guards = 0,
        path = {},
        truncated = false,
    }

    local ctx = self:create_context()

    local function simulate_operation(op_idx, op)
        results.path[#results.path + 1] = { operation = op_idx, node_id = op.node_id }
        local op_actions_duration = 0

        for _, action in ipairs(op.actions or {}) do
            local action_type = action.type

            if action_type == "Condition" then
                local cond = action.payload and action.payload.condition
                local ok = cond and RuntimeAction.evaluate_condition(ctx, cond) or false
                if not ok then
                    results.skipped_conditions = results.skipped_conditions + 1
                end
            elseif action_type == "Comment" then
                -- No-op, zero cost
            elseif action_type == "SetVariable" then
                -- Safe to execute; doesn't call external APIs
                RuntimeAction.execute_set_variable(action.payload, ctx)
            elseif action_type == nil or action_type == "" then
                -- The resolver emits an operation with no actions rather than dropping a node,
                -- but an action with no TYPE is a lowering that produced garbage, and simulation
                -- is the only place an author sees it before the bot no-ops its way past it.
                results.failed_actions = results.failed_actions + 1
            else
                -- All real actions: simulate success (the action itself
                -- would trigger Sylvannas APIs, navigation, etc.)
                -- Estimate a nominal per-action cost for duration.
                op_actions_duration = op_actions_duration + 3.0
            end
        end

        results.estimated_duration_seconds = results.estimated_duration_seconds + op_actions_duration
    end

    if ExecutionPlan.has_transitions(self._profile) then
        local function evaluate(condition)
            return RuntimeAction.evaluate_condition(ctx, condition)
        end
        local idx = 1
        local steps = 0
        while operations[idx] do
            steps = steps + 1
            -- A DAG walk visits each node at most once, so exceeding the operation count proves a
            -- cycle. The resolver emits topological order and would not produce one, but this is
            -- the tool authors point at half-finished graphs, and a simulator that hangs reports
            -- nothing at all.
            if steps > #operations then
                results.truncated = true
                break
            end
            local op = operations[idx]
            simulate_operation(idx, op)
            local next_idx, outcome, detail = ExecutionPlan.select_transition(op, evaluate)
            results.unmet_guards = results.unmet_guards + ((detail and detail.unmet) or 0)
            if outcome == "dead_end" then
                results.blocked_operations = results.blocked_operations + 1
                break
            elseif outcome == "terminal" then
                break
            elseif outcome == "linear" then
                idx = idx + 1
            else
                idx = next_idx
            end
        end
    else
        for op_idx, op in ipairs(operations) do
            simulate_operation(op_idx, op)
        end
    end

    self._sim_result = results
    self._state = "finished"
    self._current_operation_idx = #operations + 1
    return "finished", "dry-run simulation complete: " .. #results.path .. " operations"
end

--- Run the full profile simulation in dry-run mode.
--- Resets state, runs through all operations, and returns a summary table.
--- @return table Summary with operations_count, estimated_duration_seconds,
---         blocked_operations, failed_actions, skipped_conditions.
function RuntimeProfile:simulate()
    local saved_state = self._state
    local saved_op_idx = self._current_operation_idx
    local saved_action_idx = self._current_action_idx
    local saved_variables = self._variables

    self:reset()
    self._dry_run = true

    local ok, err = pcall(function()
        if not self._profile then
            error("profile not loaded")
        end
        self:_execute_dry_run()
    end)

    if not ok then
        self._state = saved_state
        self._current_operation_idx = saved_op_idx
        self._current_action_idx = saved_action_idx
        self._variables = saved_variables
        self._dry_run = false
        return { error = tostring(err) }
    end

    local result = self._sim_result or {
        operations_count = 0,
        estimated_duration_seconds = 0,
        blocked_operations = 0,
        failed_actions = 0,
        skipped_conditions = 0,
        unmet_guards = 0,
        path = {},
        truncated = false,
    }

    self._state = saved_state
    self._current_operation_idx = saved_op_idx
    self._current_action_idx = saved_action_idx
    self._variables = saved_variables
    self._dry_run = false

    return result
end

-- ====================================================================
-- W4.5 — Structured logging
-- ====================================================================

--- The graph node the executor is standing on, or nil for pre-plan content (which has none, and
--- for which inventing one would make the field a lie).
---
--- Derived at emit time rather than pushed on every index write: `_current_operation_idx` moves
--- from six places (advance, forward reconcile, backward rewind, the skipped-action advance, the
--- save restore, and reset), and a pushed field goes stale at whichever one a later change
--- forgets — leaving `operation` correct and `node_id` wrong, which is worse than nil.
function RuntimeProfile:_node_id_for_current_operation()
    if self._current_node_id then return self._current_node_id end
    local operations = self._profile and self._profile.operations
    local op = operations and operations[self._current_operation_idx]
    local node_id = op and op.node_id
    -- EventSchema.validate rejects a non-string node_id; a malformed plan must not be able to
    -- invalidate every event the run emits.
    return type(node_id) == "string" and node_id or nil
end

--- Emit a structured log entry to event bus and internal log.
--- Shape is owned by core/event_schema.lua (ADR 09a §1.5) — this function decides WHEN an event
--- happens and which run it belongs to; it does not decide what an event looks like.
function RuntimeProfile:_log_event(event_type, data)
    -- A run is the span of one seq sequence, so the run id is minted off the same counter:
    -- reset() zeroes _log_total, and without a fresh id the restarted seq numbers would collide
    -- with the pre-reset ones inside a single run_id — and (run_id, seq) is the only stable key
    -- a replay or timeline can join entries on.
    if not self._run_id or (self._log_total or 0) == 0 then
        self._run_id = EventSchema.new_run_id()
    end
    -- Ring buffer: an unbounded log grew for the whole session (17k+ entries live-caught)
    -- and was serialized wholesale into every save. seq preserves the absolute event index.
    self._log_total = (self._log_total or 0) + 1

    local entry = EventSchema.build({
        event = event_type,
        timestamp = (core and core.time and core.time()) or 0,
        state = self._state,
        seq = self._log_total,
        run_id = self._run_id,
        node_id = self:_node_id_for_current_operation(),
        legacy = { operation = self._current_operation_idx },
        data = data,
    })

    table.insert(self._execution_log, entry)
    while #self._execution_log > MAX_LOG_ENTRIES do
        table.remove(self._execution_log, 1)
    end

    -- Also publish to event bus for external listeners (editor UI, etc.)
    if self._event_bus then
        self._event_bus:publish("questing:log", entry)
    end
    -- Update blackboard
    self._blackboard:set("module.questing.last_log", entry)
end

-- Opportunistic engagement range. An operation that patrols a grind area with many Travel
-- waypoints before its Kill action would otherwise walk right past the mobs it exists to kill
-- (live-caught: op 44 walked through 20 Kobold Laborers without engaging any). While a Travel
-- action runs, if the op's later Kill action targets a creature already this close, jump
-- straight to the Kill — its sticky-target chase takes over from here and the remaining patrol
-- waypoints are unnecessary.
local OPPORTUNISTIC_KILL_RANGE = 40.0

--- If `op` has a Kill action after `from_idx` whose target creatures include one within
--- OPPORTUNISTIC_KILL_RANGE of the player, return that action's index; else nil. Cheap-ish:
--- one nearest-creature scan, and only for Travel actions in an op that still has pending kills.
function RuntimeProfile:_opportunistic_kill_index(op, from_idx)
    if not (UnitHelper and UnitHelper.get_nearest_creature) then return nil end
    local kill_idx, entries
    for i = from_idx + 1, #(op.actions or {}) do
        local a = op.actions[i]
        if a and a.type == "Kill" then
            kill_idx = i
            entries = a.payload and a.payload.creature_entries
            break
        end
    end
    if not kill_idx or type(entries) ~= "table" or #entries == 0 then return nil end
    local nearest = UnitHelper.get_nearest_creature(entries)
    if not nearest or type(nearest.get_position) ~= "function" then return nil end
    local player = UnitHelper.get_local_player()
    if not player or type(player.get_position) ~= "function" then return nil end
    local ok_c, cpos = pcall(nearest.get_position, nearest)
    local ok_p, ppos = pcall(player.get_position, player)
    if not (ok_c and ok_p and type(cpos) == "table" and type(ppos) == "table") then return nil end
    local dx = (tonumber(ppos.x) or 0) - (tonumber(cpos.x) or 0)
    local dy = (tonumber(ppos.y) or 0) - (tonumber(cpos.y) or 0)
    local dz = (tonumber(ppos.z) or 0) - (tonumber(cpos.z) or 0)
    if math.sqrt(dx * dx + dy * dy + dz * dz) <= OPPORTUNISTIC_KILL_RANGE then
        return kill_idx
    end
    return nil
end

-- ====================================================================
-- W4.1 — Running state: execute current action, handle outcomes
-- ====================================================================

function RuntimeProfile:_execute_running()
    local operations = self._profile.operations or {}
    if #operations == 0 then
        self._state = "finished"
        return "finished", "no operations"
    end

    local op = operations[self._current_operation_idx]
    if not op then
        self._state = "finished"
        return "finished", "completed all operations"
    end

    -- Detect operation change → reset per-action retry counter (W4.1)
    local op_id = op.id or self._current_operation_idx
    if op_id ~= self._current_op_id then
        self._current_op_id = op_id
        self._current_action_retries = 0
        -- If nav was left active from a previous op, stop it
        if self._nav:is_active() then
            self._nav:stop("op_change")
        end
    end

    -- W1.1: Get current action from operation's actions array
    if not op.actions or #op.actions == 0 then
        self._state = "finished"
        return "finished", "operation has no actions"
    end
    if self._current_action_idx > #op.actions then
        self._current_action_idx = 1  -- Reset to first action if out of bounds
    end
    local action = op.actions[self._current_action_idx]
    local ctx = self:create_context()

    -- Operation-level applicability, evaluated BEFORE the first action runs.
    --
    -- Actions are ordered Travel-then-work, so a step whose quests are already done would otherwise
    -- walk the whole way there and only then discover there is nothing to do — which is exactly
    -- what "it went back to the very first step we already did" looks like. Decide up front: if the
    -- operation has quest work and ALL of it is already satisfied, skip the operation without
    -- moving. This observes real game state rather than trusting saved progress (ADR 06 §8.1).
    if self._current_action_idx == 1 and self:_operation_already_done(op) then
        self:_log_event("operation_already_done", { operation = self._current_operation_idx })
        -- Advance THROUGH _advance_operation, not a raw increment: the advance path
        -- re-reconciles and can jump a whole stretch of moot operations. Live-caught:
        -- ops 5-6 skipped here one at a time, then the raw +1 landed on op 7's kills
        -- even though quest 33 was log-complete and the right stop was op 8's turn-in.
        self:_advance_operation(op)
        self._current_action_idx = 1
        return "running", "already done, skipping operation"
    end

    -- Same idea for non-quest operations gated by their own Completion condition: if the
    -- gate (usually ObjectiveComplete) is already met, the kills/loots in front of it are
    -- moot — skip the operation instead of re-farming from a zeroed local counter.
    --
    -- Re-checked on EVERY tick of the operation, not just at action 1: Kill counts corpses
    -- from zero and holds until ITS quantity is satisfied, and the first
    -- is_quest_flagged_completed(qid) call per quest can answer a cold false until the
    -- client fetches server data — so a gate read once at op entry commits the bot to the
    -- full travel-and-farm chain (live-caught twice: re-farming 40 wolves for rewarded
    -- quest 33, and walking op 24's nine lead-in waypoints for finished quest 15).
    -- _operation_gate_already_met returns false for ops without both a Completion gate and
    -- farm work, so quest-action and pure-travel ops don't pay for this.
    if self:_operation_gate_already_met(op, ctx) then
        self:_log_event("operation_gate_met", { operation = self._current_operation_idx })
        self:_advance_operation(op)
        self._current_action_idx = 1
        return "running", "completion gate already met, skipping operation"
    end

    -- Opportunistic kill: while walking a grind op's lead-in waypoints, if a target mob for
    -- this op's Kill is already in engage range, stop walking and go kill it (live-caught:
    -- the bot strolled through 20 Kobold Laborers to finish a 14-waypoint patrol first).
    if action and action.type == "Travel" then
        local kidx = self:_opportunistic_kill_index(op, self._current_action_idx)
        if kidx then
            self:_log_event("opportunistic_kill", {
                operation = self._current_operation_idx,
                from = self._current_action_idx,
                to = kidx,
            })
            self._current_action_idx = kidx
            self._current_action_retries = 0
            if self._nav:is_active() then self._nav:stop("opportunistic_kill") end
            return "running", "target in range, engaging instead of walking past"
        end
    end

    local status, msg
    -- CL4: a per-action class guard (compiler-emitted `action.guard`, a RuntimeCondition) is
    -- evaluated BEFORE dispatch. Unmet -> treat exactly like an existing "skipped" action: never
    -- executed, advances the action/operation index, never counts as a retry/failure. Guard-less
    -- actions (the overwhelming majority, and every pre-CL4 profile) are unaffected.
    if action and action.guard and not RuntimeAction.evaluate_condition(ctx, action.guard) then
        status, msg = "skipped", "class guard unmet"
    else
        status, msg = RuntimeAction.execute(action, ctx)
    end

    self._blackboard:set("module.questing.current_operation", self._current_operation_idx)
    self._blackboard:set("module.questing.current_status", status)
    self._blackboard:set("module.questing.current_action", action and action.type or "unknown")

    if status == "success" then
        self:_log_event("action_success", { action_type = action and action.type, msg = msg })
        self._current_action_retries = 0
        self._consecutive_failures = 0
        -- A Completion-role gate that just became met ends its wait here; release the
        -- timer so a later action (or a looped re-entry) starts a fresh wait (PR5b loop-safety).
        self._wait_started_at = nil
        self._wait_action_key = nil
        self._wait_level_progress = nil
        self:_set_level_gate_grind(false) -- XP1: gate passed — stop grinding-while-gated
        
        -- W1.1: Move to next action within current operation
        self._current_action_idx = self._current_action_idx + 1
        
        -- If we've completed all actions in current operation, advance to next operation
        if self._current_action_idx > #op.actions then
            self:_advance_operation(op)
            self._current_action_idx = 1  -- Reset for next operation
        end
        
        return "running", "next action"

    elseif status == "skipped" then
        self:_log_event("action_skipped", { action_type = action and action.type, msg = msg })
        -- Skipped actions should advance to next action
        self._current_action_idx = self._current_action_idx + 1
        
        -- If we've processed all actions in current operation, advance to next operation
        if self._current_action_idx > #op.actions then
            if op.next_condition == "auto" or op.next_condition == "always" then
                self._current_operation_idx = self._current_operation_idx + 1
            else
                self._current_operation_idx = self._current_operation_idx + 1
            end
        end
        self:_save()  -- W5.3 — Save on skipped advance
        return "running", "skipped, advancing"

    elseif status == "waiting" then
        -- Completion-role Condition gate: hold this action and re-poll next tick. Does not
        -- advance the action index and does not count as a retry/failure (PR5b).
        local key = tostring(op_id) .. ":" .. tostring(self._current_action_idx)
        local now = (core and core.time and core.time()) or 0
        if self._wait_action_key ~= key then
            self._wait_action_key = key
            self._wait_started_at = now
            self._wait_kill_count = nil
            self._wait_level_progress = nil
        end

        -- A Kill/Grind that is still MAKING PROGRESS must never be timeout-abandoned: a
        -- 40-mob grind legitimately exceeds MAX_CONDITION_WAIT. A rising kill count for
        -- this action's entries resets the clock; only a frozen count can time out.
        if action and (action.type == "Kill" or action.type == "Grind") then
            local entries = (action.payload and action.payload.creature_entries) or {}
            local counts = self._action_state and self._action_state.kill_counts
            local count = (counts and counts[table.concat(entries, ",")]) or 0
            if self._wait_kill_count == nil then
                self._wait_kill_count = count
            elseif count > self._wait_kill_count then
                self._wait_kill_count = count
                self._wait_started_at = now
            end
        end

        -- XP1: a LevelAtLeast Completion gate legitimately holds for HOURS. Exactly like the
        -- rising kill count above, observable leveling progress (level or XP changing since
        -- the last snapshot) resets the clock — only genuinely frozen progress can time out.
        -- While the gate holds, raise the combat module's world auto-engage flag so the bot
        -- grinds nearby hostiles instead of idling under the gate.
        local cond = action and action.type == "Condition"
            and action.payload and action.payload.condition
        if cond and cond.type == "LevelAtLeast" then
            local level = ctx:get_player_level() or 0
            local xp = ctx.get_player_xp and ctx:get_player_xp() or nil
            -- Change-detection, not strictly "rises": on level-up the XP counter drops back
            -- near zero while the level rises, and both together only ever change when the
            -- player is actually progressing.
            local progress = tostring(level) .. ":" .. tostring(xp)
            if self._wait_level_progress == nil then
                self._wait_level_progress = progress
            elseif progress ~= self._wait_level_progress then
                self._wait_level_progress = progress
                self._wait_started_at = now
            end
            self:_set_level_gate_grind(true)
        else
            self:_set_level_gate_grind(false)
        end

        local elapsed = now - self._wait_started_at
        if elapsed >= MAX_CONDITION_WAIT then
            self:_log_event("condition_wait_timeout", { action_type = action and action.type, duration = elapsed })
            self._wait_started_at = nil
            self._wait_action_key = nil
            self._wait_level_progress = nil
            self:_set_level_gate_grind(false)

            -- Bounded wait exceeded: don't deadlock the bot — advance past the gate.
            -- Through _advance_action, so the next action gets a fresh retry budget (A1).
            self:_advance_action(op)
            return "running", "condition wait timed out, skipping"
        end

        return "running", "waiting for completion"

    elseif status == "retry" then
        self._current_action_retries = self._current_action_retries + 1
        self:_log_event("action_retry", {
            action_type = action and action.type,
            retry = self._current_action_retries,
            max = MAX_RETRIES_PER_ACTION,
        })

        if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
            -- Exhausted retries → treat as failure
            self:_log_event("action_retry_exhausted", { action_type = action and action.type })
            self._consecutive_failures = self._consecutive_failures + 1
            self:_check_consecutive_failures()

            -- A1: _advance_action resets the retry budget too, so the NEXT action starts fresh
            -- rather than inheriting an already-exhausted counter.
            self:_advance_action(op)
            return "running", "retries exhausted, skipping action"
        end
        return "running", "retry"

    elseif status == "blocked" then
        self:_log_event("action_blocked", { action_type = action and action.type, msg = msg })

        -- Enter navigation recovery (W4.2). Pass the ctx already built above for this tick so
        -- _resolve_nav_target's zone-destination branch does not build a second one (F3).
        return self:_handle_blocked(action, ctx)

    elseif status == "failed" then
        self:_log_event("action_failed", { action_type = action and action.type, msg = msg })
        self._consecutive_failures = self._consecutive_failures + 1
        self:_check_consecutive_failures()

        -- A1: reset the retry budget for the next action.
        self:_advance_action(op)
        return "running", "action failed, skipping"
    end

    return "running", tostring(status)
end

-- ====================================================================
-- W4.4 — Consecutive failure check
-- ====================================================================

function RuntimeProfile:_check_consecutive_failures()
    if self._consecutive_failures >= MAX_CONSECUTIVE_FAILURES then
        self:_log_event("profile_failed", {
            consecutive_failures = self._consecutive_failures,
        })
        self._state = "failed"
    end
end

-- ====================================================================
-- A1 — Per-action retry budget
-- ====================================================================

--- Advance to the next action within `op`, rolling over to the next operation at the boundary.
--- ALWAYS resets `_current_action_retries` to 0.
---
--- PROVEN: `_current_action_retries` used to reset ONLY on success (:1103) and operation change
--- (:1053). The retry-exhausted, failed, and _handle_blocked-no-target branches advanced
--- `_current_action_idx` with a raw `+ 1` and left the counter alone, so every action after the
--- first in an operation inherited whatever was left of the budget. Repro: 4 retry-returning
--- actions -> action 1 got 5 attempts, actions 2/3/4 got ONE each, _consecutive_failures hit 3,
--- state="failed" by tick 7. One flaky action could kill the whole operation in ~1 second. Each
--- action now gets its own full MAX_RETRIES_PER_ACTION budget.
function RuntimeProfile:_advance_action(op)
    self._current_action_idx = self._current_action_idx + 1
    self._current_action_retries = 0
    if op and self._current_action_idx > #op.actions then
        self._current_operation_idx = self._current_operation_idx + 1
        self._current_action_idx = 1
    end
end

-- ====================================================================
-- W4.2 — Navigating state: poll NavAdapter, retry on arrival
-- ====================================================================

--- B5 support: verify the player is actually near the target the blocked action was navigating
--- to, rather than trusting the nav client's "idle" state on faith. Anything that calls stop()
--- on the shared nav client (combat preempting it, a reload, another module) drives it idle
--- with no position guarantee — execute_travel already handles the same pair correctly (trusts
--- "arrived" blindly, requires a position check for "idle"); this brings _execute_navigating
--- in line with it.
function RuntimeProfile:_confirm_nav_arrival()
    local target_pos = self:_resolve_nav_target(self._last_blocked_action)
    if not target_pos then
        -- No known target to confirm against — nothing to verify, so fall back to trusting
        -- idle rather than wedging the run on a check this cannot perform.
        return true
    end
    local ctx = self:create_context()
    return ctx:is_at_destination(target_pos, ARRIVAL_TOLERANCE)
end

function RuntimeProfile:_execute_navigating()
    -- Mid-flight applicability. The `_operation_already_done` skip lives in _execute_running and
    -- only fires at action index 1, so once a Travel hands control to this state nothing re-asks
    -- whether the destination still matters — the bot commits to arriving. A quest accepted or
    -- turned in BY HAND (or by a party member) mid-leg left it walking the whole way to an NPC it
    -- no longer had business with; it arrived, the accept reported instant success off the quest
    -- log, and the entire trip was wasted (user-reported).
    --
    -- Reconciliation already covers load and every operation advance — this closes the window in
    -- between. Throttled because travel legs run for many seconds while this state ticks at frame
    -- rate, and _op_quest_status walks the quest log.
    local now = (core and core.time and core.time()) or 0
    local last_recheck = self._nav_recheck_at
    if last_recheck == nil or (now - last_recheck) >= NAV_RECHECK_INTERVAL then
        self._nav_recheck_at = now
        local operations = (self._profile and self._profile.operations) or {}
        local op = operations[self._current_operation_idx]
        -- Quest work only: _operation_already_done is deliberately silent on kill/travel-only
        -- operations, so an unobservable leg is never aborted on a guess.
        if op and self:_operation_already_done(op) then
            self._nav:stop("operation_already_done")
            self:_log_event("operation_already_done", {
                operation = self._current_operation_idx,
                during = "navigating",
            })
            self._state = "running"
            self:_advance_operation(op)
            self._current_action_idx = 1
            return "running", "quest work satisfied mid-route, skipping operation"
        end
    end

    -- If nav completed without us noticing, check if we're there
    if not self._nav:is_active() then
        local state = self._nav:get_state()
        if state == "arrived" then
            -- Nav finished; the navmesh's own confirmation is trusted directly.
            self:_log_event("nav_arrived", {})
            self._state = "running"
            return "running", "navigated, retry"
        elseif state == "idle" and self:_confirm_nav_arrival() then
            self:_log_event("nav_arrived", {})
            self._state = "running"
            return "running", "navigated, retry"
        end
    end

    -- Poll nav
    local state, progress = self._nav:poll()
    self._blackboard:set("module.questing.nav_state", state)

    if state == "arrived" then
        self._nav:stop("arrived")
        self:_log_event("nav_arrived", {})
        self._state = "running"
        return "running", "navigated, retry"

    elseif state == "idle" then
        -- B5: "idle" with NO position check used to be treated as arrival unconditionally.
        -- Require an actual position confirmation before accepting it.
        if self:_confirm_nav_arrival() then
            self._nav:stop("arrived")
            self:_log_event("nav_arrived", {})
            self._state = "running"
            return "running", "navigated, retry"
        end
        self:_log_event("nav_idle_unconfirmed", {})
        self._current_action_retries = self._current_action_retries + 1
        self._state = "running"
        -- These retries must actually EXHAUST. They were incremented here but consumed
        -- nowhere, so a nav client that silently dropped every request span the
        -- running↔navigating cycle at frame rate forever (live-caught: 17k+ events at
        -- one waypoint, player standing still). Mirror the nav-timeout branch: give up
        -- on the action, count a consecutive failure so the cascade guard can surface
        -- a blocked run instead of a silent spin.
        if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
            self._consecutive_failures = self._consecutive_failures + 1
            self:_check_consecutive_failures()
            local operations = self._profile.operations or {}
            local op = operations[self._current_operation_idx]
            self:_advance_action(op)
            return "running", "nav idle without arrival, retries exhausted, advancing"
        end
        return "running", "nav idle without arrival, retry"

    elseif state == "requesting_path" or state == "moving" then
        -- Check timeout
        local now = (core and core.time and core.time()) or 0
        if self._nav_start_time and (now - self._nav_start_time) > NAV_TIMEOUT then
            self:_log_event("nav_timeout", { duration = now - self._nav_start_time })
            self._current_action_retries = self._current_action_retries + 1
            self._nav:stop("timeout")
            self._last_blocked_action = nil
            self._state = "running"
            if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
                self._consecutive_failures = self._consecutive_failures + 1
                self:_check_consecutive_failures()
                -- Skip the whole operation through _advance_operation (reconcile + save),
                -- and start its successor at action 1 with a fresh retry budget — the raw
                -- op increment used to keep the old action index and exhausted counter.
                local operations = self._profile.operations or {}
                self:_advance_operation(operations[self._current_operation_idx])
                self._current_action_idx = 1
                self._current_action_retries = 0
                return "running", "nav timeout, retries exhausted"
            end
            return "running", "nav timeout, retry"
        end
        return "running", "navigating"

    elseif state == "stuck" then
        -- Pathfinding issue: increment retries, go back to running
        self:_log_event("nav_stuck", {})
        self._current_action_retries = self._current_action_retries + 1
        self._nav:stop("stuck")
        self._state = "running"
        return "running", "nav stuck, retry"

    else
        -- failed / unknown. Same exhaustion contract as the idle branch: without it a
        -- client that fails every request (unreachable target, dead server) loops
        -- retry-forever with no escalation and no visible blocked reason.
        local nav_err = self._nav.get_last_error and self._nav:get_last_error() or nil
        self:_log_event("nav_failed", { state = state, reason = nav_err and nav_err.reason })
        self._current_action_retries = self._current_action_retries + 1
        self._state = "running"
        if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
            self._consecutive_failures = self._consecutive_failures + 1
            self:_check_consecutive_failures()
            local operations = self._profile.operations or {}
            local op = operations[self._current_operation_idx]
            self:_advance_action(op)
            return "running", "nav failed, retries exhausted, advancing"
        end
        return "running", "nav failed, retry"
    end
end

-- ====================================================================
-- W4.3 — Ghost state: death recovery
-- ====================================================================

-- resurrect_corpse only works near the corpse; TBC accepts ~39yd, 30 keeps a margin.
local CORPSE_RES_RANGE = 30.0

function RuntimeProfile:_execute_ghost()
    -- Check if still dead
    local dead = self:_is_player_dead()
    if not dead then
        -- Alive again! Return to running, retry current operation
        self:_log_event("ghost_rezzed", {})
        self._state = "running"
        self._ghost_start_time = nil
        if self._nav and self._nav.is_active and self._nav:is_active() then
            self._nav:stop("rezzed")
        end
        return "running", "resurrected, retry"
    end

    local now = (core and core.time and core.time()) or 0
    local elapsed = self._ghost_start_time and (now - self._ghost_start_time) or 0

    -- Timeout: skip current operation
    if elapsed >= GHOST_TIMEOUT then
        self:_log_event("ghost_timeout", { duration = elapsed })
        self._ghost_start_time = nil
        -- Through _advance_operation (reconcile + save) with the action index and retry
        -- budget reset — the raw op increment left both stale for the next operation.
        local operations = (self._profile and self._profile.operations) or {}
        self:_advance_operation(operations[self._current_operation_idx])
        self._current_action_idx = 1
        self._current_action_retries = 0
        self._state = "running"
        return "running", "ghost recovery timed out, skipping operation"
    end

    -- Phase 1 — still a corpse: release the spirit.
    local player = UnitHelper.get_local_player()
    local is_ghost = false
    if player and player.is_ghost then
        local ok, ghost = pcall(player.is_ghost, player)
        is_ghost = ok and ghost == true
    end
    if not is_ghost then
        if core and core.input and core.input.release_spirit then
            core.input.release_spirit()
            self:_log_event("ghost_release_spirit", {})
        end
        return "running", "ghost recovery: releasing spirit"
    end

    -- Phase 2 — ghost at the graveyard: RUN TO THE CORPSE. This never happened before —
    -- resurrect_corpse was spammed from wherever the ghost stood, silently failing out of
    -- range while the ghost stood still (live-caught).
    local corpse = nil
    if core and core.game_ui and core.game_ui.get_corpse_position then
        local ok, pos = pcall(core.game_ui.get_corpse_position)
        if ok and type(pos) == "table" and pos.x then
            corpse = pos
        end
    end
    if corpse and player and player.get_position then
        local ok_p, ppos = pcall(player.get_position, player)
        if ok_p and ppos then
            local dist = Geometry.distance(ppos, corpse)
            if dist and dist > CORPSE_RES_RANGE then
                if self._nav and self._nav.is_active and not self._nav:is_active() then
                    self._nav:move_to({ x = corpse.x, y = corpse.y, z = corpse.z },
                        { tolerance = CORPSE_RES_RANGE * 0.5 })
                    self:_log_event("ghost_corpse_run", { distance = math.floor(dist) })
                end
                return "running", "ghost recovery: corpse run (" .. tostring(math.floor(dist)) .. "yd)"
            end
        end
    end

    -- Phase 3 — in range: wait out the res sickness delay, then resurrect.
    if core and core.game_ui and core.game_ui.get_resurrect_corpse_delay then
        local ok, delay = pcall(core.game_ui.get_resurrect_corpse_delay)
        if ok and tonumber(delay) and delay > 0 then
            return "running", "ghost recovery: res available in " .. tostring(math.floor(delay)) .. "s"
        end
    end
    if core and core.input and core.input.resurrect_corpse then
        core.input.resurrect_corpse()
        self:_log_event("ghost_resurrect_attempt", {})
    end

    return "running", "ghost recovery (" .. tostring(math.floor(elapsed)) .. "s)"
end

-- ====================================================================
-- W4.2 — Blocked handler: resolve target and start navigation
-- ====================================================================

--- Called when an action returns "blocked".
--- Attempts to resolve a navigation target from the action payload
--- and starts NavAdapter movement. Transitions to "navigating" state.
--- @param ctx table|nil Optional pre-built context for this tick (F3: avoids a redundant
---        create_context() call inside _resolve_nav_target's zone-destination branch when
---        the caller already built one this tick).
function RuntimeProfile:_handle_blocked(action, ctx)
    -- If nav is already active (action handler started it), just poll
    if self._nav:is_active() then
        self._state = "navigating"
        self._nav_start_time = (core and core.time and core.time()) or 0
        self._last_blocked_action = action
        self:_log_event("nav_already_active", { action_type = action and action.type })
        return "running", "navigating"
    end

    -- Resolve target position from action payload
    local target_pos = self:_resolve_nav_target(action, ctx)
    if not target_pos then
        -- Can't navigate: increment retries
        self._current_action_retries = self._current_action_retries + 1
        if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
            -- Exhausted retries → advance to next action (A1: reset the budget for the next one).
            self._consecutive_failures = self._consecutive_failures + 1
            self:_check_consecutive_failures()
            local operations = self._profile.operations or {}
            local op = operations[self._current_operation_idx]
            self:_advance_action(op)
            return "running", "blocked (no nav target), retries exhausted, advancing"
        end
        return "running", "blocked (no nav target)"
    end

    -- Start navigation
    local ok, err = self._nav:move_to(target_pos, { tolerance = ARRIVAL_TOLERANCE })
    if not ok then
        self._current_action_retries = self._current_action_retries + 1
        self:_log_event("nav_dispatch_failed", { error = err })
        -- Same exhaustion contract as the no-target branch above: a nav client that
        -- rejects every dispatch must not retry this action forever.
        if self._current_action_retries >= MAX_RETRIES_PER_ACTION then
            self._consecutive_failures = self._consecutive_failures + 1
            self:_check_consecutive_failures()
            local operations = self._profile.operations or {}
            local op = operations[self._current_operation_idx]
            self:_advance_action(op)
            return "running", "blocked (nav dispatch failed), retries exhausted, advancing"
        end
        return "running", "blocked (nav dispatch failed)"
    end

    self._state = "navigating"
    self._nav_start_time = (core and core.time and core.time()) or 0
    self._last_blocked_action = action
    self:_log_event("nav_started", {
        target = target_pos,
        action_type = action and action.type,
    })
    return "running", "navigating to target"
end

-- ====================================================================
-- Target resolution helpers
-- ====================================================================

--- Resolve a navigation target from an action's payload.
--- Returns {x, y, z} or nil.
--- @param ctx table|nil Optional pre-built context (F3) — reused for zone-destination lookups
---        instead of calling create_context() a second time in the same tick.
function RuntimeProfile:_resolve_nav_target(action, ctx)
    if not action or not action.payload then return nil end
    local p = action.payload

    -- 1. Explicit position coordinates (handle both legacy {x,y,z} and new {world_x,world_y,world_z,map} formats)
    --
    -- `is_navigable_position` gates this whole step, because this function is a FALLBACK CHAIN and
    -- the origin sentinel used to win it. A Travel compiled with no resolved position carried
    -- `{map=0, world_x=0, world_y=0, world_z=0}`; `elseif p.position.world_x then` accepted it (0
    -- is TRUTHY in LuaJIT), so steps 2-5 below — npc_entry, object_entry, creature_entries, and
    -- the zone-destination string that could still have answered — were never reached, and nav was
    -- handed world origin. Refusing the sentinel by VALUE restores the fall-through.
    if p.position and type(p.position) == "table" and RuntimeAction.is_navigable_position(p.position) then
        if p.position.x then
            -- Legacy format: {x, y, z}
            return { x = p.position.x, y = p.position.y, z = p.position.z }
        elseif p.position.world_x then
            -- New format from compiler: {world_x, world_y, world_z, map}. The recorded Z
            -- must go through the same plausibility gate as execute_travel's — this
            -- branch fed the RAW world_z straight to nav, so a bogus baked height (the
            -- .goto radius bug: z=45, ~35yd underground) wedged pathing in awaiting_path
            -- forever even though execute_travel itself would have sanitized it.
            return {
                x = p.position.world_x,
                y = p.position.world_y,
                z = RuntimeAction.resolve_ground_z(
                    p.position.world_x, p.position.world_y, p.position.world_z),
            }
        end
    end

    -- 2. NPC entry → look up in object manager
    if p.npc_entry then
        return self:_get_npc_position(p.npc_entry)
    end

    -- 3. Object entry → look up in object manager
    if p.object_entry then
        return self:_get_object_position(p.object_entry)
    end

    -- 4. Creature entries (first one) → look up
    if p.creature_entries and type(p.creature_entries) == "table" and #p.creature_entries > 0 then
        return self:_get_npc_position(p.creature_entries[1])
    end

    -- 5. Zone destination string (e.g. "Elwynn Forest")
    if p.destination and type(p.destination) == "string" then
        -- F3: reuse the caller-provided context when available instead of building a second
        -- one for this same tick; only fall back to create_context() when called standalone
        -- (e.g. from _confirm_nav_arrival, a different tick/state than the "blocked" handler).
        ctx = ctx or self:create_context()
        return ctx:get_zone_waypoint(p.destination)
    end

    return nil
end

--- Look up an NPC's position: live object manager first, then STATIC sources.
---
--- The object manager only sees units in draw distance. Marshal McBride stands inside
--- Northshire Abbey — invisible from where travel drops the character — so the accept had
--- no nav target, burned its retries, and the quest was skipped (live-caught). When the
--- NPC is not visible, fall back to:
---   1. the compiled profile's own npcs table (authoritative spawn, zero requests —
---      empty in today's profiles, a compiler gap, but honored the moment it lands);
---   2. the QueryServer spawn position (async request-and-cache: nil while the response
---      is in flight, which lands within a tick on localhost — the blocked-retry loop
---      naturally re-polls).
--- Walking to the static spawn brings the NPC into draw distance, after which the live
--- lookup and is_at_npc take over.
function RuntimeProfile:_get_npc_position(npc_entry)
    local npc = UnitHelper.get_nearest_creature({ npc_entry })
    if npc and npc:is_valid() then
        if npc.get_position then
            local ok, pos = pcall(npc.get_position, npc)
            if ok and pos then
                return { x = pos.x, y = pos.y, z = pos.z }
            end
        end
    end

    -- Static source 1: the profile's resolved npc table.
    if self._profile and type(self._profile.npcs) == "table" and #self._profile.npcs > 0 then
        if not self._npc_index then
            self._npc_index = {}
            for _, n in ipairs(self._profile.npcs) do
                if n.entry and n.position then
                    self._npc_index[n.entry] = n.position
                end
            end
        end
        local p = self._npc_index[npc_entry]
        if p then
            local x = p.x or p.world_x
            local y = p.y or p.world_y
            local z = p.z or p.world_z or 0
            if x and y then
                return { x = x, y = y, z = RuntimeAction.resolve_ground_z(x, y, z) }
            end
        end
    end

    -- Static source 2: QueryServer spawn positions, filtered to the current map.
    if self._query and self._query.get_npc then
        local ok, info = pcall(self._query.get_npc, self._query, npc_entry)
        if ok and type(info) == "table" and type(info.positions) == "table" then
            local my_map = core and core.get_map_id and core.get_map_id() or nil
            for _, p in ipairs(info.positions) do
                if p.x and p.y and (my_map == nil or p.map == nil or p.map == my_map) then
                    return { x = p.x, y = p.y, z = RuntimeAction.resolve_ground_z(p.x, p.y, p.z or 0) }
                end
            end
        end
    end

    return nil
end

--- Look up a game object's position from the object manager (Sylvannas API compliant).
function RuntimeProfile:_get_object_position(object_entry)
    local obj = UnitHelper.get_nearest_game_object({ object_entry })
    if obj and obj:is_valid() then
        if obj.get_position then
            local ok, pos = pcall(obj.get_position, obj)
            if ok and pos then
                return { x = pos.x, y = pos.y, z = pos.z }
            end
        end
    end
    return nil
end

--- Check if the player is dead OR a ghost. Ghost form reports is_dead() == false, which
--- made the profile leave the ghost state at the graveyard and resume the route — fighting
--- wolves as a ghost (live-caught 2026-07-23). is_dead_or_ghost is the authoritative check.
function RuntimeProfile:_is_player_dead()
    local player = UnitHelper.get_local_player()
    if player and player:is_valid() then
        if player.is_dead_or_ghost then
            local ok, dead = pcall(player.is_dead_or_ghost, player)
            if ok then
                return dead == true
            end
        end
        if player.is_dead then
            local ok, dead = pcall(player.is_dead, player)
            if ok and dead == true then
                return true
            end
        end
        if player.is_ghost then
            local ok, ghost = pcall(player.is_ghost, player)
            if ok and ghost == true then
                return true
            end
        end
        -- Fallback: check health
        if player.get_health then
            local ok, health = pcall(player.get_health, player)
            if ok and type(health) == "number" then
                return health <= 0
            end
        end
    end
    return false -- Assume alive if no API
end

--- Advance to the next operation: follow the plan's outgoing edge guards when the operation has
--- any, otherwise increment as pre-plan content always did.
--- Also triggers auto-save of execution state (W5.3).
---
--- This is the single branch point ADR 09 §6.2 budgets for graph execution. The `next_condition`
--- chain it replaced had three arms that all did `+1` — the "conditional" arm was a stub that
--- never evaluated anything, so every non-linear guide compiled since has been running as if it
--- were linear. Selection itself lives in `execution_plan.lua`; what belongs here is only WHERE
--- the index lands and WHAT gets logged.
function RuntimeProfile:_advance_operation(op)
    local operations = (self._profile and self._profile.operations) or {}

    -- One context for however many guards this boundary evaluates, built only if a guard exists.
    -- create_context is on the per-tick hot path and a linear plan must not pay for the branch.
    local ctx
    local function evaluate(condition)
        ctx = ctx or self:create_context()
        return RuntimeAction.evaluate_condition(ctx, condition)
    end

    local next_idx, outcome, detail = ExecutionPlan.select_transition(op, evaluate)

    -- Logged BEFORE the index moves, so `node_id` names the node the route is LEAVING — an edge
    -- event attributed to its destination cannot be joined back to the decision that produced it.
    if outcome == "guarded" then
        self:_log_event("plan_branch_taken", {
            guard_id = detail.guard_id,
            to_operation = next_idx,
            unmet = detail.unmet,
        })
    elseif outcome == "dead_end" then
        -- No outgoing edge is satisfiable. Terminating and logging beats the two alternatives:
        -- re-running this operation forever is invisible from inside the game, and falling
        -- through to idx+1 would run a branch the author explicitly gated off.
        self:_log_event("plan_dead_end", {
            unmet = detail.unmet,
            transitions = detail.transitions,
            guards = detail.guards,
        })
    elseif outcome == "terminal" then
        self:_log_event("plan_route_end", {})
    end

    if outcome == "linear" then
        self._current_operation_idx = self._current_operation_idx + 1
    elseif outcome == "terminal" or outcome == "dead_end" then
        -- Past the end, which `_execute_running` already reports as "finished". Topological order
        -- does not put terminal nodes last, so `+1` here would run whatever operation happens to
        -- sit at the next index with nothing pointing at it.
        self._current_operation_idx = #operations + 1
    else
        self._current_operation_idx = next_idx
    end

    -- Re-reconcile at every operation boundary: the turn-in that just landed may prove a
    -- whole later stretch of the route done (e.g. turning in quest 7 makes ops 5-6's
    -- accept/turn-in satisfied and quest 33's kills log-complete, so the right next stop
    -- is op 8's turn-in, not op 7's kobold camp). A certain verdict (ready turn-in) can
    -- also rewind — at most once per target op — so a turn-in that failed its retries is
    -- revisited instead of lost. Cost is a handful of client flag reads per operation.
    local reconciled, certain, certain_idx = self:_reconcile_start_operation()
    self:_apply_reconciliation(reconciled, certain, certain_idx)

    -- A new operation's Kill starts from a clean slate. kill_counts keying isolates
    -- per-entry-set, but the corpse/loot maps grew for the whole session, and a stale
    -- committed target or chase destination must never leak into the next operation.
    local P = self._action_state
    if P then
        P.kill_counts = {}
        P._counted_corpses = nil
        P._loot_attempts = nil
        P._target_key = nil
        P._chase_dest = nil
    end

    -- W5.3 — Auto-save after operation advance
    self:_save()
end

-- ====================================================================
-- Reset / lifecycle
-- ====================================================================

--- XP1: raise/lower the combat module's world auto-engage flag for a holding LevelAtLeast
--- gate. Idempotent and ownership-aware: only touches the blackboard on a real transition,
--- and only clears a flag THIS profile raised — a user/operator-set auto_engage_world is
--- never stomped by a gate ending.
function RuntimeProfile:_set_level_gate_grind(active)
    if active then
        if not self._level_gate_grind then
            self._level_gate_grind = true
            self._blackboard:set("module.combat.auto_engage_world", true)
            self:_log_event("level_gate_grind", { enabled = true })
        end
    elseif self._level_gate_grind then
        self._level_gate_grind = false
        self._blackboard:set("module.combat.auto_engage_world", false)
        self:_log_event("level_gate_grind", { enabled = false })
    end
end

function RuntimeProfile:reset()
    self._current_operation_idx = 1
    self._current_op_id = nil
    self._variables = {}
    self._state = "running"
    self._current_action_retries = 0
    self._consecutive_failures = 0
    self._current_action_idx = 1
    self._nav_start_time = nil
    self._ghost_start_time = nil
    self._wait_started_at = nil
    self._wait_action_key = nil
    self._wait_level_progress = nil
    self:_set_level_gate_grind(false) -- XP1: never leave the grind flag latched across a reset
    self._last_blocked_action = nil
    self._execution_log = {}
    self._log_total = 0
    self._json_mtime = nil
    self._rewound_ops = {}
    self._deaths_at_op = {}
    self._completed_quests = {}
    self._temporary_variables = {}
    self._visited_vendors = {}
    self._known_flight_paths = {}
    self._known_hearth_location = nil
    self._sim_result = nil
    -- Per-session action state (kill tallies, corpse maps, chase target) dies with the
    -- run; create_context lazily rebuilds a fresh table on the next tick.
    self._action_state = nil
    self._dry_run = false
    if self._nav then
        self._nav:stop("reset")
    end
end

function RuntimeProfile:get_log()
    return self._execution_log
end

function RuntimeProfile:get_state()
    return self._state, {
        operation = self._current_operation_idx,
        retries = self._current_action_retries,
        consecutive_failures = self._consecutive_failures,
    }
end

return RuntimeProfile