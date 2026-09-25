-- sentinel/tests/shared/test_query_client_config.lua
-- The QueryServer endpoint is configurable so a HOSTED deployment works without a code edit.
-- QueryClient:new() reads sentinel/config/query_server.lua; explicit args still win; a missing or
-- malformed config falls back to the historical 127.0.0.1:3030 so the default dev box is unchanged.

local T = require("tests/test_util")

local M = {}

local CONFIG_KEY = "config/query_server"

-- Force the next `require(CONFIG_KEY)` (inside QueryClient:new) to see `cfg`, and force
-- query_client itself to be re-required so its module-local default helper re-runs cleanly.
local function with_config(cfg, fn)
    local saved_cfg = package.loaded[CONFIG_KEY]
    local saved_qc = package.loaded["shared/query_client"]
    package.loaded[CONFIG_KEY] = cfg
    package.loaded["shared/query_client"] = nil
    local QueryClient = require("shared/query_client")
    local ok, err = pcall(fn, QueryClient)
    -- Restore both so later suites keep resolving the real shipped config / cached module.
    package.loaded[CONFIG_KEY] = saved_cfg
    package.loaded["shared/query_client"] = saved_qc
    if not ok then error(err) end
end

function M.run()
    print("=== QueryClient endpoint config Tests ===")

    print("Test 1: the shipped config file resolves to a local QueryServer by default")
    do
        -- Uses the REAL sentinel/config/query_server.lua on disk (not an injected double).
        package.loaded["shared/query_client"] = nil
        local QueryClient = require("shared/query_client")
        local qc = QueryClient:new()
        T.assert_equal(qc._host, "127.0.0.1", "default host must come from the shipped config")
        T.assert_equal(qc._port, 3030, "default port must come from the shipped config")
        T.assert_equal(qc:_url("/health"), "http://127.0.0.1:3030/health", "URL uses configured endpoint")
    end
    print("  PASS")

    print("Test 2: a hosted config overrides host and port")
    with_config({ host = "query.example.net", port = 4040 }, function(QueryClient)
        local qc = QueryClient:new()
        T.assert_equal(qc._host, "query.example.net", "hosted host must be honoured")
        T.assert_equal(qc._port, 4040, "hosted port must be honoured")
        T.assert_equal(qc:_url("/npc/1"), "http://query.example.net:4040/npc/1", "URL targets hosted server")
    end)
    print("  PASS")

    print("Test 3: explicit constructor args win over the config")
    with_config({ host = "query.example.net", port = 4040 }, function(QueryClient)
        local qc = QueryClient:new("127.0.0.1", 3031)
        T.assert_equal(qc._host, "127.0.0.1", "explicit host overrides config (this is how EditorClient pins :3031)")
        T.assert_equal(qc._port, 3031, "explicit port overrides config")
    end)
    print("  PASS")

    print("Test 4: a malformed or empty config falls back to the historical default")
    with_config({ host = "", port = "not-a-number" }, function(QueryClient)
        local qc = QueryClient:new()
        T.assert_equal(qc._host, "127.0.0.1", "empty host falls back to 127.0.0.1")
        T.assert_equal(qc._port, 3030, "non-numeric port falls back to 3030")
    end)
    print("  PASS")

    print("Test 5: a non-table config value is ignored (defensive against a malformed return)")
    with_config(42, function(QueryClient)
        -- A truthy non-table short-circuits `require`, so config_endpoint sees `42`, not the file;
        -- its `type(cfg) == "table"` guard must reject it and fall back rather than crash.
        local qc = QueryClient:new()
        T.assert_equal(qc._host, "127.0.0.1", "non-table config falls back to 127.0.0.1")
        T.assert_equal(qc._port, 3030, "non-table config falls back to 3030")
    end)
    print("  PASS")

    print("\n=== All QueryClient endpoint config Tests PASSED ===")
end

return M
