-- ============================================================
-- RealSiloDebug.lua
--
-- Debug-logging schakelaar. Standaard UIT.
-- Inschakelen: installeer de companion-mod FS25_RealSilo_Debug.
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
