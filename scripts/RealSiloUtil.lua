-- ============================================================
-- RealSiloUtil.lua
--
-- isFarmSiloStorage / isFarmSiloPlaceableSilo / isFarmSiloPlaceableExtension:
--   Controleren of een storage/placeable minstens één fillType uit de
--   "farmSilo" categorie ondersteunt. We gebruiken hiervoor de RUNTIME
--   fillTypes die Giants al heeft ingeladen op basis van het
--   fillTypeCategories-attribuut in de placeable-XML, in plaats van de
--   XML zelf opnieuw te parsen (dat is foutgevoelig qua paden/indexering).
--   Deze aanpak werkt altijd correct, ongeacht hoe fillTypeCategories
--   is opgegeven, en geeft op server en client identiek resultaat
--   (beide laden dezelfde gedeelde mod-/placeable-bestanden).
--
--   Resultaat: silo's/extensions zonder farmSilo-fillType (bv.
--   dieseltanks, watertanks) worden door realSilo volledig genegeerd:
--   geen registratie, geen storage-vervanging, geen menu.
--
-- resolveDisplayName:
--   Leest storeData/name van een placeable. Is die afwezig, leeg, of
--   een niet-vertaalde "$l10n_..."-referentie, dan wordt een
--   fallback-tekst gebruikt (via l10n-key, met een laatste hard-coded
--   fallback als die key ontbreekt).
-- ============================================================

RealSiloUtil = {}

-- ------------------------------------------------------------------
-- Bepalen of een storage een graansilo is die de mod moet beheren.
--
-- De juiste bron van waarheid is de fillType-categorie "FARMSILO".
-- Dat is precies waarvoor Giants die categorie heeft: het bepaalt
-- welke producten in een boerderijsilo mogen. Maps die eigen
-- graansoorten toevoegen (RYE, TRITICALE, SPELT, WINTERWHEAT,
-- GREENRYE, VETCHRYE, MUSTARD, SILAGEMAIZE, enz.) voegen die aan de
-- FARMSILO-categorie toe via hun eigen fillTypes.xml. Het spel voegt
-- die samen met de basis-graansoorten (WHEAT, BARLEY, OAT, CANOLA,
-- SORGHUM, ...). Door direct de FARMSILO-categorie te lezen, worden
-- al die soorten automatisch herkend — zonder de mod aan te passen,
-- en zonder legitieme soorten per ongeluk uit te sluiten.
--
-- Een storage wordt beheerd als hij minstens één fillType uit de
-- FARMSILO-categorie accepteert. Zo blijven mest-, kalk-, aardappel-,
-- vloeistof- en universele opslagen buiten schot: die accepteren geen
-- FARMSILO-producten.
-- ------------------------------------------------------------------

local farmSiloFillTypeSet = nil
local function getFarmSiloFillTypeSet()
    -- Alleen cachen als we daadwerkelijk fillTypes vonden. Zo wordt bij
    -- een vroege (nog lege) aanroep niet permanent een lege set gecached
    -- terwijl de map zijn fillTypes.xml later alsnog registreert.
    if farmSiloFillTypeSet == nil or next(farmSiloFillTypeSet) == nil then
        local result = {}
        for _, catName in ipairs({ "farmSilo", "FARMSILO" }) do
            local ok, list = pcall(function()
                return g_fillTypeManager:getFillTypesByCategoryNames(catName, nil)
            end)
            if ok and list then
                for _, ft in ipairs(list) do
                    result[ft] = true
                end
            end
        end
        farmSiloFillTypeSet = result
    end
    return farmSiloFillTypeSet
end
RealSiloUtil.getFarmSiloFillTypeSet = getFarmSiloFillTypeSet

function RealSiloUtil.isFarmSiloStorage(storage)
    if storage == nil or storage.fillTypes == nil then return false end
    local farmSet = getFarmSiloFillTypeSet()
    for ft, active in pairs(storage.fillTypes) do
        if active and farmSet[ft] then
            RealSiloDebug.print("[realSilo] Silo herkend: accepteert FARMSILO-product (fillType %s)", tostring(ft))
            return true
        end
    end
    -- Niet herkend: log wat de silo WEL accepteert en hoe groot de
    -- FARMSILO-set is, zodat we kunnen zien waar de mismatch zit.
    if RealSiloDebug.enabled then
        local accepted = {}
        for ft, active in pairs(storage.fillTypes) do
            if active then table.insert(accepted, tostring(ft)) end
        end
        local farmCount = 0
        for _ in pairs(farmSet) do farmCount = farmCount + 1 end
        RealSiloDebug.print(
            "[realSilo] Silo NIET herkend. Accepteert fillTypes: [%s] | FARMSILO-set heeft %d types",
            table.concat(accepted, ","), farmCount)
    end
    return false
end

-- Minstens één van de storages van deze PlaceableSilo moet farmSilo zijn.
function RealSiloUtil.isFarmSiloPlaceableSilo(placeable)
    local spec = placeable and placeable.spec_silo
    if not spec or not spec.storages then return false end
    for _, storage in ipairs(spec.storages) do
        if RealSiloUtil.isFarmSiloStorage(storage) then
            return true
        end
    end
    return false
