-- ============================================================
-- realSiloHook.lua  v9 - Schoon extension-herstel via uid
-- ============================================================

local modDirectory = g_currentModDirectory

-- ================================================================
-- Savegame helpers
-- ================================================================
local function getSaveFilePath()
    if g_currentMission and g_currentMission.missionInfo then
        local saveDir = g_currentMission.missionInfo.savegameDirectory
        if saveDir then return saveDir .. "/realSiloData.xml" end
    end
    return nil
end

local function saveAllSiloData()
    local path = getSaveFilePath()
    if not path then return end
    local xmlFile = createXMLFile("realSiloData", path, "realSiloData")
    if xmlFile == nil or xmlFile == 0 then return end

    local idx = 0
    for uid, silo in pairs(realSiloManager.silos) do
        local key = string.format("realSiloData.silo(%d)", idx)
        setXMLString(xmlFile, key .. "#uid",          uid)
        setXMLInt(xmlFile,    key .. "#numComps",     silo.config.numCompartments)
        setXMLInt(xmlFile,    key .. "#capPerComp",   silo.config.capacityPerCompartment)
        setXMLInt(xmlFile,    key .. "#configured",   silo.config.isConfigured and 1 or 0)
        setXMLInt(xmlFile,    key .. "#locked",       silo.config.locked and 1 or 0)
        setXMLInt(xmlFile,    key .. "#transferRate", silo.config.transferRate or 1000)
        if silo.config.totalStorageCapacity then
            setXMLInt(xmlFile, key .. "#totalCap", silo.config.totalStorageCapacity)
        end
        RealSiloCompartmentStorage.saveToXML(xmlFile, key .. ".slots", uid)
        local silo2 = realSiloManager.getSilo(uid)
        if silo2 and silo2.config.slotCapacities then
            for slotIdx, cap in pairs(silo2.config.slotCapacities) do
                setXMLInt(xmlFile, string.format("%s.slotCap(%d)#i",   key, slotIdx-1), slotIdx)
                setXMLInt(xmlFile, string.format("%s.slotCap(%d)#cap", key, slotIdx-1), cap)
            end
        end
        local naam = realSiloManager.getSiloName(uid)
        if naam then setXMLString(xmlFile, key .. "#naam", naam) end
        idx = idx + 1
    end
    RealSiloExtensionManager.saveToXML(xmlFile)
    saveXMLFile(xmlFile)
    delete(xmlFile)
    RealSiloDebug.print(string.format("[realSilo] %d silo('s) opgeslagen", idx))
end

local function loadAllSiloData()
    local path = getSaveFilePath()
    if not path or not fileExists(path) then return {} end
    local xmlFile = loadXMLFile("realSiloData", path)
    if xmlFile == nil or xmlFile == 0 then return {} end

    local data = {}
    local i = 0
    while true do
        local key = string.format("realSiloData.silo(%d)", i)
        local uid = getXMLString(xmlFile, key .. "#uid")
        if uid == nil then break end
        local configured = getXMLInt(xmlFile, key .. "#configured") or 0
        local totalCap   = getXMLInt(xmlFile, key .. "#totalCap")
        local slotCaps   = {}
        local sc = 0
        while true do
            local scKey = string.format("%s.slotCap(%d)", key, sc)
            local si    = getXMLInt(xmlFile, scKey .. "#i")
            if si == nil then break end
            local scap  = getXMLInt(xmlFile, scKey .. "#cap")
            if scap then slotCaps[si] = scap end
            sc = sc + 1
        end
        data[uid] = {
            numCompartments        = getXMLInt(xmlFile, key .. "#numComps")    or 4,
            capacityPerCompartment = getXMLInt(xmlFile, key .. "#capPerComp") or 50000,
            isConfigured           = (configured == 1),
            locked                 = (getXMLInt(xmlFile, key .. "#locked") or 0) == 1,
            transferRate           = getXMLInt(xmlFile, key .. "#transferRate") or 1000,
            totalStorageCapacity   = totalCap,
            slotCapacities         = next(slotCaps) and slotCaps or nil,
            naam                   = getXMLString(xmlFile, key .. "#naam"),
            xmlFile                = xmlFile,
            slotsKey               = key .. ".slots",
        }
        i = i + 1
    end
    -- Laad extension-data in pendingSaved (geen koppeling hier)
    RealSiloExtensionManager.loadFromXML(xmlFile)
    data._xmlFile = xmlFile
    RealSiloDebug.print(string.format("[realSilo] %d silo('s) geladen", i))
    return data
