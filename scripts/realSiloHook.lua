-- ============================================================
-- realSiloHook.lua  v13 - Aangepaste naam overal + schoon extension-
-- herstel via uid
-- ============================================================

local modDirectory = g_currentModDirectory

-- ================================================================
-- Open-toets REALSILO_OPEN (standaard R, aanpasbaar via Opties >
-- Besturing).
--
-- ONTWERP: precies EEN globale action-event, niet een per silo.
-- Een eerdere versie registreerde per silo een eigen event; op maps
-- met meerdere silo's hield FS25 dan het eerste event vast, waardoor
-- R overal het menu van de eerste silo opende en de tweede silo
-- onbereikbaar werd (gemelde bug: hoofdsilo-hal + tweede FARMA 400).
--
-- De TRIGGER bepaalt bij welke silo de speler staat; het ene globale
-- event opent bij indrukken die silo. Staan er door overlappende
-- triggers meerdere silo's tegelijk als "betreden" geregistreerd, dan
-- wint de laatst-betreden silo; bij verlaten valt hij terug op een
-- eventueel nog-betreden andere silo.
--
-- Er is bewust GEEN generieke activatable-fallback: die zat op de
-- gedeelde "object activeren"-toets en botste met andere mods.
-- ================================================================
local realSiloActiveTriggerSilo = nil   -- silo waar de speler nu bij staat
-- Een placeable kan zowel een playerActionTrigger als een infoTrigger
-- hebben. Bewaar daarom iedere door de engine bewaakte trigger-vorm apart;
-- één onLeave mag de andere, nog betreden vorm niet ongeldig maken.
local realSiloEnteredSet        = {}    -- [placeable][triggerId]=true zolang onLeave niet is ontvangen
local realSiloRegisteredPlayerRoot = nil
local realSiloGlobalEventId     = nil

local function realSiloUpdatePromptText()
    if realSiloGlobalEventId == nil or g_inputBinding == nil then return end
    local active = (realSiloActiveTriggerSilo ~= nil)
    RealSiloDebug.print("[realSilo][DIAG] prompt zichtbaar=%s (event=%s)",
        tostring(active), tostring(realSiloGlobalEventId))
    pcall(function() g_inputBinding:setActionEventTextVisibility(realSiloGlobalEventId, active) end)
    if active then
        pcall(function()
            g_inputBinding:setActionEventText(realSiloGlobalEventId,
                g_i18n:getText("realSilo_configureAction") or "RealSilo")
        end)
    end
end

-- Diagnose: welke toets is er aan REALSILO_OPEN gekoppeld? Als de
-- binding leeg is, bestaat de actie wel maar heeft hij geen toets --
-- dan verschijnt er geen prompt en reageert er niets. Dat is niet uit
-- een serverlog af te leiden, vandaar deze melding bij mission-start.
local function realSiloLogBinding()
    if g_inputBinding == nil then
        RealSiloDebug.print("[realSilo][DIAG] binding: g_inputBinding niet beschikbaar")
        return
    end
    if InputAction.REALSILO_OPEN == nil then
        RealSiloDebug.print("[realSilo][DIAG] binding: InputAction.REALSILO_OPEN BESTAAT NIET")
        return
    end

    local shown = false
    -- Meerdere API-varianten proberen; welke bestaat verschilt per versie.
    for _, fn in ipairs({ "getDisplayKeyNamesForActionString",
                          "getDisplayKeyNamesForAction",
                          "getButtonsForActionName" }) do
        if not shown and g_inputBinding[fn] ~= nil then
            local ok, res = pcall(function()
                return g_inputBinding[fn](g_inputBinding, InputAction.REALSILO_OPEN)
            end)
            if ok and res ~= nil and tostring(res) ~= "" then
                RealSiloDebug.print("[realSilo][DIAG] binding REALSILO_OPEN (%s): %s",
                    fn, tostring(res))
                shown = true
            end
        end
    end
    if not shown then
        RealSiloDebug.print("[realSilo][DIAG] binding REALSILO_OPEN: GEEN toets gevonden (actie bestaat wel)")
    end
end

if Mission00 ~= nil and Mission00.onStartMission ~= nil then
    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
        realSiloLogBinding()
    end)
end