end

-- De storage van deze PlaceableSiloExtension moet farmSilo zijn.
function RealSiloUtil.isFarmSiloPlaceableExtension(placeable)
    local spec = placeable and placeable.spec_siloExtension
    return RealSiloUtil.isFarmSiloStorage(spec and spec.storage)
end

function RealSiloUtil.resolveDisplayName(placeable, fallbackL10nKey, fallbackText)
    local name = placeable and placeable.storeItem and placeable.storeItem.name
    if name and name ~= "" and not name:find("^%$") then
        return name
    end
    local ok, text = pcall(function() return g_i18n:getText(fallbackL10nKey) end)
    if ok and text and text ~= "" and text ~= fallbackL10nKey then
        return text
    end
    return fallbackText or "Silo"
end

RealSiloDebug.print("[realSilo] RealSiloUtil geladen")

-- ============================================================
-- Multiplayer-toestemmingen
--
-- Wie mag silo-instellingen wijzigen?
--   - Server/host: altijd
--   - Admin (master user): altijd, voor elke boerderij
--   - Eigen boerderij + boerderijbeheerder ("Farm Manager"): toegestaan
--   - Eigen boerderij maar gewoon lid: NIET toegestaan
--   - Andere boerderij, geen admin: NIET toegestaan
--   - Onbeheerde silo (boerderij 0 / spectator): voor niemand
--
-- API geverifieerd tegen de broncode van een echte, multiplayer-
-- geteste FS25-mod (rittermod/FS25_AdjustStorageCapacity, MIT/open
-- broncode op GitHub) die exact hetzelfde soort actie beveiligt
-- (storage-capaciteit aanpassen). Gebruikt hier dezelfde functies:
--   g_currentMission:getFarmId(), g_currentMission:getIsServer(),
--   g_currentMission.missionDynamicInfo.isMultiplayer,
--   g_currentMission.userManager:getUserByConnection(connection),
--   user:getIsMasterUser(), g_farmManager:getFarmById(farmId),
--   farm:isUserFarmManager(userId), placeable:getOwnerFarmId().
-- ============================================================

function RealSiloUtil.getFarmIdForUid(uid)
    local silo = realSiloManager and realSiloManager.getSilo(uid)
    local placeable = silo and silo.placeable
    if placeable and placeable.getOwnerFarmId then
        return placeable:getOwnerFarmId()
    end
    return nil
end

-- ----------------------------------------------------------------
-- Server-side check: connection is de netwerk-verbinding van de
-- speler die de wijziging aanvroeg. connection == nil betekent een
-- lokale aanroep door de host zelf → altijd toegestaan (de host is
-- per definitie de server).
--
-- Regel (vereenvoudigd op verzoek): ALLEEN een admin (master user)
-- mag silo-instellingen wijzigen. Gewone boerderijleden, ongeacht
-- eigenaarschap, mogen niet wijzigen.
-- ----------------------------------------------------------------
function RealSiloUtil.canManageSilo(uid, connection)
    if connection == nil then return true end

    local ok, allowed = pcall(function()
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if not user then
            RealSiloDebug.print("[realSilo] Toestemmingscheck: geen user gevonden voor connectie, geweigerd")
            return false
        end

        local isAdmin = user.getIsMasterUser and user:getIsMasterUser()
        if not isAdmin then
            RealSiloDebug.print(string.format("[realSilo] Toestemmingscheck: userId=%s is geen admin, geweigerd",
                tostring(user.userId or "?")))
        end
        return isAdmin == true
    end)

    if not ok then
        RealSiloDebug.print("[realSilo] Toestemmingscheck mislukte met fout, toegestaan (fail-open): " .. tostring(allowed))
        return true
    end
    return allowed
end

-- ----------------------------------------------------------------
-- Lokale variant: checkt of DE HUIDIGE SPELER (geen netwerk-
-- connectie, dat heeft een client niet van zichzelf) deze silo mag
-- beheren. Wordt gebruikt om een wijziging al client-side te
-- blokkeren vóórdat hij optimistisch lokaal wordt toegepast — zo
-- blijft de lokale weergave van een speler zonder toestemming niet
-- ten onrechte "gewijzigd" staan nadat de server het alsnog afwijst.
-- De server-side check (canManageSilo) blijft de echte beveiliging;
-- dit is puur voor correcte/directe feedback aan de speler.
--
-- Zelfde vereenvoudigde regel: alleen admin (of host/singleplayer).
-- ----------------------------------------------------------------
function RealSiloUtil.canManageSiloLocal(uid)
    local ok, allowed = pcall(function()
        -- Server/host mag altijd (geldt ook voor singleplayer).
        if g_currentMission:getIsServer() then
            return true
        end
        -- Multiplayer-client: alleen admin (master user) mag wijzigen.
        return g_currentMission.isMasterUser == true
    end)

    if not ok then return true end
    return allowed
end