end

local savedData  = {}
local dataLoaded = false
local function ensureDataLoaded()
    if not dataLoaded then
        savedData  = loadAllSiloData()
        dataLoaded = true
    end
end

-- Alle geladen extension-placeables (gevuld in onFinalizePlacement van extension)
local allExtensions = {}

-- [extPlaceable] = uid (voor onDelete)
local extensionToSilo = {}

-- Vindt de dichtstbijzijnde realSilo voor een extension placeable (binnen 50m)
local function findNearestRealSilo(extPlaceable)
    local ex, ey, ez = 0, 0, 0
    if extPlaceable.rootNode and extPlaceable.rootNode ~= 0 then
        ex, ey, ez = getWorldTranslation(extPlaceable.rootNode)
    end
    local bestUid  = nil
    local bestDist = math.huge
    for uid, silo in pairs(realSiloManager.silos) do
        local p = silo.placeable
        if p and p.rootNode and p.rootNode ~= 0 then
            local sx, sy, sz = getWorldTranslation(p.rootNode)
            local dist = MathUtil.vector3Length(ex-sx, ey-sy, ez-sz)
            if dist < bestDist then bestDist = dist; bestUid = uid end
        end
    end
    if bestDist < 50 then return bestUid, bestDist end
    return nil, nil
end

-- Controleer of een extension placeable al gekoppeld is (enkel of multi)
local function isExtensionLinked(ext)
    if RealSiloExtensionManager.linked[ext] then return true end
    local multi = RealSiloExtensionManager.linkedMulti
    if multi and multi[ext] then return true end
    return false
end

-- Koppel een extension aan een silo, op basis van de XML-definitie
-- (ext._realSiloXmlDef) of met de standaard capaciteit als die ontbreekt.
local function linkExtensionByXmlDef(ext, uid)
    local def = ext._realSiloXmlDef
    if def and def.compartments and #def.compartments > 0 then
        table.sort(def.compartments, function(a, b) return a.index < b.index end)
        if #def.compartments == 1 then
            return RealSiloExtensionManager.link(ext, uid, def.compartments[1].capacity)
        else
            local comps = {}
            for _, comp in ipairs(def.compartments) do
                table.insert(comps, { cap = comp.capacity, fillType = 0, fillLevel = 0, isActive = false })
            end
            return RealSiloExtensionManager.linkMulti(ext, uid, comps)
        end
    else
        return RealSiloExtensionManager.link(ext, uid, nil)
    end
end

-- ================================================================
-- GUI registratie na mission start
-- ================================================================
Mission00.onStartMission = Utils.appendedFunction(
    Mission00.onStartMission,
    function(mission)
        RealSiloDialog.register(modDirectory)

        -- Multiplayer: een verbindende client heeft geen toegang tot
        -- realSiloData.xml op de host, en maakt dus zelf een (vaak
        -- verkeerde) aanname over vakken/capaciteit/koppelingen. Vraag
        -- de server hier via een eigen Event om de echte stand van
        -- zaken — dit raakt geen interne Giants-streams van andere
        -- objecten, in tegenstelling tot onWriteStream/onReadStream.
        if g_server == nil then
            RealSiloEvents.requestSync()
        end
    end
)

