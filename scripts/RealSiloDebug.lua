-- ============================================================
-- RealSiloDebug.lua
--
-- Debug-logging schakelaar. Standaard UIT.
-- Inschakelen: installeer de companion-mod FS25_RealSilo_Debug.
--
-- Elke mod draait in FS25 in een eigen Lua-omgeving, dus globale
-- variabelen zijn niet gedeeld. Daarom detecteert de hoofdmod zelf
-- of de companion geladen is, via g_modIsLoaded / g_modManager.
-- ============================================================

RealSiloDebug = {}
RealSiloDebug.enabled = false

function RealSiloDebug.print(fmt, ...)
    if not RealSiloDebug.enabled then return end
    if select("#", ...) > 0 then
        print(string.format(fmt, ...))
    else
        print(fmt)
    end
end

function RealSiloDebug.setEnabled(value)
    RealSiloDebug.enabled = (value == true)
end

local function isDebugModLoaded()
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_RealSilo_Debug"] then
        return true
    end
    if g_modManager ~= nil and g_modManager.getModByName ~= nil then
        local ok, mod = pcall(function()
            return g_modManager:getModByName("FS25_RealSilo_Debug")
        end)
        if ok and mod ~= nil then return true end
    end
    return false
end

local function updateDebugState(context)
    if not RealSiloDebug.enabled and isDebugModLoaded() then
        RealSiloDebug.enabled = true
        print("[realSilo] Debug-logging AAN (companion-mod gedetecteerd - " .. tostring(context) .. ")")
    end
end

updateDebugState("laden")

if Mission00 ~= nil and Mission00.onStartMission ~= nil then
    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
        updateDebugState("mission-start")
    end)
end
