-- ============================================================
-- realSiloActivatable.lua  v12
--
-- run() opent de GUI dialoog en geeft de placeable mee zodat het
-- overzicht de echte storage kan lezen.
--
-- Geschiedenis van de MoistureSystem-compatibiliteitsfix:
--   v10: eigen toets (REALSILO_CONFIGURE) via registerCustomInput.
--        Bleek in de praktijk niet zichtbaar te worden (vermoedelijk
--        een stille keybind-conflict tussen de tientallen andere
--        actieve mods) — de speler zag de nieuwe toets nooit.
--   v11: permanent geregistreerde globale toets, los van
--        activatableObjectsSystem. Zelfde resultaat: geen zichtbaar
--        effect.
--   v12: terug naar de BEWEZEN werkende weg. Uit gebruikerstest bleek
--        de bestaande generieke activatable-prompt (de vaste
--        interactietoets van het spel, geen eigen binding) prima te
--        werken bij een lege silo. Bij een silo met product verliest
--        hij van FS25_MoistureSystem se "Start Drying"-activatable,
--        die op dezelfde silo (dezelfde rootNode → gegarandeerd
--        gelijke afstand) ook meedingt. De winnaar bij gelijke
--        afstand lijkt willekeurig/registratie-afhankelijk te zijn.
--        Oplossing: geef RealSiloActivatable een kleine, vaste
--        afstand-voorsprong (epsilon) in getDistance(), zodat het
--        de vergelijking nooit meer kan verliezen — zonder een
--        nieuwe toets, dus zonder nieuw conflict-risico.
-- ============================================================

RealSiloActivatable = {}
local RealSiloActivatable_mt = Class(RealSiloActivatable)

-- Voorsprong (in meters) t.o.v. andere activatables op exact dezelfde
-- silo, zodat RealSilo's prompt altijd wint bij een afstand-gelijkspel.
local DISTANCE_ADVANTAGE = 0.1

function RealSiloActivatable.new(placeable)
    local self = setmetatable({}, RealSiloActivatable_mt)
    self.placeable    = placeable
    self.activateText = g_i18n:getText("realSilo_configureAction")
    return self
end

function RealSiloActivatable:getIsActivatable()
    return g_currentMission:getFarmId() == self.placeable:getOwnerFarmId()
end

function RealSiloActivatable:getDistance(x, y, z)
    local p = self.placeable
    if p.rootNode ~= nil and p.rootNode ~= 0 then
        local tx, ty, tz = getWorldTranslation(p.rootNode)
        local d = MathUtil.vector3Length(x - tx, y - ty, z - tz)
        return math.max(0, d - DISTANCE_ADVANTAGE)
    end
    return math.huge
end

function RealSiloActivatable:run()
    local uid = self.placeable.realSiloUniqueId
    print(string.format("[realSilo][DIAG] RealSiloActivatable:run() aangeroepen, uid=%s", tostring(uid)))
    if not uid then return end
    RealSiloDialog.show(uid, self.placeable)
end