-- ================================================================
-- Hook: PlaceableSilo:onLoad
-- ================================================================
local originalOnLoad = PlaceableSilo.onLoad
PlaceableSilo.onLoad = function(self, savegame)
    originalOnLoad(self, savegame)

    -- realSilo werkt alleen op silo's met minstens één farmSilo-fillType
    -- (zie RealSiloUtil.lua). Andere silo's (bv. dieseltanks, watertanks)
    -- worden volledig genegeerd: geen registratie, geen storage-vervanging,
    -- geen menu, geen enkele aanraking door deze mod.
    -- Is spec_silo.storages op dit moment nog niet gevuld, dan stellen we
    -- het oordeel uit tot onFinalizePlacement (daar staat het gegarandeerd
    -- klaar) in plaats van een silo per ongeluk verkeerd te negeren.
    local specReady = self.spec_silo ~= nil and self.spec_silo.storages ~= nil
    if specReady and not RealSiloUtil.isFarmSiloPlaceableSilo(self) then
        self._realSiloIgnored = true
        return
    end

    local x, y, z = 0, 0, 0
    if self.rootNode and self.rootNode ~= 0 then
        x, y, z = getWorldTranslation(self.rootNode)
    end
    local uid = string.format("rs_%d_%d_%d",
        math.floor(x+0.5), math.floor(y+0.5), math.floor(z+0.5))
    self.realSiloUniqueId    = uid
    self.realSiloActivatable = RealSiloActivatable.new(self)

    -- Lees optionele realSilo definitie uit de silo XML
    local xmlDefined = nil
    if self.configFileName then
        local rawXml = loadXMLFile("realSiloRead", self.configFileName)
        if rawXml and rawXml ~= 0 then
            local rsKey    = "placeable.realSilo"
            local numComps = getXMLInt(rawXml, rsKey .. "#compartments")
            RealSiloDebug.print(string.format("[realSilo] realSilo tag numComps: %s", tostring(numComps)))
            if numComps then
                local slotCaps     = {}
                local i            = 0
                local transferRate = getXMLFloat(rawXml, rsKey .. "#transferRate") or 1000
                while true do
                    local cKey = string.format("%s.compartment(%d)", rsKey, i)
                    local cap  = getXMLInt(rawXml, cKey .. "#capacity")
                    if cap == nil then break end
                    -- index is optioneel: als niet opgegeven, gebruik volgorde (1-based)
                    local idx = getXMLInt(rawXml, cKey .. "#index") or (i + 1)
                    slotCaps[idx] = cap
                    i = i + 1
                end
                -- locked: standaard TRUE als de modder dit blok heeft gedefinieerd
                -- (de configuratie staat al vast in de XML), tenzij expliciet
                -- locked="false" is opgegeven.
                local lockedAttr = getXMLBool(rawXml, rsKey .. "#locked")
                local locked = (lockedAttr == nil) and true or lockedAttr

                xmlDefined = {
                    numCompartments = numComps,
                    locked          = locked,
                    slotCapacities  = next(slotCaps) and slotCaps or nil,
                    name            = getXMLString(rawXml, rsKey .. "#name"),
                    transferRate    = transferRate,
                }
            end
            delete(rawXml)
        end
    end
    self.realSiloXmlDefined = xmlDefined

    ensureDataLoaded()
    local cfg = savedData[uid]
    local savedConfig = cfg and {
        numCompartments        = cfg.numCompartments,
        capacityPerCompartment = cfg.capacityPerCompartment,
    } or nil
    realSiloManager.register(self, uid, savedConfig, nil)
    if cfg and cfg.naam then
        realSiloManager.setSiloName(uid, cfg.naam)
    else
        realSiloManager.setSiloName(uid,
            RealSiloUtil.resolveDisplayName(self, "realSilo_defaultName", "Silo"))
    end
    if cfg and cfg.isConfigured           then realSiloManager.setConfigured(uid) end
    if cfg and cfg.totalStorageCapacity   then
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.totalStorageCapacity = cfg.totalStorageCapacity end
    end
    if cfg and cfg.transferRate then
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.transferRate = cfg.transferRate end
    end
    RealSiloDebug.print(string.format("[realSilo] onLoad: %s", uid))
end