local function realSiloEnsureGlobalEvent()
    if realSiloGlobalEventId ~= nil then
        -- Hetzelfde event gedurende de hele missie hergebruiken. Herhaald
        -- verwijderen en opnieuw registreren kan een zichtbare maar niet
        -- meer reagerende F1-actie achterlaten.
        pcall(function() g_inputBinding:setActionEventActive(realSiloGlobalEventId, true) end)
        return
    end
    if g_inputBinding == nil or InputAction.REALSILO_OPEN == nil then return end

    local _, eventId = g_inputBinding:registerActionEvent(
        InputAction.REALSILO_OPEN, nil,
        function()
            local target = realSiloActiveTriggerSilo
            if target ~= nil and target.realSiloUniqueId ~= nil then
                RealSiloDialog.show(target.realSiloUniqueId, target)
            end
        end,
        false, true, false, true)
    realSiloGlobalEventId = eventId
    RealSiloDebug.print("[realSilo][DIAG] open-toets event geregistreerd: id=%s", tostring(eventId))
end

-- Buiten alle silo-triggers blijft het ene event bestaan, maar wordt het
-- gedeactiveerd en verborgen. Daardoor slikt het geen toets en kan dezelfde
-- geldige registratie bij een volgende onEnter weer worden gebruikt.
local function realSiloRemoveGlobalEvent()
    if realSiloGlobalEventId ~= nil and g_inputBinding ~= nil then
        pcall(function() g_inputBinding:setActionEventTextVisibility(realSiloGlobalEventId, false) end)
        pcall(function() g_inputBinding:setActionEventActive(realSiloGlobalEventId, false) end)
    end
end

-- ----------------------------------------------------------------
-- Vangnet zonder eigen afstandsschatting.
--
-- De engine kent de werkelijke vorm, schaal en positie van iedere trigger
-- en meldt die via triggerId/onEnter/onLeave. Een afstand tot het rootNode
-- is daarvoor geen betrouwbare vervanging: bij een grote of verplaatste
-- silohal kan het rootNode ver buiten de echte trigger liggen.
--
-- Normaal ruimt onLeave exact de betreffende trigger-vorm op. Dit vangnet
-- grijpt alleen in als de geregistreerde silo of de lokale player-root niet
-- meer bestaat/veranderd is, bijvoorbeeld bij verwijderen of opnieuw laden.
-- Op een dedicated server bestaat g_localPlayer alleen op de client; de
-- server registreert dus geen UI-action-event en hoeft niets te synchroniseren.
-- ----------------------------------------------------------------
local realSiloSafetyTimer = 0
local function realSiloReleaseKeyIfPlayerGone(dt)
    if realSiloActiveTriggerSilo == nil then return end

    realSiloSafetyTimer = realSiloSafetyTimer + dt
    if realSiloSafetyTimer < 400 then return end
    realSiloSafetyTimer = 0

    local p = realSiloActiveTriggerSilo
    local playerRoot = g_localPlayer and g_localPlayer.rootNode or nil
    local release = p == nil
        or p.rootNode == nil
        or p.rootNode == 0
        or p.realSiloUniqueId == nil
        or playerRoot == nil
        or playerRoot == 0
        or playerRoot ~= realSiloRegisteredPlayerRoot
        or realSiloEnteredSet[p] == nil

    if release then
        realSiloEnteredSet = {}
        realSiloActiveTriggerSilo = nil
        realSiloRegisteredPlayerRoot = nil
        realSiloRemoveGlobalEvent()
    end
end

-- Speler betreedt de trigger van een eigen silo.
local function realSiloRegisterInProximity(self, triggerId, isEnter)
    if triggerId == nil then return end
    if isEnter then
        RealSiloDebug.print("[realSilo][DIAG] trigger BINNEN bij uid=%s triggerId=%s",
            tostring(self.realSiloUniqueId), tostring(triggerId))
    end
    local triggers = realSiloEnteredSet[self]
    if triggers == nil then
        triggers = {}
        realSiloEnteredSet[self] = triggers
    end
    local wasEntered = triggers[triggerId] ~= nil
    local wasActive = realSiloActiveTriggerSilo == self
    -- Niet alle GIANTS-infoTriggers sturen continu onStay. De registratie
    -- blijft daarom geldig tot de bijbehorende echte onLeave-callback.
    triggers[triggerId] = true
    realSiloActiveTriggerSilo = self
    realSiloRegisteredPlayerRoot = g_localPlayer and g_localPlayer.rootNode or nil
    if not wasEntered or not wasActive then
        realSiloEnsureGlobalEvent()
        realSiloUpdatePromptText()
    end
