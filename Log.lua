-- Ring-buffer logger -> GOBIGnINTERRUPTLog SV.
-- Usage: GBI.Log.Info("module", "fmt %d", arg) / .Warn / .Err / .Debug

GOBIGnINTERRUPT = GOBIGnINTERRUPT or {}
local GBI = GOBIGnINTERRUPT
GBI.Log = GBI.Log or {}

local LEVELS    = { DEBUG = 1, INFO = 2, WARN = 3, ERR = 4 }
local LEVEL_TAG = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERR" }
local MAX_LINES = 500   -- ring buffer cap; older entries roll off

local function ensure()
    GOBIGnINTERRUPTLog = GOBIGnINTERRUPTLog or { lines = {}, head = 1 }
    GOBIGnINTERRUPTLog.lines = GOBIGnINTERRUPTLog.lines or {}
    GOBIGnINTERRUPTLog.head  = GOBIGnINTERRUPTLog.head  or 1
    return GOBIGnINTERRUPTLog
end

local function push(level, mod, msg)
    local buf  = ensure()
    local line = ("%.3f [%s] %s: %s"):format(GetTime(), LEVEL_TAG[level], mod, msg)
    buf.lines[buf.head] = line
    buf.head = (buf.head % MAX_LINES) + 1
    return line
end

-- Stringify one value without ever throwing on a secret. issecretvalue is
-- checked first (a tagged value's tostring can itself be tagged / throw),
-- then tostring under pcall, falling back to a placeholder.
local function safeStr(v)
    if GBI.Taint and GBI.Taint.IsSecret and GBI.Taint.IsSecret(v) then
        return "<secret>"
    end
    local ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return "<secret>"
end

local function fmt(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    if n == 1 then return safeStr((...)) end
    -- Try string.format; if any arg is secret it throws and we fall back to
    -- per-arg safe stringification so a debug log never becomes a crash.
    local ok, s = pcall(string.format, ...)
    if ok and type(s) == "string" then return s end
    local args = { ... }
    local parts = {}
    for i = 1, n do parts[i] = safeStr(args[i]) end
    return table.concat(parts, " ")
end

function GBI.Log.Debug(mod, ...)
    if not (GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.debug) then return end
    local line = push(LEVELS.DEBUG, mod, fmt(...))
    print("|cff888888GBI|r " .. line)
end

function GBI.Log.Info(mod, ...)
    local line = push(LEVELS.INFO, mod, fmt(...))
    if GOBIGnINTERRUPTDB and GOBIGnINTERRUPTDB.debug then
        print("|cff33ff99GBI|r " .. line)
    end
end

function GBI.Log.Warn(mod, ...)
    local line = push(LEVELS.WARN, mod, fmt(...))
    print("|cffffaa00GBI|r " .. line)
end

function GBI.Log.Err(mod, ...)
    local line = push(LEVELS.ERR, mod, fmt(...))
    print("|cffff5555GBI|r " .. line)
end

-- Dump last N lines via /gbi log.
function GBI.Log.Dump(n)
    local buf = ensure()
    n = tonumber(n) or 50
    local out = {}
    -- newest first: walk back from head
    for i = 0, math.min(n, MAX_LINES) - 1 do
        local idx = ((buf.head - 2 - i) % MAX_LINES) + 1
        local line = buf.lines[idx]
        if line then out[#out + 1] = line end
    end
    for i = #out, 1, -1 do print(out[i]) end
end

function GBI.Log.Clear()
    GOBIGnINTERRUPTLog = { lines = {}, head = 1 }
end