-- ================================================================
-- Hook: PlaceableSilo:onFinalizePlacement
-- ================================================================
local originalOnFinalize = PlaceableSilo.onFinalizePlacement
PlaceableSilo.onFinalizePlacement = function(self)
    originalOnFinalize(self)

    local uid = self.realSiloUniqueId
    if not uid then return end

    -- Vangnet: als spec_silo.storages tijdens onLoad nog niet beschikbaar
    -- was, is de farmSilo-check daar overgeslagen. Hier staat de data
    -- gegarandeerd klaar, dus controleren we het nu alsnog en maken de
    -- (nog niet aangepaste) registratie ongedaan indien nodig.
    if not RealSiloUtil.isFarmSiloPlaceableSilo(self) then
        if self.realSiloActivatable then
            g_currentMission.activatableObjectsSystem:removeActivatable(self.realSiloActivatable)
        end
        realSiloManager.unregister(uid)
        self.realSiloUniqueId = nil
        self._realSiloIgnored = true
        return
    end

    local silo = realSiloManager.getSilo(uid)
    if not silo then return end

    local ok = RealSiloCompartmentStorage.initialize(
        self, uid,
        silo.config.numCompartments,
        silo.config.capacityPerCompartment)

    if ok then
        local cfg = savedData[uid]
        if cfg and savedData._xmlFile then
            RealSiloCompartmentStorage.loadFromXML(savedData._xmlFile, cfg.slotsKey, uid)
            if cfg.slotCapacities then
                for slotIdx, cap in pairs(cfg.slotCapacities) do
                    RealSiloCompartmentStorage.setSlotCapacity(uid, slotIdx, cap)
                end
            end
        end

        -- XML-definitie toepassen als niet geconfigureerd via savegame
        local xmlDef = self.realSiloXmlDefined
        if xmlDef and not realSiloManager.isConfigured(uid) then
            local siloData   = realSiloManager.getSilo(uid)
            local totalCap   = realSiloManager.getStorageCapacity(self)
                               or (siloData and siloData.config.totalStorageCapacity)
                               or 400000
            local capPerComp = math.max(math.floor(totalCap / xmlDef.numCompartments), 1000)
            realSiloManager.applyConfig(uid, xmlDef.numCompartments, capPerComp)
            realSiloManager.setConfigured(uid)
            if xmlDef.name and xmlDef.name ~= "" then
                realSiloManager.setSiloName(uid, xmlDef.name)
            end
            local s2 = realSiloManager.getSilo(uid)
            if s2 then s2.config.transferRate = xmlDef.transferRate or 1000 end
            if xmlDef.slotCapacities then
                for slotIdx, slotCap in pairs(xmlDef.slotCapacities) do
                    RealSiloCompartmentStorage.setSlotCapacity(uid, slotIdx, slotCap)
                end
            end
        end

        -- Locked-status altijd toepassen vanuit XML, onafhankelijk van
        -- of de silo al geconfigureerd was (bv. via een eerdere savegame).
        if xmlDef then
            local s = realSiloManager.getSilo(uid)
            if s then s.config.locked = xmlDef.locked end
        end

        -- Herstel extensions voor deze silo vanuit pendingSaved (uid-gebaseerd)
        local pending = RealSiloExtensionManager.pendingSaved
        local i = 1
        while i <= #pending do
            if pending[i].siloUid == uid then
                local saved = table.remove(pending, i)
                -- Zoek eerste ongekoppelde extension
                local matched = nil
                for _, ext in ipairs(allExtensions) do
                    if not isExtensionLinked(ext) then
                        matched = ext; break
                    end
                end
                if matched then
                    if saved.isMulti then
                        RealSiloExtensionManager.linkMulti(matched, uid, saved.comps)
                    else
                        RealSiloExtensionManager.link(matched, uid,
                            saved.cap, saved.fillType, saved.fillLevel, saved.isActive)
                    end
                else
                    -- Extension nog niet geladen, bewaar voor later
                    table.insert(pending, i, saved)
                    i = i + 1
                end
            else
                i = i + 1
            end
        end

        -- Koppel ongekoppelde extensions in de buurt (bv. orphans na verwijderen
        -- van een andere silo) aan deze silo, op basis van hun XML-definitie.
        for _, ext in ipairs(allExtensions) do
            if not isExtensionLinked(ext) then
                local nearUid = findNearestRealSilo(ext)
                if nearUid == uid then
                    if linkExtensionByXmlDef(ext, uid) then
                        extensionToSilo[ext] = uid
                    end
                end
            end
        end

        RealSiloDebug.print(string.format("[realSilo] onFinalizePlacement OK: %s", uid))
    end