end

local function realSiloFindEnteredSilo()
    for placeable, triggers in pairs(realSiloEnteredSet) do
        if next(triggers) ~= nil then
            return placeable
        end
    end
    return nil
end

-- Speler verlaat precies de door de engine gemelde trigger-vorm.
local function realSiloOnLeave(self, triggerId)
    local triggers = realSiloEnteredSet[self]
    if triggers ~= nil then
        triggers[triggerId] = nil
        if next(triggers) == nil then
            realSiloEnteredSet[self] = nil
        end
    end
    if realSiloActiveTriggerSilo == self then
        realSiloActiveTriggerSilo = realSiloFindEnteredSilo()
    end
    if realSiloActiveTriggerSilo == nil then
        realSiloRegisteredPlayerRoot = nil
        -- Geen echte silo-trigger meer betreden: toets weer vrijgeven.
        realSiloRemoveGlobalEvent()
    else
        realSiloUpdatePromptText()
    end
end

-- Opruimen als een silo verdwijnt (delete / niet-farmsilo).
local function realSiloUnregisterFromProximity(self)
    realSiloEnteredSet[self] = nil
    if realSiloActiveTriggerSilo == self then
        realSiloActiveTriggerSilo = realSiloFindEnteredSilo()
    end
    if realSiloActiveTriggerSilo == nil then
        realSiloRegisteredPlayerRoot = nil
        realSiloRemoveGlobalEvent()
    else
        realSiloUpdatePromptText()
    end
end





-- ================================================================
-- Aangepaste silo-naam overal tonen (niet alleen in het R-menu)
--
-- realSiloManager.siloNames[uid] werd tot nu toe alleen door
-- RealSiloDialog zelf gelezen (voor de titelbalk van het eigen menu).
-- Overal elders -- de wereld-infobox, het shop/verkoopmenu, en andere
-- mods zoals FS25_MoistureSystem die placeable:getName() aanroepen
-- voor hun eigen UI (bv. het Shift+M droogmenu) -- bleef daardoor de
-- originele/standaard naam zichtbaar.
--
-- Placeable is een echte, gedeelde spelklasse (geen mod-eigen global
-- zoals DryingSystem), dus getName() kan hier gewoon rechtstreeks
-- gepatcht worden -- geen metatable-truc nodig, die is alleen nodig
-- voor klassen die een ANDERE mod zelf aanmaakt. Deze ene patch dekt
-- automatisch alle drie de plekken die Dennis noemde, want ze roepen
-- uiteindelijk allemaal dezelfde placeable:getName() aan.
-- ================================================================
if Placeable ~= nil and Placeable.getName ~= nil then
    local originalPlaceableGetName = Placeable.getName
    Placeable.getName = function(self, ...)
        local uid = self and self.realSiloUniqueId
        if uid then
            local customName = realSiloManager.siloNames[uid]
            if customName ~= nil and customName ~= "" then
                return customName
            end
        end
        return originalPlaceableGetName(self, ...)
    end
    RealSiloDebug.print("[realSilo] Placeable:getName() gepatcht voor aangepaste silo-namen (infobox/shop/andere mods)")
else
    RealSiloDebug.print("[realSilo][DIAG] WAARSCHUWING: Placeable of Placeable.getName niet gevonden, naam-patch niet geïnstalleerd")
