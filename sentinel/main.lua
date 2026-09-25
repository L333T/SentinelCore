local SentinelApp = require("runtime/app")

-- Set up package path for sentinel modules
package.path = table.concat({
    "sentinel/?.lua",
    "sentinel/?/?.lua",
    "sentinel/?/?/?.lua",
    "sentinel/?/?/?/?.lua",
    "sentinel/?/?/?/?/?.lua",
    package.path,
}, ";")

-- Load the bundled rotation packages so each can self-register (ADR 08 §2.4/§14). The inventory
-- lives in rotations/init.lua — the rotations layer owns its own contents; this host line only
-- says "this bundle ships rotations", and a rotation running as its own Sylvanas plugin needs
-- neither this line nor that inventory. AFTER the package.path block above, deliberately: in the
-- injector nothing has patched the path yet when this file loads, and a require above the block
-- fails on the very first line of a live boot while passing in every offline test.
require("rotations/init")

local app = nil
local initialized = false
local last_init_error = nil

-- Menu elements for main menu.
--
-- CONSTRUCTED HERE, AT MODULE SCOPE, AND NOWHERE ELSE. Sylvannas forbids creating windows and menu
-- elements inside a render callback; doing so fails in the injector at runtime with no offline
-- signal at all. The render callback near the bottom of this file only ever calls `:render` on the
-- objects below. `core.menu.button` also requires a unique string id, so each one gets its own.
--
-- THERE IS EXACTLY ONE BUTTON, AND THAT IS THE POINT. The IDE is the only UI surface; the menu is
-- the door to it. The Recording, Resolve and Run buttons that used to live here are gone -- every
-- one of them stays reachable as a host verb below, and the IDE's editor panel is what will drive
-- them. A second control for a job the IDE also does is a control that drifts out of step with it.
local _menu_tree = core.menu.tree_node()

-- In-game IDE shell (ADR 09b U2). Required HERE, at module scope, and not lazily: the shell's
-- layout persistence is a set of `core.menu.slider_int` ghost elements built when this file is
-- required, and menu elements are the only resource that survives an injection (ADR 09b §2.3).
-- Deferring the require to first use would rebuild them mid-session, losing the saved layout.
-- `Shell.new` itself constructs nothing -- the window is built in the tick callback below.
local IdeShell = require("ui/shell")
local _ide_open_btn = core.menu.button("sentinel_open_ide")

-- Forward-declared so the shell can be built before `host_verbs` exists. The shell's empty state
-- offers an action (ADR 09b §5.5: an empty pane that instructs and then cannot be acted on is
-- still a dead end), and the only thing that can service it is a host verb.
local ide_action = nil
local _ide_shell = IdeShell.new({
    on_action = function(action_id)
        if ide_action then return ide_action(action_id) end
        return nil
    end,
})

local function log_error(message)
    if core and type(core.log_error) == "function" then
        pcall(core.log_error, "[Sentinel] " .. tostring(message))
    end
end

local function log_info(message)
    if core and type(core.log) == "function" then
        pcall(core.log, "[Sentinel] " .. tostring(message))
    end
end