end

-- ================================================================
-- Hook: PlaceableSilo:onDelete
-- ================================================================
local originalOnDelete = PlaceableSilo.onDelete
PlaceableSilo.onDelete = function(self)
    local uid = self.realSiloUniqueId
    if uid then
        if self.realSiloActivatable then
            g_currentMission.activatableObjectsSystem:removeActivatable(
                self.realSiloActivatable)
        end
        RealSiloCompartmentStorage.cleanup(self, uid)
        realSiloManager.unregister(uid)
    end
    originalOnDelete(self)
end

-- ================================================================
-- Trigger callbacks
-- ================================================================
local originalPlayerTrigger = PlaceableSilo.onPlayerActionTriggerCallback
PlaceableSilo.onPlayerActionTriggerCallback = function(self, triggerId, otherId, onEnter, onLeave, onStay)
    originalPlayerTrigger(self, triggerId, otherId, onEnter, onLeave, onStay)
    if not self.realSiloActivatable then return end
    if not (g_localPlayer and otherId == g_localPlayer.rootNode) then return end
    if self:getOwnerFarmId() ~= g_currentMission:getFarmId() then return end
    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(self.realSiloActivatable)
    else
        g_currentMission.activatableObjectsSystem:removeActivatable(self.realSiloActivatable)
    end
end

local originalInfoTrigger = PlaceableInfoTrigger.onInfoTriggerCallback
PlaceableInfoTrigger.onInfoTriggerCallback = function(self, triggerId, otherId, onEnter, onLeave, onStay)
    originalInfoTrigger(self, triggerId, otherId, onEnter, onLeave, onStay)
    if not self.realSiloActivatable then return end
    if not (g_localPlayer and otherId == g_localPlayer.rootNode) then return end
    if self:getOwnerFarmId() ~= g_currentMission:getFarmId() then return end
    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(self.realSiloActivatable)
        RealSiloDebug.print("[realSilo] Activatable via infoTrigger")
    else
        g_currentMission.activatableObjectsSystem:removeActivatable(self.realSiloActivatable)
    end
end

-- ================================================================
-- Savegame
-- ================================================================
local originalSaveSavegame = FSBaseMission.saveSavegame
FSBaseMission.saveSavegame = function(self)
    originalSaveSavegame(self)
    saveAllSiloData()
end

-- ================================================================
-- Update loop: transfer systeem
-- ================================================================
local originalUpdate = FSBaseMission.update
FSBaseMission.update = function(self, dt)
    originalUpdate(self, dt)
    -- Vulniveaus mogen alleen op de server gewijzigd worden; clients
    -- ontvangen de resultaten via de normale storage-synchronisatie.
    if g_server ~= nil then
        realSiloManager.updateTransfers(dt)
    end
end

RealSiloDebug.print("[realSilo] PlaceableSilo hooks geïnstalleerd (v9 - schoon extension-herstel)")

-- ================================================================
-- SiloExtension koppeling
--
-- Bij laden: pendingSaved bevat {siloUid, cap, ft, fl} per extension.
-- onFinalizePlacement van SILO koppelt extensies via uid.
-- onFinalizePlacement van EXTENSION: alleen voor nieuw geplaatste extensies.
-- ================================================================