end

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
        setXMLInt(xmlFile,    key .. "#dryer",        silo.config.hasDryer and 1 or 0)
        setXMLInt(xmlFile,    key .. "#transferRate", silo.config.transferRate or 1000)
        setXMLInt(xmlFile,    key .. "#extensionRange", silo.config.extensionRange or 50)
        setXMLInt(xmlFile,    key .. "#dryingAllowed", silo.config.dryingAllowed ~= false and 1 or 0)
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
            hasDryer               = (getXMLInt(xmlFile, key .. "#dryer") or 0) == 1,
            transferRate           = getXMLInt(xmlFile, key .. "#transferRate") or 1000,
            extensionRange         = getXMLInt(xmlFile, key .. "#extensionRange") or 50,
            dryingAllowed          = (getXMLInt(xmlFile, key .. "#dryingAllowed") or 1) == 1,
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
    local bestUid   = nil
    local bestDist  = math.huge
    local bestRange = 50
    for uid, silo in pairs(realSiloManager.silos) do
        local p = silo.placeable
        if p and p.rootNode and p.rootNode ~= 0 then
            local sx, sy, sz = getWorldTranslation(p.rootNode)
            local dist = MathUtil.vector3Length(ex-sx, ey-sy, ez-sz)
            if dist < bestDist then
                bestDist  = dist
                bestUid   = uid
                -- Zoekbereik is per silo instelbaar (standaard 50 m).
                bestRange = (silo.config and silo.config.extensionRange) or 50
            end
        end
    end
    if bestDist < bestRange then
        RealSiloDebug.print("[realSilo] Extension gekoppeld: afstand %.1f m (bereik %d m)", bestDist, bestRange)
        return bestUid, bestDist
    end
    RealSiloDebug.print("[realSilo] Extension NIET gekoppeld: dichtstbijzijnde silo %.1f m (bereik %d m)",
        bestDist, bestRange)
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