-- ======================================================================
-- Diagnostics sink (C4) — the EventBus is otherwise write-only for these events
-- (see audit finding C4): module:fault (Wave-1 per-module tick isolation),
-- questing:error (profile-load failure), and module lifecycle/shutdown state
-- changes all publish into the void with zero subscribers. This is a THIN sink:
-- it only logs what already happened, it makes no decisions and changes no state.
-- ======================================================================
--- Subscribe the diagnostics sink to a given bus. Split out from ensure_diagnostics_wired (which
--- binds it to the module-level `app`) so it is a pure, directly testable unit: pass any EventBus
--- in, get the same three subscriptions out, no SentinelApp/IziBridge boot required.
local function wire_diagnostics(bus)
    if not bus then return end

    -- `phase` is logged because ModuleRegistry tags every fault with it "so the two are
    -- distinguishable at the receiving end" -- and this sink IS the receiving end. Formatting
    -- module/count/error alone made that claim false: a module that DIED AT BOOT (SHUTDOWN,
    -- refused reinitialisation, dead until the operator reloads) and a module that hiccupped on
    -- one tick (streak cleared by the next clean tick) produced byte-identical log lines.
    --
    -- An absent phase reads `unknown`, NOT `tick`. Defaulting to `tick` would round every
    -- unlabelled fault towards the milder, self-healing reading -- the one direction a boot death
    -- must never be rounded in.
    --
    -- WHAT THIS SINK CANNOT SEE: it observes only what was PUBLISHED. A fault raised before the
    -- bus exists, or on a different bus (`ensure_diagnostics_wired` binds exactly one), is
    -- invisible here regardless of its phase. It also cannot distinguish a module that recovered
    -- from one that stayed dead -- there is no recovery event; the cockpit's `system.module_faults`
    -- map is the only channel that carries that.
    bus:subscribe("module:fault", function(payload)
        payload = payload or {}
        log_error(string.format(
            "module:fault module=%s phase=%s count=%s error=%s",
            tostring(payload.module), tostring(payload.phase or "unknown"),
            tostring(payload.count or 1), tostring(payload.error)))
    end)

    bus:subscribe("questing:error", function(payload)
        payload = payload or {}
        log_error("questing:error " .. tostring(payload.error))
    end)

    bus:subscribe("module_state_changed", function(payload)
        payload = payload or {}
        log_info(string.format(
            "module_state_changed module=%s state=%s",
            tostring(payload.module), tostring(payload.state)))
    end)
end

local _diagnostics_subscribed = false

local function ensure_diagnostics_wired()
    if _diagnostics_subscribed then return end
    if not app or not app.get_event_bus then return end
    local bus = app:get_event_bus()
    if not bus then return end
    wire_diagnostics(bus)
    _diagnostics_subscribed = true
end