local originalExtFinalize = PlaceableSiloExtension.onFinalizePlacement
PlaceableSiloExtension.onFinalizePlacement = function(self)
    originalExtFinalize(self)

    -- realSilo koppelt alleen extensions met minstens één farmSilo-fillType.
    -- Dieseltanks en andere niet-farmSilo extensions blijven volledig
    -- ongemoeid (geen koppeling, geen vakindeling, geen menu-item).
    if not RealSiloUtil.isFarmSiloPlaceableExtension(self) then
        self._realSiloIgnored = true
        return
    end

    -- Weergavenaam van deze extension (storeData/name uit de XML, anders
    -- de fallback "Silo Extension").
    self._realSiloDisplayName = RealSiloUtil.resolveDisplayName(
        self, "realSilo_defaultExtensionName", "Silo Extension")

    table.insert(allExtensions, self)

    -- Lees XML-definitie van de modder (optioneel)
    -- <realSiloExtension>
    --     <compartment capacity="100000" />
    --     <compartment capacity="75000" />
    -- </realSiloExtension>
    local xmlDef = nil
    if self.configFileName then
        local rawXml = loadXMLFile("realSiloExtRead", self.configFileName)
        if rawXml and rawXml ~= 0 then
            local rsKey = "placeable.realSiloExtension"
            local comps = {}
            local c = 0
            while true do
                local cKey = string.format("%s.compartment(%d)", rsKey, c)
                local cap  = getXMLInt(rawXml, cKey .. "#capacity")
                if cap == nil then break end
                -- index is optioneel: als niet opgegeven, gebruik volgorde (1-based)
                local idx = getXMLInt(rawXml, cKey .. "#index") or (c + 1)
                table.insert(comps, { index = idx, capacity = math.max(cap, 1000) })
                c = c + 1
            end
            if #comps > 0 then
                xmlDef = { compartments = comps }
            end
            delete(rawXml)
        end
    end
    self._realSiloXmlDef = xmlDef

    -- Al gekoppeld door silo-herstel? Dan klaar.
    if isExtensionLinked(self) then
        extensionToSilo[self] = (RealSiloExtensionManager.linked[self] and RealSiloExtensionManager.linked[self].uid)
            or (RealSiloExtensionManager.linkedMulti[self] and RealSiloExtensionManager.linkedMulti[self][1].uid)
        return
    end

    -- Nog pending saved data? (extension laadde na de silo)
    local pending = RealSiloExtensionManager.pendingSaved
    if #pending > 0 then
        local saved = table.remove(pending, 1)
        local ok
        if saved.isMulti then
            ok = RealSiloExtensionManager.linkMulti(self, saved.siloUid, saved.comps)
        else
            ok = RealSiloExtensionManager.link(self, saved.siloUid,
                saved.cap, saved.fillType, saved.fillLevel, saved.isActive)
        end
        if ok then
            extensionToSilo[self] = saved.siloUid
            return
        end
        table.insert(pending, 1, saved)  -- mislukt, zet terug
    end

    -- Nieuw geplaatst: positie-check
    local uid, dist = findNearestRealSilo(self)
    if not uid then
        RealSiloDebug.print("[realSilo] SiloExtension: geen nabije realSilo gevonden")
        return
    end
    extensionToSilo[self] = uid
    linkExtensionByXmlDef(self, uid)
end

local originalExtDelete = PlaceableSiloExtension.onDelete
PlaceableSiloExtension.onDelete = function(self)
    RealSiloExtensionManager.unlink(self)
    for i = #allExtensions, 1, -1 do
        if allExtensions[i] == self then table.remove(allExtensions, i); break end
    end
    extensionToSilo[self] = nil
    originalExtDelete(self)
end

RealSiloDebug.print("[realSilo] SiloExtension hooks geïnstalleerd")

-- ================================================================
-- Infobox: compartimentinfo via InfoDisplayKeyValueBox.addLine
--
-- updateInfo signatuur is niet stabiel te hooken via overwrittenFunction.
-- We hooken InfoDisplayKeyValueBox.addLine zelf: zodra de silo zijn
-- eerste rij toevoegt, injecteren we direct daarna de compartimentdata.
-- De eerste rij van Giants (totaalregel "Gerst 100.000 l") onderdrukken we.
-- ================================================================

