-- sentinel/config/query_server.lua
-- QueryServer connection defaults for the in-game runtime and IDE.
--
-- The runtime's QueryClient (sentinel/shared/query_client.lua) reads this file to decide which
-- SentinelQueryServer to resolve against. A LOCAL install leaves the defaults below; a HOSTED
-- install rewrites host/port to point at the shared server. The thin-client installer
-- (scripts/install.ps1) writes this file, exactly as it writes SentinelNavClient/config/server.lua
-- for NavServer.
--
-- QueryServer is an OPTIONAL enhancement at play-time: it powers off-draw-distance NPC spawn
-- fallback and vendor grey-selling (item quality). If it is unreachable the runtime degrades
-- gracefully -- runtime_profile.lua's "Static source 2" lookup is pcall-guarded -- so a client
-- with no QueryServer at all still quests from the compiled profile.
--
-- host: hostname or IP of the QueryServer (no scheme, no port).
-- port: TCP port the QueryServer listens on (matches SENTINEL_QUERY_BIND/PORT on the server).
return {
    host = "127.0.0.1",
    port = 3030,
}