local function clear_module_cache()
    if not package or not package.loaded then return end
    local prefixes = { "runtime/", "core/bt/", "modules/", "shared/" }
    for key in pairs(package.loaded) do
        for _, prefix in ipairs(prefixes) do
            if key:sub(1, #prefix) == prefix then
                package.loaded[key] = nil
                break
            end
        end
    end
end

-- F1: `clear_module_cache()` used to run unconditionally at the top of `ensure_initialized`,
-- BEFORE the pcall, with no state tracking beyond `initialized`. Since `initialized` only
-- flips true on SUCCESS, a single init failure meant every subsequent frame (this is called
-- from every registered callback, ~60/s) nil'd out ~50 entries in `package.loaded` and forced
-- a full re-`require` of the runtime tree before even attempting init again — indistinguishable
-- from a client hang. The cache only needs clearing ONCE per script load (to pick up a
-- hot-reloaded source tree), not once per failed retry. `_cache_cleared` tracks that; the
-- explicit `reload()` path below still clears unconditionally, since that is a deliberate
-- "pick up new code" request, not a retry loop.
local _cache_cleared = false
local _cache_clear_count = 0 -- exposed for offline testing only (F1 regression guard)

-- Forward declaration: publication needs the host verbs, which are defined below because `reload`
-- has to re-publish after it stands a new app up.
local publish_surface

local function ensure_initialized()
    if initialized and app then
        return true
    end

    if not _cache_cleared then
        clear_module_cache()
        _cache_cleared = true
        _cache_clear_count = _cache_clear_count + 1
    end

    local ok, result = pcall(function()
        local next_app = SentinelApp:new()
        -- Publish BEFORE initialize (ADR 08 §14): the publish drain registers whatever pushed
        -- itself onto `__SentinelPending`, and `rotation.kernel_pending` must be visible before
        -- the combat module initialises — after, the module has already built its profile through
        -- Registry.resolve and the plugin path idles behind the double-drive guard for the whole
        -- session. The kernel components the surface exposes are all constructed in new(), so
        -- publishing here exposes nothing half-built.
        publish_surface(next_app)
        next_app:initialize()
        return next_app
    end)

    if not ok then
        if result ~= last_init_error then
            last_init_error = result
            log_error("Initialization failed: " .. tostring(result))
        end
        return false
    end

    app = result
    initialized = true
    last_init_error = nil
    ensure_diagnostics_wired()
    log_info("SentinelCore loaded (Combat Engine)")
    return true
end

-- ---------------------------------------------------------------------------
-- Host verbs on `_G.Sentinel` (ADR 08 §10)
-- ---------------------------------------------------------------------------
-- The kernel owns COMPONENTS -- control, state, events, intents, plugins -- and publishes them
-- behind live getters. It cannot own the verbs below, because it does not build the app: this file
-- does, and it is the only thing that can tear one down and stand a new one up. So the host
-- contributes them and the kernel refuses any name that collides with one of its own fields.
--
-- `app` is no longer assigned here. It resolves through a live getter on the surface, which is what
-- makes the old `_G.Sentinel.app = app` unnecessary -- and necessary to remove, since the published
-- surface is read-only by design.
--
-- `get_event_bus` and `get_blackboard` used to sit here too. Both had zero callers and duplicated
-- `Sentinel.events` / `Sentinel.state`, so they are deleted rather than carried: two ways to reach
-- one object is exactly how the surfaces drift apart again.
local host_verbs = {}

function host_verbs.combat()
    if ensure_initialized() then return app:get_module("combat") end
    return nil
end

function host_verbs.questing()
    if ensure_initialized() then
        local q = app:get_module("questing")
        -- Return inner QuestingModule for direct access
        return q and q._questing or nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- In-game IDE verbs (ADR 09b U2)
-- ---------------------------------------------------------------------------
-- The shell is deliberately independent of `app`: it holds no module, runs no rotation, and must
-- open even when initialisation has failed -- that is exactly when an operator wants to look at
-- something. So these verbs do not go through `ensure_initialized`.

--- @return boolean the new visibility
function host_verbs.toggle_ide()
    return _ide_shell:toggle()
end

--- The shell itself. This is how U3-U7 reach the switcher: `Sentinel.ide():register_panel{...}`.
--- Handing the object out rather than proxying each call means a later panel needs no edit to
--- this file, which is the whole point of the registration contract (ADR 09b §6).
function host_verbs.ide()
    return _ide_shell
end

--- Services the shell's empty-state actions. Assigned rather than declared so it closes over
--- `host_verbs`, which does not exist where the shell is constructed.
ide_action = function(action_id)
    if action_id == "start_recording" then return host_verbs.start_recording() end
    return nil
end

-- ADR 09b U2b: the seam between the shell (U2) and the Runner panel (U5).
--
-- REGISTRATION LIVES HERE, not in either of them. `shell.lua` may not name a panel and
-- `panels/runner.lua` may not reach for a module from inside a render callback, so the host is the
-- only place that can legitimately know the Runner drives questing. `ui/ide_panels.lua` holds that
-- knowledge; this line is only the host handing it a shell and a way to find the module.
--
-- The resolver is a FUNCTION on purpose. `reload()` tears the app down and stands a new one up, and
-- `toggle_ide` deliberately opens the IDE without `ensure_initialized` — so "the questing module"
-- has to be looked up per refresh, and answering nil has to be normal rather than an error.
local IdePanels = require("ui/ide_panels")

-- ONE QueryClient for the whole IDE, built here because the host owns service topology and the
-- panels must not. Every data panel shares this instance on purpose: QueryClient is request-and-
-- cache, so a single path-keyed cache and in-flight table means Explorer and Properties asking for
-- `/npc/567` in the same frame produce one request, not two.
--
-- A TABLE, NOT A RESOLVER. `questing` above is a function because `reload()` tears the app down and
-- stands a new one up, so "the questing module" has to be looked up per refresh. QueryClient has no
-- such lifecycle -- it is a plain HTTP client with no reference into the app graph, so re-deriving
-- it per tick would only throw away its cache. The binding docs in ide_panels.lua say `table|nil`
-- for exactly this reason.
--
-- Constructing it costs nothing and touches no SDK surface: `QueryClient:new` only fills a table.
-- The first `core.http_get` happens on the first fetch, from a tick callback, never from render.
-- No explicit host/port: `QueryClient:new()` reads sentinel/config/query_server.lua, so a hosted
-- deployment (installer-written config) and a local dev box are both honoured without editing code.
local QueryClient = require("shared/query_client")
local _ide_query_client = QueryClient:new()

-- And ONE EditorClient for the campaign editor at :3031. PR1 deliberately left this line out
-- rather than pass a `deps.editor_client` that resolved to nil, because a nil-valued dependency is
-- exactly the silent contract this change exists to remove; `shared/editor_client.lua` did not
-- exist yet. It does now, so the line lands here, where the host already owns service topology.
--
-- A separate client from the one above, not a second port on the same one: the QueryServer serves
-- static game data that can be cached forever, while the editor's campaigns change because this
-- client changes them, and the two must not share a cache.
local EditorClient = require("shared/editor_client")
local _ide_editor_client = EditorClient:new("127.0.0.1", 3031)

local _ide_bindings = IdePanels.install(_ide_shell, {
    questing = function() return host_verbs.questing() end,
    query_client = _ide_query_client,
    editor_client = _ide_editor_client,
})
if not _ide_bindings then
    log_error("IDE runner panel failed to register; the IDE will open with an empty switcher")
end

-- ---------------------------------------------------------------------------
-- Recording Mode verbs (ADR 09a W12)
-- ---------------------------------------------------------------------------
-- These are driven from outside the client through the debug bridge (`game_eval` against
-- `_G.Sentinel`), where an uncaught error returns NOTHING to the operator -- not a message, not a
-- stack. So an unavailable module is answered, never thrown, and every answer is a table carrying a
-- reason rather than a bare boolean the caller cannot act on.
local RECORDING_UNAVAILABLE = "questing module unavailable"

--- Resolve the inner QuestingModule, or nil. Goes through `host_verbs.questing` rather than
--- re-deriving it so there is one definition of "the questing module" on this surface.
local function recording_target(verb)
    local questing = host_verbs.questing()
    if questing and type(questing[verb]) == "function" then
        return questing
    end
    return nil
end

--- @param name string|nil defaults to "<zone> <timestamp>"
--- @return table `{ ok, name, started_at }` or `{ ok = false, reason }`
function host_verbs.start_recording(name)
    local questing = recording_target("start_recording")
    if not questing then return { ok = false, reason = RECORDING_UNAVAILABLE } end
    local result = questing:start_recording(name)
    log_info(result.ok
        and ("recording started: " .. tostring(result.name))
        or ("recording not started: " .. tostring(result.reason)))
    return result
end

--- @return table `{ ok, name, nodes, campaign }` or `{ ok = false, reason }`
function host_verbs.stop_recording()
    local questing = recording_target("stop_recording")
    if not questing then return { ok = false, reason = RECORDING_UNAVAILABLE } end
    local result = questing:stop_recording()
    log_info(result.ok
        and ("recording stopped: " .. tostring(result.name) .. " (" .. tostring(result.nodes) .. " tasks)")
        or ("recording not stopped: " .. tostring(result.reason)))
    return result
end

--- @return table `{ recording, name, nodes, started_at }`
function host_verbs.recording_status()
    local questing = recording_target("recording_status")
    if not questing then return { recording = false, nodes = 0, reason = RECORDING_UNAVAILABLE } end
    return questing:recording_status()
end

--- @param path string|nil defaults to sentinel/data/recordings/<slug>.json
--- @return table `{ ok, path, name, nodes }` or `{ ok = false, reason }`
function host_verbs.save_recording(path)
    local questing = recording_target("save_recording")
    if not questing then return { ok = false, reason = RECORDING_UNAVAILABLE } end
    local result = questing:save_recording(path)
    log_info(result.ok
        and ("recording saved: " .. tostring(result.path))
        or ("recording not saved: " .. tostring(result.reason)))
    return result
end

-- ---------------------------------------------------------------------------
-- Resolve-and-run verbs (ADR 09a W13)
-- ---------------------------------------------------------------------------
-- What closes the loop. Without these, a recording saved in game had to be carried out of the client
-- by hand -- curled against QueryServer and dropped into the profile directory -- before the route
-- the author had just walked could be run. Same rules as the recording verbs above: an unavailable
-- module is answered, never thrown.

--- Resolve a saved recording through QueryServer and leave the plan where the runner looks.
---
--- ASYNCHRONOUS. `core.http_post` returns before the server answers and there is no blocking form,
--- so `{ ok = true, status = "pending" }` means the request LEFT, not that the plan exists; poll
--- `Sentinel.resolve_status()` or subscribe to `questing:recording_resolved`.
--- @param name string|nil campaign name, file name, or path; defaults to this session's recording
--- @return table `{ ok, status, path, plan_path, diagnostics }`
function host_verbs.resolve_recording(name)
    local questing = recording_target("resolve_recording")
    if not questing then return { ok = false, status = "unavailable", reason = RECORDING_UNAVAILABLE } end
    local result = questing:resolve_recording(name)
    -- The diagnostic count is logged even on success: a 200 carrying diagnostics is a plan that
    -- lowered AND a route with holes, and an operator who only ever sees "resolved" never learns
    -- there was anything to fix.
    local diagnostics = result.diagnostics
    log_info(result.ok
        and string.format("resolve %s: %s (%d diagnostic(s))",
            tostring(result.status), tostring(result.plan_path),
            (diagnostics and diagnostics.count) or 0)
        or ("resolve failed [" .. tostring(result.status) .. "]: " .. tostring(result.reason)))
    if diagnostics and diagnostics.messages then
        for _, message in ipairs(diagnostics.messages) do log_info("  " .. tostring(message)) end
    end
    return result
end

--- @return table the last resolution, or `{ status = "idle" }`
function host_verbs.resolve_status()
    local questing = recording_target("resolve_status")
    if not questing then return { status = "unavailable", reason = RECORDING_UNAVAILABLE } end
    return questing:resolve_status()
end

--- @param name string|nil profile stem, file name, or path; defaults to the last plan resolved
--- @return table `{ ok, status, plan_path }`
function host_verbs.run_plan(name)
    local questing = recording_target("run_plan")
    if not questing then return { ok = false, status = "unavailable", reason = RECORDING_UNAVAILABLE } end
    local result = questing:run_plan(name)
    log_info(result.ok
        and ("running plan: " .. tostring(result.plan_path))
        or ("plan not started: " .. tostring(result.reason)))
    return result
end

function host_verbs.reload()
    log_info("Forcing full reload...")
    if app and type(app.shutdown) == "function" then
        pcall(app.shutdown, app)
    end
    app = nil
    initialized = false
    last_init_error = nil
    clear_module_cache()
    _cache_cleared = true -- already cleared above; ensure_initialized must not clear again
    _cache_clear_count = _cache_clear_count + 1
    local ok, result = pcall(function()
        local next_app = SentinelApp:new()
        -- Publish BEFORE initialize (ADR 08 §14): the publish drain registers whatever pushed
        -- itself onto `__SentinelPending`, and `rotation.kernel_pending` must be visible before
        -- the combat module initialises — after, the module has already built its profile through
        -- Registry.resolve and the plugin path idles behind the double-drive guard for the whole
        -- session. The kernel components the surface exposes are all constructed in new(), so
        -- publishing here exposes nothing half-built.
        publish_surface(next_app)
        next_app:initialize()
        return next_app
    end)
    if ok then
        app = result
        initialized = true
        publish_surface(app)
        _diagnostics_subscribed = false -- re-subscribe with new event bus
        ensure_diagnostics_wired()
        log_info("Reloaded successfully")
        return true
    else
        log_error("Reload failed: " .. tostring(result))
        return false
    end
end

--- Assigns the forward-declared local. `_G.Sentinel` therefore appears on the first successful
--- init rather than at load: a plugin that loads before us registers through the
--- `__SentinelPending` queue, which exists for precisely that ordering (ADR 08 §2.4).
publish_surface = function(instance)
    return instance:publish_api(host_verbs)
end

core.register_on_pre_tick_callback(function()
    if ensure_initialized() then
        app:on_pre_tick()
    end
end)

local _last_ide_tick_error = nil
core.register_on_update_callback(function()
    if ensure_initialized() then app:on_update() end
    -- The IDE shell's whole tick surface: window creation, the Escape/keybind edges, the combat
    -- read that suppresses motion, and the ghost-slider writes. All of it belongs here because
    -- Sylvannas forbids constructing windows and menu elements in a render callback, and because
    -- ADR 09b §2.4 keeps the render path free of everything that is not paint.
    local ide_ok, ide_err = pcall(function() _ide_shell:on_tick() end)
    if not ide_ok then
        local msg = "IDE shell tick failed: " .. tostring(ide_err)
        if msg ~= _last_ide_tick_error then
            _last_ide_tick_error = msg
            log_error(msg)
        end
    else
        _last_ide_tick_error = nil
    end
end)

core.register_on_spell_cast_callback(function(data)
    if ensure_initialized() then app:on_spell_cast(data) end
end)

core.register_on_legit_spell_cast_callback(function(data)
    if ensure_initialized() then app:on_legit_spell_cast(data) end
end)

-- Optional render callbacks (no-op by default, registered for extensibility)
core.register_on_render_callback(function()
    if ensure_initialized() then app:on_render() end
end)

local _last_ide_render_error = nil
core.register_on_render_window_callback(function()
    if ensure_initialized() then app:on_render_window() end
    local ide_ok, ide_err = pcall(function() _ide_shell:_on_render_window() end)
    if not ide_ok then
        local msg = "IDE shell render failed: " .. tostring(ide_err)
        if msg ~= _last_ide_render_error then
            _last_ide_render_error = msg
            log_error(msg)
        end
    else
        _last_ide_render_error = nil
    end
end)

-- Sentinel menu entry
core.register_on_render_menu_callback(function()
    if not ensure_initialized() then return end
    _menu_tree:render("SentinelCore", function()
        if _ide_open_btn:render("Open IDE") then
            host_verbs.toggle_ide()
        end
        -- ADR 09b §5.2: "Escape closes, a keybind toggles. Hands stay near movement keys." The
        -- element is built at module scope inside ui/shell.lua; this only renders it, and only
        -- when it exists -- it does not in a test harness that stubs a partial `core.menu`.
        local ide_keybind = IdeShell.elements and IdeShell.elements.toggle_keybind
        if ide_keybind then
            ide_keybind:render("Toggle IDE")
        end
    end)
end)

local function on_unload()
    -- The shell drops its window but survives as an object: its ghost sliders are module-scope
    -- menu elements that outlive the unload, and rebuilding them would mean rebuilding elements
    -- with ids Sylvannas already holds.
    pcall(_ide_shell.destroy, _ide_shell)
    if app and type(app.shutdown) == "function" then
        app:shutdown()
    end
    app = nil
    initialized = false
    _diagnostics_subscribed = false
    _G.Sentinel = nil
end

return {
    name = "SentinelCore",
    version = "0.2.0",
    unload = on_unload,
    -- Exposed for offline tests only (tests/test_main_diagnostics.lua): lets the diagnostics
    -- sink be exercised against a real EventBus without booting the injector-only IziBridge.
    _wire_diagnostics_for_test = wire_diagnostics,
    -- Exposed for offline tests only (F1 regression guard, tests/test_main_diagnostics.lua):
    -- lets a test drive the real ensure_initialized() retry path and observe how many times
    -- the module cache actually got cleared.
    _ensure_initialized_for_test = ensure_initialized,
    _cache_clear_count_for_test = function() return _cache_clear_count end,
}
