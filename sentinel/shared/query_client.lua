--- Sentinel Query Client
--- HTTP client for QueryServer (port 3030)
--- Communicates with the SentinelQueryServer Rust backend to resolve NPCs, quests, vendors

local QueryClient = {}
QueryClient.__index = QueryClient

-- The Sylvannas sandbox has NO global `JSON` — relying on it meant every in-game query
-- silently returned nil (the same bug runtime_profile.lua had with profile parsing).
-- Prefer the shipped pure-Lua parser; fall back to an injected global only for harnesses
-- that supply one.
local JsonLib = (function()
    local ok, mod = pcall(require, "core/JSON")
    if ok and type(mod) == "table" and mod.decode then
        return mod
    end
    return nil
end)()

local function json_decode(str)
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

---URL-encode a query parameter. Spaces become %20; unsafe characters become %XX.
local function url_encode(str)
    str = tostring(str or "")
    return (str:gsub("([^A-Za-z0-9%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Negative-cache sentinel: a resolved 404/parse failure returns nil FAST forever after,
-- instead of re-requesting every tick.
local NOT_FOUND = "__not_found__"

-- The historical default endpoint. A HOSTED deployment overrides it by shipping a
-- `sentinel/config/query_server.lua` returning `{ host = ..., port = ... }` (mirrors
-- SentinelNavClient/config/server.lua for NavServer); the thin-client installer writes that file.
-- When the config is absent or malformed we fall back to a local QueryServer, so the offline
-- suite and a default dev box behave exactly as before. Explicit `:new(host, port)` args (used by
-- the editor client at :3031 and by tests) always win over the config.
local DEFAULT_HOST, DEFAULT_PORT = "127.0.0.1", 3030

local function config_endpoint()
    local ok, cfg = pcall(require, "config/query_server")
    if ok and type(cfg) == "table" then
        local host = (type(cfg.host) == "string" and cfg.host ~= "") and cfg.host or nil
        local port = tonumber(cfg.port)
        return host or DEFAULT_HOST, port or DEFAULT_PORT
    end
    return DEFAULT_HOST, DEFAULT_PORT
end

function QueryClient:new(host, port)
    local o = setmetatable({}, QueryClient)
    local cfg_host, cfg_port = config_endpoint()
    o._host = host or cfg_host
    o._port = port or cfg_port
    o._cache = {}
    o._inflight = {}
    return o
end

function QueryClient:_url(path)
    return string.format("http://%s:%d%s", self._host, self._port, path)
end

--- Request-and-cache fetch. The LIVE core.http_get is ASYNC — `(url, callback)`, with the
--- one-argument synchronous form raising "function expected" (verified in-game
--- 2026-07-23; the old sync call meant QueryClient never returned data in-game at all).
--- First call fires the request and usually returns (nil, true) = pending; callers poll
--- again next tick — which is exactly the executor's retry/waiting model. Offline
--- harnesses with synchronous mocks (either signature) resolve immediately.
--- @return table|nil result, boolean|nil pending
function QueryClient:_get(path)
    if not (core and core.http_get) then return nil end
    self._cache = self._cache or {}
    self._inflight = self._inflight or {}

    local cached = self._cache[path]
    if cached ~= nil then
        if cached == NOT_FOUND then return nil end
        return cached
    end
    if self._inflight[path] then
        return nil, true
    end

    local url = self:_url(path)
    local client = self
    self._inflight[path] = true
    local ok, sync_body = pcall(core.http_get, url, function(http_code, _content_type, body)
        client._inflight[path] = nil
        if http_code == 200 and type(body) == "string" then
            local decoded = json_decode(body)
            client._cache[path] = decoded ~= nil and decoded or NOT_FOUND
        else
            client._cache[path] = NOT_FOUND
        end
    end)

    if not ok then
        -- Legacy offline mock with the old single-argument synchronous signature.
        self._inflight[path] = nil
        local ok2, resp = pcall(core.http_get, url)
        if ok2 and type(resp) == "string" then
            local decoded = json_decode(resp)
            self._cache[path] = decoded ~= nil and decoded or NOT_FOUND
            if decoded then return decoded end
        end
        return nil
    end

    -- Synchronous mock that accepted (url, callback) but returned the body directly.
    if type(sync_body) == "string" then
        self._inflight[path] = nil
        local decoded = json_decode(sync_body)
        if decoded then
            self._cache[path] = decoded
            return decoded
        end
    end

    -- The live client may have run the callback before http_get returned; honor it.
    cached = self._cache[path]
    if cached ~= nil then
        if cached == NOT_FOUND then return nil end
        return cached
    end
    return nil, true
end

-- Declared even though `/resolve` reads the body as raw bytes: a POST that announces nothing is one
-- a proxy, or a future strict handler, is entitled to reject — and that rejection would arrive as an
-- opaque 400 the operator would spend the evening blaming their recording for.
local JSON_HEADERS = { ["Content-Type"] = "application/json" }

--- One-shot POST, answered through `on_complete(http_code, body)`.
---
--- NOT cached the way `_get` is: a POST's answer depends on the body it carried, so a path-keyed
--- cache would hand the second recording the first one's plan.
---
--- `core.http_post` is ASYNCHRONOUS — `(url, [headers,] body, callback)`, returning before the
--- server has answered (docs/SylvannasAPI/dev/api/core.md). There is no synchronous form, and
--- waiting for one inside a tick would stall the game client, so this returns as soon as the
--- request is dispatched and the CALLER owns the wait. `http_code` is 0 on transport failure, which
--- is the only way to tell "QueryServer is not running" from "QueryServer said no".
---
--- The headers form is tried first and the three-argument form is the fallback. This is not
--- defensive padding: `_get` above records that the live `core.http_get` raises "function expected"
--- on the signature this tree assumed, and that failure was invisible offline for months.
--- @return string|nil "dispatched", or nil plus the reason the request never left
function QueryClient:post(path, body, on_complete)
    if not (core and core.http_post) then
        return nil, "core.http_post is unavailable in this sandbox"
    end
    if type(body) ~= "string" or body == "" then
        return nil, "refusing to POST an empty body"
    end
    if type(on_complete) ~= "function" then
        return nil, "a POST with no completion handler discards the server's answer"
    end

    local url = self:_url(path)
    local delivered = false
    local function deliver(http_code, _content_type, response)
        -- A transport that both invokes the callback and returns the body would otherwise answer
        -- twice, and the second answer would overwrite a good result with a guessed one.
        if delivered then return end
        delivered = true
        on_complete(tonumber(http_code) or 0, type(response) == "string" and response or nil)
    end

    local ok, sync_body = pcall(core.http_post, url, JSON_HEADERS, body, deliver)
    if not ok then
        local ok3, sync3 = pcall(core.http_post, url, body, deliver)
        if not ok3 then
            return nil, "core.http_post rejected the request: " .. tostring(sync3)
        end
        sync_body = sync3
    end

    -- Legacy offline mocks return the body straight from the call instead of invoking the callback.
    -- Nothing in the live client does this, which is why the status is assumed rather than read.
    if type(sync_body) == "string" and not delivered then
        deliver(200, nil, sync_body)
    end

    return "dispatched"
end

--- Drop every cached path beginning with `prefix`, and abandon the in-flight requests under it.
---
--- `_get` is a path-keyed cache with a negative-cache sentinel, which is exactly right for the
--- QueryServer's static game data and exactly WRONG for the editor at :3031, whose graphs change
--- because this client changed them. Without this, a campaign fetched once would keep answering the
--- pre-write graph for the life of the session, and a campaign that did not exist yet would keep
--- answering NOT_FOUND after being created.
---
--- Dropping the in-flight marker matters as much as dropping the cache: a read that was already in
--- the air when the write landed will resolve into the cache with pre-write data, so the next
--- `_get` must be free to issue a fresh request rather than wait on that one.
---@param prefix string|nil a path prefix; nil or "" clears everything
---@return number cleared how many cached paths were dropped
function QueryClient:invalidate(prefix)
    prefix = tostring(prefix or "")
    local cleared = 0
    for path in pairs(self._cache or {}) do
        if prefix == "" or path:sub(1, #prefix) == prefix then
            self._cache[path] = nil
            cleared = cleared + 1
        end
    end
    for path in pairs(self._inflight or {}) do
        if prefix == "" or path:sub(1, #prefix) == prefix then
            self._inflight[path] = nil
        end
    end
    return cleared
end

function QueryClient:search_quests(query)
    return self:_get("/quests/search?q=" .. url_encode(query))
end

function QueryClient:get_quest(quest_id)
    return self:_get("/quest/" .. tostring(quest_id))
end

function QueryClient:search_npcs(query)
    return self:_get("/npc/search?q=" .. url_encode(query))
end

function QueryClient:get_npc(entry)
    return self:_get("/npc/" .. tostring(entry))
end

function QueryClient:get_vendor(entry)
    return self:_get("/vendor/" .. tostring(entry))
end

function QueryClient:get_trainer(entry)
    return self:_get("/trainer/" .. tostring(entry))
end

function QueryClient:get_flight(entry)
    return self:_get("/flight/" .. tostring(entry))
end

function QueryClient:get_object(entry)
    return self:_get("/object/" .. tostring(entry))
end

--- Static item facts (name, quality, sell_price). The live SDK has no item-quality API,
--- so grey detection for vendor selling rides on this endpoint.
function QueryClient:get_item(entry)
    return self:_get("/item/" .. tostring(entry))
end

function QueryClient:creatures_in_polygon(polygon)
    return self:_get("/creatures/polygon?polygon=" .. tostring(polygon))
end

function QueryClient:get_quest_chain(quest_id)
    return self:_get("/quest/" .. tostring(quest_id) .. "/chain")
end

function QueryClient:get_quest_objectives(quest_id)
    return self:_get("/quest/" .. tostring(quest_id) .. "/objectives")
end

---GET /zone/{id}/spawns — real spawn aggregation for a zone.
function QueryClient:get_zone_spawns(zone_id)
    return self:_get("/zone/" .. tostring(zone_id) .. "/spawns")
end

---GET /spawns/density/{zone} — density bands, safe spots, and XP estimates.
function QueryClient:get_spawn_density(zone_id)
    return self:_get("/spawns/density/" .. tostring(zone_id))
end

return QueryClient