local _activeSiloUid = nil

-- Bijhouden welke silo actief is in de infobox
local _origInfoCb = PlaceableInfoTrigger.onInfoTriggerCallback
PlaceableInfoTrigger.onInfoTriggerCallback = function(self, triggerId, otherId, onEnter, onLeave, onStay)
    _origInfoCb(self, triggerId, otherId, onEnter, onLeave, onStay)
    if g_localPlayer and otherId == g_localPlayer.rootNode then
        if onEnter then
            _activeSiloUid = self.realSiloUniqueId
        elseif onLeave then
            if _activeSiloUid == self.realSiloUniqueId then
                _activeSiloUid = nil
            end
        end
    end
end

-- Groen kleur voor actief vak (zelfde groen als FS25 HUD)
local COLOR_ACTIVE = { 0.204, 0.827, 0.169, 1.0 }

-- Hook InfoDisplayKeyValueBox na mission start (klasse is dan beschikbaar)
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
    if InfoDisplayKeyValueBox == nil then
        RealSiloDebug.print("[realSilo] WAARSCHUWING: InfoDisplayKeyValueBox niet gevonden")
        return
    end

    local _linesThisFrame = 0   -- telt hoeveel rijen Giants al toevoegde
    local _injectedThisFrame = false

    -- clear() markeert begin nieuwe frame
    local _origClear = InfoDisplayKeyValueBox.clear
    InfoDisplayKeyValueBox.clear = function(self)
        _origClear(self)
        _linesThisFrame   = 0
        _injectedThisFrame = false
    end

    -- addLine: onderdruk de eerste Giants-rij (totaalregel) voor realSilo's,
    -- en injecteer daarna onze compartimentdata
    local _origAddLine = InfoDisplayKeyValueBox.addLine
    InfoDisplayKeyValueBox.addLine = function(self, key, value, accentuate, accentuateColor)
        if _activeSiloUid then
            _linesThisFrame = _linesThisFrame + 1

            -- Eerste rij = Giants totaalregel ("Gerst  100.000 l") → onderdrukken
            if _linesThisFrame == 1 then
                -- Niet doorsturen naar origineel
                -- Injecteer direct onze compartimentdata
                if not _injectedThisFrame then
                    _injectedThisFrame = true
                    local data = RealSiloCompartmentStorage.siloSlots[_activeSiloUid]
                    local activeSlot = data and data.activeSlot or nil
                    if data and data.slots and #data.slots > 0 then
                        _origAddLine(self, "Silo's", "")
                        for i, slot in ipairs(data.slots) do
                            local fillTypeName, fillAmount = nil, 0
                            local cap = slot.capacity or 0
                            if slot.fillType and slot.fillType ~= 0 and slot.fillLevel and slot.fillLevel > 0 then
                                local ftDef = g_fillTypeManager:getFillTypeByIndex(slot.fillType)
                                fillTypeName = ftDef and (ftDef.title or ftDef.name) or tostring(slot.fillType)
                                fillAmount   = slot.fillLevel
                            end
                            local label = string.format("Silo %d%s", i, slot.isExtension and " (ext)" or "")
                            local val   = string.format("%s / %s L  [%s]",
                                g_i18n:formatNumber(math.floor(fillAmount), 0),
                                g_i18n:formatNumber(math.floor(cap), 0),
                                fillTypeName or (g_i18n:getText("realSilo_empty") or "Empty"))
                            -- Actief vak groen markeren
                            local isActive = (i == activeSlot)
                            _origAddLine(self, label, val, isActive, COLOR_ACTIVE)
                        end
                    end
                end
                return  -- Giants' totaalregel niet tonen
            end
        end

        -- Alle andere rijen (andere placeables, of latere rijen) normaal doorsturen
        _origAddLine(self, key, value, accentuate, accentuateColor)
    end

    RealSiloDebug.print("[realSilo] Infobox hook: addLine (met actief-vak kleur + totaalregel onderdrukt)")
end)