-- Herscan: koppel ongekoppelde extensions binnen het (mogelijk zojuist
-- gewijzigde) zoekbereik van een silo. Wordt aangeroepen nadat de
-- instelling "zoekbereik extensions" is aangepast, zodat de wijziging
-- meteen effect heeft zonder de silo opnieuw te plaatsen.
function RealSiloHookRescanExtensions(uid)
    if uid == nil then return end
    local linked = 0
    for _, ext in ipairs(allExtensions) do
        if not isExtensionLinked(ext) then
            local nearUid = findNearestRealSilo(ext)
            if nearUid == uid then
                if linkExtensionByXmlDef(ext, uid) then
                    extensionToSilo[ext] = uid
                    linked = linked + 1
                end
            end
        end
    end
    if linked > 0 then
        RealSiloDebug.print("[realSilo] Herscan: %d extension(s) alsnog gekoppeld aan %s", linked, tostring(uid))
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
        RealSiloDebug.print("[realSilo][DIAG] onLoad: silo genegeerd (geen farmSilo-fillType) - %s",
            tostring(self.configFileName))
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
    RealSiloDebug.print("[realSilo][DIAG] onLoad: silo geregistreerd, uid=%s configFile=%s",
        tostring(uid), tostring(self.configFileName))

    -- v6: extra, onafhankelijke trigger voor de MoistureSystem-
    -- compatibiliteitslaag, NAAST de bestaande Mission00.onStartMission-
    -- poging in realSiloMoistureCompat.lua. We
    -- konden in de praktijk niet bevestigen dat die onStartMission-route
    -- ooit met een geladen MoistureSystem draait, terwijl PlaceableSilo:onLoad
    -- aantoonbaar (elke keer, in elke log tot nu toe) wel afgaat. Beide
    -- routes zijn idempotent (tryInstall stopt vanzelf zodra het gelukt is),
    -- dus dit kan nooit iets dubbel installeren.
    if RealSiloMoistureCompat ~= nil and RealSiloMoistureCompat.tryInstall ~= nil then
        pcall(RealSiloMoistureCompat.tryInstall)
    end
    if RealSiloDryerCompat ~= nil and RealSiloDryerCompat.tryInstall ~= nil then
        pcall(RealSiloDryerCompat.tryInstall)
    end

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
                local extensionRange = getXMLFloat(rawXml, rsKey .. "#extensionRange") or 50
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

                -- dryer: optioneel attribuut. nil = modder heeft niets
                -- opgegeven -> speler kan de droger-instelling zelf
                -- kiezen in de dialoog. true/false = modder legt vast
                -- of dit silomodel een droger heeft (niet aanpasbaar).
                local dryerAttr = getXMLBool(rawXml, rsKey .. "#dryer")

                xmlDefined = {
                    numCompartments = numComps,
                    locked          = locked,
                    hasDryer        = dryerAttr,
                    slotCapacities  = next(slotCaps) and slotCaps or nil,
                    name            = getXMLString(rawXml, rsKey .. "#name"),
                    transferRate    = transferRate,
                    extensionRange  = extensionRange,
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
    if cfg and cfg.hasDryer then
        local s0 = realSiloManager.getSilo(uid)
        if s0 then s0.config.hasDryer = true end
    end
    if cfg and cfg.totalStorageCapacity   then
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.totalStorageCapacity = cfg.totalStorageCapacity end
    end
    if cfg and cfg.extensionRange then
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.extensionRange = cfg.extensionRange end
    end
    if cfg and cfg.dryingAllowed == false then
        -- Alleen expliciet UIT overnemen; het standaard (AAN) ligt al vast
        -- via realSiloManager.register(), en oude saves zonder dit veld
        -- laden dankzij de default "1" in loadAllSiloData() toch als AAN.
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.dryingAllowed = false end
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
        realSiloUnregisterFromProximity(self)
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
            if s2 then
                s2.config.transferRate   = xmlDef.transferRate or 1000
                s2.config.extensionRange = xmlDef.extensionRange or 50
            end
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

        -- Droger-status: ALLEEN overnemen uit XML als de modder het
        -- dryer-attribuut expliciet heeft opgegeven (anders blijft de
        -- door de speler/savegame gekozen waarde staan). Is het wel
        -- opgegeven, dan is de droger een vast onderdeel van dit
        -- silomodel: dryerXmlFixed=true maakt de instelling read-only
        -- in de dialoog (zie RealSiloDialog.lua).
        do
            local s = realSiloManager.getSilo(uid)
            if s then
                if xmlDef and xmlDef.hasDryer ~= nil then
                    s.config.hasDryer      = xmlDef.hasDryer
                    s.config.dryerXmlFixed = true
                else
                    s.config.dryerXmlFixed = false
                end
            end
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

        -- (Bewust GEEN registratie hier: de open-toets wordt pas
        --  gekoppeld als de speler daadwerkelijk een silo-trigger
        --  binnenloopt. Registreren tijdens het laden van de map zou
        --  het action-event te vroeg aanmaken -- dan werkt de toets
        --  niet en verschijnt hij ook niet in het F1-overzicht.)

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
        realSiloUnregisterFromProximity(self)
        RealSiloCompartmentStorage.cleanup(self, uid)
        realSiloManager.unregister(uid)
    end
    originalOnDelete(self)
end

-- ================================================================
-- Trigger callbacks
--
-- Bij het binnenlopen van een silo-trigger wordt de open-toets
-- geregistreerd en die silo als doel gezet; bij het verlaten wordt de
-- toets weer vrijgegeven (zodat R buiten de silo vrij blijft voor het
-- spel en andere mods).
-- ================================================================
local originalPlayerTrigger = PlaceableSilo.onPlayerActionTriggerCallback
RealSiloDebug.print("[realSilo][DIAG] hook-check: PlaceableSilo.onPlayerActionTriggerCallback bestaat=%s",
    tostring(originalPlayerTrigger ~= nil))
PlaceableSilo.onPlayerActionTriggerCallback = function(self, triggerId, otherId, onEnter, onLeave, onStay)
    originalPlayerTrigger(self, triggerId, otherId, onEnter, onLeave, onStay)
    -- Diagnose: welke voorwaarde blokkeert? In een clientlog bleek deze
    -- callback nooit tot registratie te komen (geen enkele "trigger BINNEN"),
    -- waardoor de open-toets nooit werd aangemaakt.
    if RealSiloDebug and RealSiloDebug.enabled then
        RealSiloDebug.print(
            "[realSilo][DIAG] playerTrigger: activatable=%s localPlayer=%s otherIdMatch=%s ownerFarm=%s spelerFarm=%s onEnter=%s",
            tostring(self.realSiloActivatable ~= nil),
            tostring(g_localPlayer ~= nil),
            tostring(g_localPlayer ~= nil and otherId == g_localPlayer.rootNode),
            tostring(self.getOwnerFarmId and self:getOwnerFarmId()),
            tostring(g_currentMission and g_currentMission:getFarmId()),
            tostring(onEnter))
    end
    if not self.realSiloActivatable then return end
    if not (g_localPlayer and otherId == g_localPlayer.rootNode) then return end
    if self:getOwnerFarmId() ~= g_currentMission:getFarmId() then return end
    -- onLeave heeft voorrang: sommige triggerimplementaties leveren in de
    -- overgangsframe zowel onStay als onLeave aan.
    if onLeave then
        realSiloOnLeave(self, triggerId)
    elseif onEnter or onStay then
        realSiloRegisterInProximity(self, triggerId, onEnter)
    end
end

local originalInfoTrigger = PlaceableInfoTrigger.onInfoTriggerCallback
RealSiloDebug.print("[realSilo][DIAG] hook-check: PlaceableInfoTrigger.onInfoTriggerCallback bestaat=%s",
    tostring(originalInfoTrigger ~= nil))
PlaceableInfoTrigger.onInfoTriggerCallback = function(self, triggerId, otherId, onEnter, onLeave, onStay)
    originalInfoTrigger(self, triggerId, otherId, onEnter, onLeave, onStay)
    if RealSiloDebug and RealSiloDebug.enabled then
        RealSiloDebug.print(
            "[realSilo][DIAG] infoTrigger: activatable=%s localPlayer=%s otherIdMatch=%s ownerFarm=%s spelerFarm=%s onEnter=%s",
            tostring(self.realSiloActivatable ~= nil),
            tostring(g_localPlayer ~= nil),
            tostring(g_localPlayer ~= nil and otherId == g_localPlayer.rootNode),
            tostring(self.getOwnerFarmId and self:getOwnerFarmId()),
            tostring(g_currentMission and g_currentMission:getFarmId()),
            tostring(onEnter))
    end
    if not self.realSiloActivatable then return end
    if not (g_localPlayer and otherId == g_localPlayer.rootNode) then return end
    if self:getOwnerFarmId() ~= g_currentMission:getFarmId() then return end
    if onLeave then
        realSiloOnLeave(self, triggerId)
    elseif onEnter or onStay then
        realSiloRegisterInProximity(self, triggerId, onEnter)
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
--
-- v19 -- ROBUSTHEID: gebruikte hier tot nu toe een handmatige
-- capture-en-herschrijf van FSBaseMission.update ("local originalUpdate
-- = FSBaseMission.update; FSBaseMission.update = function(self, dt)
-- originalUpdate(self, dt) ... end") in plaats van Utils.appendedFunction,
-- zoals de rest van deze mod (realSiloMoistureCompat.lua/
-- realSiloDryerCompat.lua) al wel consequent doet. Functioneel
-- hetzelfde patroon, maar Utils.appendedFunction is Giants' eigen,
-- bedoelde manier om dit te doen, en is wat andere mods doorgaans ZELF
-- ook gebruiken om HUN hook ervoor/erachter te plakken -- dus dit sluit
-- beter aan bij hoe andere mods verwachten dat FSBaseMission.update
-- opgebouwd wordt. Lost een eventuele "andere mod overschrijft
-- FSBaseMission.update hard, zonder door te schakelen" niet vanzelf op
-- (dat is een bug in díe andere mod, niet iets waar wij ons volledig
-- tegen kunnen wapenen), maar maakt realSilo zelf wel een brave,
-- voorspelbare schakel in de keten.
-- ================================================================
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(self, dt)
    -- Vulniveaus mogen alleen op de server gewijzigd worden; clients
    -- ontvangen de resultaten via de normale storage-synchronisatie.
    if g_server ~= nil then
        realSiloManager.updateTransfers(dt)
    end

    -- Vangnet voor een verdwenen/vervangen lokale speler of placeable.
    -- Binnen/buiten wordt uitsluitend door de echte engine-triggers bepaald.
    realSiloReleaseKeyIfPlayerGone(dt)
end)

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

                            -- MoistureSystem-compatibiliteit: vocht% + kwaliteitsgrade
                            -- achter de regel plakken als die mod actief is en er data is.
                            if fillAmount > 0 and slot.fillType and slot.fillType ~= 0
                               and RealSiloMoistureCompat then
                                local ownerPlaceable = slot.isExtension and slot.extPlaceable or data.placeable
                                val = val .. RealSiloMoistureCompat.getCompartmentLabel(ownerPlaceable, slot.fillType, slot, _activeSiloUid, i)
                            end

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
