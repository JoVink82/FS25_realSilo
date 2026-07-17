-- ============================================================
-- realSiloEvents.lua
--
-- Multiplayer-synchronisatie voor alle door de speler getriggerde
-- wijzigingen (instellingen-dialoog).
--
-- Elk event heeft een expliciete vlag "isBroadcast":
--   - isBroadcast = false  -> een VERZOEK (van een client naar de
--                             server, of de eerste keer dat de host
--                             zelf iets uitvoert)
--   - isBroadcast = true   -> een RESULTAAT-broadcast (van de server
--                             naar alle clients, incl. eventuele
--                             loopback-verbinding van de host)
--
-- :run(connection) past de wijziging ALTIJD toe (apply), maar
-- broadcast ALLEEN verder als g_server ~= nil EN isBroadcast == false.
-- Een broadcast-event (isBroadcast == true) broadcast NOOIT opnieuw --
-- dit voorkomt een oneindige lus.
--
-- broadcastEvent(event, noEventToSelf, connection, target): het 2e
-- argument staat overal op TRUE. Bevestigd via een log waarin elke
-- klik op de host (zowel singleplayer als de admin-client op een
-- dedicated server) een dubbele melding gaf ("Actief vak voor ...:
-- vak X" twee keer kort na elkaar): de host past de wijziging al
-- direct lokaal toe vóór het broadcasten, en is tegelijk zijn eigen
-- "client" via een lokale loopback-verbinding. Met noEventToSelf op
-- FALSE ontving de host zijn eigen broadcast dus een tweede keer en
-- verwerkte hem opnieuw. Op TRUE slaat de host die loopback over,
-- precies zoals bedoeld: lokaal is het al toegepast, de broadcast is
-- alleen voor de ANDERE clients.
-- ============================================================

RealSiloEvents = {}

-- ------------------------------------------------------------
-- Helper: ververs de open dialoog (indien open voor deze silo)
-- ------------------------------------------------------------
function RealSiloEvents.refreshDialog(uid)
    local dlg = RealSiloDialog.INSTANCE
    if not dlg then return end
    if RealSiloDialog.currentUniqueId ~= uid then return end

    dlg:refreshList()
    if dlg.compartmentList then dlg.compartmentList:reloadData() end
    if dlg.updateActiveSlotInfo then dlg:updateActiveSlotInfo() end
    if dlg.updateTransferStatus then dlg:updateTransferStatus() end
end

-- ============================================================
-- 1) Silo-instellingen (aantal silo's, capaciteit, naam, transfer rate)
-- ============================================================
RealSiloConfigEvent = {}
local RealSiloConfigEvent_mt = Class(RealSiloConfigEvent, Event)
InitEventClass(RealSiloConfigEvent, "RealSiloConfigEvent")

function RealSiloConfigEvent.emptyNew()
    return Event.new(RealSiloConfigEvent_mt)
end

function RealSiloConfigEvent.new(uid, numComps, capacity, name, transferRate, isBroadcast, isConfigured)
    local self = RealSiloConfigEvent.emptyNew()
    self.uid              = uid
    self.numComps         = numComps
    self.capacity         = capacity
    self.name             = name or ""
    self.transferRate     = transferRate or 1000
    self.isBroadcast      = isBroadcast or false
    self.isServerConfigured = isConfigured or false
    return self
end

function RealSiloConfigEvent:readStream(streamId, connection)
    self.uid              = streamReadString(streamId)
    self.numComps         = streamReadUIntN(streamId, 6)
    self.capacity         = streamReadUIntN(streamId, 32)
    self.name             = streamReadString(streamId)
    self.transferRate     = streamReadUIntN(streamId, 16)
    self.isBroadcast      = streamReadBool(streamId)
    self.isServerConfigured = streamReadBool(streamId)
    self:run(connection)
end

function RealSiloConfigEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    streamWriteUIntN(streamId, self.numComps, 6)
    streamWriteUIntN(streamId, self.capacity, 32)
    streamWriteString(streamId, self.name)
    streamWriteUIntN(streamId, self.transferRate, 16)
    streamWriteBool(streamId, self.isBroadcast)
    streamWriteBool(streamId, self.isServerConfigured)
end

function RealSiloConfigEvent.apply(uid, numComps, capacity, name, transferRate, serverConfirmsConfigured)
    realSiloManager.setSiloName(uid, name)
    local silo = realSiloManager.getSilo(uid)
    if silo then silo.config.transferRate = transferRate end

    RealSiloDebug.print(
        "[realSilo][DIAG] ConfigEvent.apply VOOR: uid=%s gevraagd numComps=%d capacity=%d | silo gevonden=%s huidigeNumComps=%s",
        tostring(uid), numComps, capacity, tostring(silo ~= nil),
        tostring(silo and silo.config.numCompartments))

    local ok, err = realSiloManager.applyConfig(uid, numComps, capacity)

    RealSiloDebug.print(
        "[realSilo][DIAG] ConfigEvent.apply NA: ok=%s err=%s nieuweNumComps=%s",
        tostring(ok), tostring(err), tostring(silo and silo.config.numCompartments))

    -- setConfigured alleen als de server dit bevestigt (of als we zelf
    -- de server/singleplayer zijn die de config toepast).
    -- Een client die via de sync-event de default-config binnenkrijgt
    -- van een ongeconfigureerde silo mag NIET setConfigured aanroepen —
    -- anders denkt de client dat de silo klaar is terwijl de server
    -- weet dat de admin hem nog niet heeft ingesteld.
    if ok and (serverConfirmsConfigured or g_server ~= nil) then
        realSiloManager.setConfigured(uid)
        RealSiloCompartmentStorage.captureAndDistribute(uid)
        RealSiloEvents.broadcastSlotSync(uid)
    end
    RealSiloEvents.refreshDialog(uid)
    return ok, err
end

function RealSiloConfigEvent:run(connection)
    RealSiloDebug.print(
        "[realSilo][DIAG] ConfigEvent:run uid=%s numComps=%d isBroadcast=%s g_server=%s connection=%s isServerConfigured=%s",
        tostring(self.uid), self.numComps, tostring(self.isBroadcast),
        tostring(g_server ~= nil), tostring(connection ~= nil), tostring(self.isServerConfigured))
    if g_server ~= nil and connection ~= nil and not self.isBroadcast then
        if not RealSiloUtil.canManageSilo(self.uid, connection) then
            RealSiloDebug.print("[realSilo] Config-wijziging geweigerd: geen toestemming")
            return
        end
    end
    -- Op de SERVER geldt: isServerConfigured = true (we stellen zelf in).
    -- Bij een BROADCAST naar clients: gebruik de vlag die meegestuurd is.
    local confirmedConfigured = self.isServerConfigured or (g_server ~= nil and not self.isBroadcast)
    RealSiloConfigEvent.apply(self.uid, self.numComps, self.capacity, self.name, self.transferRate, confirmedConfigured)
    if g_server ~= nil and not self.isBroadcast then
        g_server:broadcastEvent(
            RealSiloConfigEvent.new(self.uid, self.numComps, self.capacity, self.name, self.transferRate, true, true),
            true, nil, nil)
    end
end

-- Aanroepen vanuit de dialoog
function RealSiloEvents.sendConfig(uid, numComps, capacity, name, transferRate)
    if not RealSiloUtil.canManageSiloLocal(uid) then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_noPermission") or "Je hebt geen toestemming om deze silo te beheren.")
        return false, "noPermission"
    end
    local ok, err = RealSiloConfigEvent.apply(uid, numComps, capacity, name, transferRate, true)
    if g_server ~= nil then
        g_server:broadcastEvent(RealSiloConfigEvent.new(uid, numComps, capacity, name, transferRate, true, true), true, nil, nil)
    else
        g_client:getServerConnection():sendEvent(RealSiloConfigEvent.new(uid, numComps, capacity, name, transferRate, false, false))
    end
    return ok, err
end


-- ============================================================
-- 2) Capaciteit van één compartiment (normaal of extension-vak)
-- ============================================================
RealSiloSlotCapacityEvent = {}
local RealSiloSlotCapacityEvent_mt = Class(RealSiloSlotCapacityEvent, Event)
InitEventClass(RealSiloSlotCapacityEvent, "RealSiloSlotCapacityEvent")

function RealSiloSlotCapacityEvent.emptyNew()
    return Event.new(RealSiloSlotCapacityEvent_mt)
end

function RealSiloSlotCapacityEvent.new(uid, slotIndex, newCap, isBroadcast)
    local self = RealSiloSlotCapacityEvent.emptyNew()
    self.uid         = uid
    self.slotIndex   = slotIndex
    self.newCap      = newCap
    self.isBroadcast = isBroadcast or false
    return self
end

function RealSiloSlotCapacityEvent:readStream(streamId, connection)
    self.uid         = streamReadString(streamId)
    self.slotIndex   = streamReadUIntN(streamId, 6)
    self.newCap      = streamReadUIntN(streamId, 32)
    self.isBroadcast = streamReadBool(streamId)
    self:run(connection)
end

function RealSiloSlotCapacityEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    streamWriteUIntN(streamId, self.slotIndex, 6)
    streamWriteUIntN(streamId, self.newCap, 32)
    streamWriteBool(streamId, self.isBroadcast)
end

function RealSiloSlotCapacityEvent.apply(uid, slotIndex, newCap)
    local ok = RealSiloCompartmentStorage.setSlotCapacity(uid, slotIndex, newCap)
    RealSiloEvents.refreshDialog(uid)
    return ok
end

function RealSiloSlotCapacityEvent:run(connection)
    if g_server ~= nil and connection ~= nil and not self.isBroadcast then
        if not RealSiloUtil.canManageSilo(self.uid, connection) then
            RealSiloDebug.print("[realSilo] Vak-capaciteit wijziging geweigerd: geen toestemming")
            return
        end
    end
    RealSiloSlotCapacityEvent.apply(self.uid, self.slotIndex, self.newCap)
    if g_server ~= nil and not self.isBroadcast then
        g_server:broadcastEvent(
            RealSiloSlotCapacityEvent.new(self.uid, self.slotIndex, self.newCap, true),
            true, nil, nil)
    end
end

function RealSiloEvents.sendSlotCapacity(uid, slotIndex, newCap)
    if not RealSiloUtil.canManageSiloLocal(uid) then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_noPermission") or "Je hebt geen toestemming om deze silo te beheren.")
        return false
    end
    local ok = RealSiloSlotCapacityEvent.apply(uid, slotIndex, newCap)
    if g_server ~= nil then
        g_server:broadcastEvent(RealSiloSlotCapacityEvent.new(uid, slotIndex, newCap, true), true, nil, nil)
    else
        g_client:getServerConnection():sendEvent(RealSiloSlotCapacityEvent.new(uid, slotIndex, newCap, false))
    end
    return ok
end


-- ============================================================
-- 3) Actief vak selecteren
-- ============================================================
RealSiloActiveSlotEvent = {}
local RealSiloActiveSlotEvent_mt = Class(RealSiloActiveSlotEvent, Event)
InitEventClass(RealSiloActiveSlotEvent, "RealSiloActiveSlotEvent")

function RealSiloActiveSlotEvent.emptyNew()
    return Event.new(RealSiloActiveSlotEvent_mt)
end

function RealSiloActiveSlotEvent.new(uid, slotIndex, isBroadcast)
    local self = RealSiloActiveSlotEvent.emptyNew()
    self.uid         = uid
    self.slotIndex   = slotIndex
    self.isBroadcast = isBroadcast or false
    return self
end

function RealSiloActiveSlotEvent:readStream(streamId, connection)
    self.uid         = streamReadString(streamId)
    self.slotIndex   = streamReadUIntN(streamId, 6)
    self.isBroadcast = streamReadBool(streamId)
    self:run(connection)
end

function RealSiloActiveSlotEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    streamWriteUIntN(streamId, self.slotIndex, 6)
    streamWriteBool(streamId, self.isBroadcast)
end

function RealSiloActiveSlotEvent.apply(uid, slotIndex)
    RealSiloCompartmentStorage.setActiveSlot(uid, slotIndex)
    RealSiloEvents.refreshDialog(uid)
end

function RealSiloActiveSlotEvent:run(connection)
    RealSiloActiveSlotEvent.apply(self.uid, self.slotIndex)
    if g_server ~= nil and not self.isBroadcast then
        g_server:broadcastEvent(
            RealSiloActiveSlotEvent.new(self.uid, self.slotIndex, true),
            true, nil, nil)
    end
end

function RealSiloEvents.sendActiveSlot(uid, slotIndex)
    RealSiloActiveSlotEvent.apply(uid, slotIndex)
    if g_server ~= nil then
        g_server:broadcastEvent(RealSiloActiveSlotEvent.new(uid, slotIndex, true), true, nil, nil)
    else
        g_client:getServerConnection():sendEvent(RealSiloActiveSlotEvent.new(uid, slotIndex, false))
    end
end


-- ============================================================
-- 4) Transfer starten/stoppen
--    action: 1 = start, 0 = stop
-- ============================================================
RealSiloTransferEvent = {}
local RealSiloTransferEvent_mt = Class(RealSiloTransferEvent, Event)
InitEventClass(RealSiloTransferEvent, "RealSiloTransferEvent")

function RealSiloTransferEvent.emptyNew()
    return Event.new(RealSiloTransferEvent_mt)
end

function RealSiloTransferEvent.new(uid, action, fromSlot, toSlot, rate, isBroadcast)
    local self = RealSiloTransferEvent.emptyNew()
    self.uid         = uid
    self.action      = action and 1 or 0
    self.fromSlot    = fromSlot or 0
    self.toSlot      = toSlot or 0
    self.rate        = rate or 0
    self.isBroadcast = isBroadcast or false
    return self
end

function RealSiloTransferEvent:readStream(streamId, connection)
    self.uid         = streamReadString(streamId)
    self.action      = streamReadUIntN(streamId, 1)
    self.fromSlot    = streamReadUIntN(streamId, 6)
    self.toSlot      = streamReadUIntN(streamId, 6)
    self.rate        = streamReadUIntN(streamId, 20)
    self.isBroadcast = streamReadBool(streamId)
    self:run(connection)
end

function RealSiloTransferEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    streamWriteUIntN(streamId, self.action, 1)
    streamWriteUIntN(streamId, self.fromSlot, 6)
    streamWriteUIntN(streamId, self.toSlot, 6)
    streamWriteUIntN(streamId, self.rate, 20)
    streamWriteBool(streamId, self.isBroadcast)
end

function RealSiloTransferEvent.apply(uid, action, fromSlot, toSlot, rate)
    local ok, err
    if action == 1 then
        local silo = realSiloManager.getSilo(uid)
        if silo then silo.config.transferRate = rate end
        ok, err = realSiloManager.startTransfer(uid, fromSlot, toSlot, rate)
    else
        realSiloManager.stopTransfer(uid)
        if g_server ~= nil then
            RealSiloEvents.broadcastSlotSync(uid)
        end
        ok = true
    end
    RealSiloEvents.refreshDialog(uid)
    return ok, err
end

function RealSiloTransferEvent:run(connection)
    RealSiloTransferEvent.apply(self.uid, self.action, self.fromSlot, self.toSlot, self.rate)
    if g_server ~= nil and not self.isBroadcast then
        g_server:broadcastEvent(
            RealSiloTransferEvent.new(self.uid, self.action == 1, self.fromSlot, self.toSlot, self.rate, true),
            true, nil, nil)
    end
end

-- action: true = start, false = stop
function RealSiloEvents.sendTransfer(uid, action, fromSlot, toSlot, rate)
    local ok, err = RealSiloTransferEvent.apply(uid, action and 1 or 0, fromSlot or 0, toSlot or 0, rate or 0)
    if g_server ~= nil then
        g_server:broadcastEvent(RealSiloTransferEvent.new(uid, action, fromSlot, toSlot, rate, true), true, nil, nil)
    else
        g_client:getServerConnection():sendEvent(RealSiloTransferEvent.new(uid, action, fromSlot, toSlot, rate, false))
    end
    return ok, err
end


-- ============================================================
-- 5) Extension: aantal vakken wijzigen (relink)
-- ============================================================
RealSiloExtensionRelinkEvent = {}
local RealSiloExtensionRelinkEvent_mt = Class(RealSiloExtensionRelinkEvent, Event)
InitEventClass(RealSiloExtensionRelinkEvent, "RealSiloExtensionRelinkEvent")

function RealSiloExtensionRelinkEvent.emptyNew()
    return Event.new(RealSiloExtensionRelinkEvent_mt)
end

-- extPlaceable: het SiloExtension placeable-object (netwerk-object)
function RealSiloExtensionRelinkEvent.new(uid, extPlaceable, newNum, isBroadcast)
    local self = RealSiloExtensionRelinkEvent.emptyNew()
    self.uid          = uid
    self.extPlaceable = extPlaceable
    self.newNum       = newNum
    self.isBroadcast  = isBroadcast or false
    return self
end

function RealSiloExtensionRelinkEvent:readStream(streamId, connection)
    self.uid          = streamReadString(streamId)
    self.extPlaceable = NetworkUtil.readNodeObject(streamId)
    self.newNum       = streamReadUIntN(streamId, 4)
    self.isBroadcast  = streamReadBool(streamId)
    self:run(connection)
end

function RealSiloExtensionRelinkEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    NetworkUtil.writeNodeObject(streamId, self.extPlaceable)
    streamWriteUIntN(streamId, self.newNum, 4)
    streamWriteBool(streamId, self.isBroadcast)
end

function RealSiloExtensionRelinkEvent.apply(uid, extPlaceable, newNum)
    if not extPlaceable then return false end

    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end

    -- Verzamel de huidige vakken van deze extension
    local items = {}
    for _, slot in ipairs(data.slots) do
        if slot.isExtension and slot.extPlaceable == extPlaceable then
            table.insert(items, slot)
        end
    end
    if #items == 0 then return false end

    -- Mag niet als er nog product in zit
    local totalFill = 0
    for _, slot in ipairs(items) do
        totalFill = totalFill + (slot.fillLevel or 0)
    end
    if totalFill > 0 then
        RealSiloEvents.refreshDialog(uid)
        return false, "extMustBeEmpty"
    end

    -- Totale capaciteit behouden, gelijk verdelen over nieuwe vakken
    local totalCap = 0
    for _, slot in ipairs(items) do
        totalCap = totalCap + (slot.capacity or 0)
    end
    local capPer = math.max(math.floor(totalCap / newNum), 1000)
    local comps = {}
    for c = 1, newNum do
        table.insert(comps, { cap = capPer, fillType = 0, fillLevel = 0, isActive = false })
    end

    local ok = RealSiloExtensionManager.relink(extPlaceable, uid, comps)
    RealSiloEvents.refreshDialog(uid)
    return ok
end

function RealSiloExtensionRelinkEvent:run(connection)
    if g_server ~= nil and connection ~= nil and not self.isBroadcast then
        if not RealSiloUtil.canManageSilo(self.uid, connection) then
            RealSiloDebug.print("[realSilo] Extension-herconfiguratie geweigerd: geen toestemming")
            return
        end
    end
    RealSiloExtensionRelinkEvent.apply(self.uid, self.extPlaceable, self.newNum)
    if g_server ~= nil and not self.isBroadcast then
        g_server:broadcastEvent(
            RealSiloExtensionRelinkEvent.new(self.uid, self.extPlaceable, self.newNum, true),
            true, nil, nil)
    end
end

function RealSiloEvents.sendExtensionRelink(uid, extPlaceable, newNum)
    if not RealSiloUtil.canManageSiloLocal(uid) then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_noPermission") or "Je hebt geen toestemming om deze silo te beheren.")
        return false, "noPermission"
    end
    local ok, err = RealSiloExtensionRelinkEvent.apply(uid, extPlaceable, newNum)
    if ok then
        if g_server ~= nil then
            g_server:broadcastEvent(RealSiloExtensionRelinkEvent.new(uid, extPlaceable, newNum, true), true, nil, nil)
        else
            g_client:getServerConnection():sendEvent(RealSiloExtensionRelinkEvent.new(uid, extPlaceable, newNum, false))
        end
    end
    return ok, err
end

RealSiloDebug.print("[realSilo] Multiplayer events geladen")

-- ============================================================
-- 6) Sync bij het joinen: client vraagt, server antwoordt
--    GERICHT aan die ene verbinding (niet broadcast).
--
-- Waarom een eigen Event in plaats van onWriteStream/onReadStream
-- op het placeable-object zelf: een Event is een zelfstandig
-- pakket met zijn eigen readStream/writeStream. Het kan nooit de
-- stream van een ander (willekeurig) object op hetzelfde moment
-- verstoren. onWriteStream/onReadStream direct overschrijven raakt
-- een niet-gedocumenteerd, intern Giants-protocol waarvan de exacte
-- volgorde/aanroepmomenten niet te verifiëren zijn — en dat bleek
-- in de praktijk de boel te corrumperen (zie testlog: andere,
-- ongerelateerde objecten gingen stuk op het join-moment).
-- ============================================================

-- ----- Extension-koppeling: server -> één specifieke client -----
RealSiloExtensionSyncEvent = {}
local RealSiloExtensionSyncEvent_mt = Class(RealSiloExtensionSyncEvent, Event)
InitEventClass(RealSiloExtensionSyncEvent, "RealSiloExtensionSyncEvent")

function RealSiloExtensionSyncEvent.emptyNew()
    return Event.new(RealSiloExtensionSyncEvent_mt)
end

function RealSiloExtensionSyncEvent.new(uid, extPlaceable, comps)
    local self = RealSiloExtensionSyncEvent.emptyNew()
    self.uid          = uid
    self.extPlaceable = extPlaceable
    self.comps        = comps
    return self
end

function RealSiloExtensionSyncEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    NetworkUtil.writeNodeObject(streamId, self.extPlaceable)
    streamWriteUIntN(streamId, math.min(#self.comps, 31), 5)
    for _, c in ipairs(self.comps) do
        streamWriteUIntN(streamId, math.min(math.max(math.floor(c.cap), 0), 4294967295), 32)
        streamWriteUIntN(streamId, math.min(math.max(c.fillType, 0), 16383), 14)
        streamWriteUIntN(streamId, math.min(math.max(math.floor(c.fillLevel), 0), 4294967295), 32)
        streamWriteBool(streamId, c.isActive)
    end
end

function RealSiloExtensionSyncEvent:readStream(streamId, connection)
    self.uid          = streamReadString(streamId)
    self.extPlaceable = NetworkUtil.readNodeObject(streamId)
    local n = streamReadUIntN(streamId, 5)
    self.comps = {}
    for _ = 1, n do
        table.insert(self.comps, {
            cap       = streamReadUIntN(streamId, 32),
            fillType  = streamReadUIntN(streamId, 14),
            fillLevel = streamReadUIntN(streamId, 32),
            isActive  = streamReadBool(streamId),
        })
    end
    self:run(connection)
end

function RealSiloExtensionSyncEvent:run(connection)
    if self.extPlaceable ~= nil and not self.extPlaceable._realSiloIgnored then
        RealSiloExtensionManager.relink(self.extPlaceable, self.uid, self.comps)
        RealSiloEvents.refreshDialog(self.uid)
        RealSiloDebug.print(string.format("[realSilo] Extension-koppeling ontvangen van server: %s (%d vak(ken))",
            tostring(self.uid), #self.comps))
    end
end

-- Verzamel de huidige koppel-data van een extension (op de server),
-- rechtstreeks uit de boekhouding (geen apart storage-object meer per vak).
local function collectExtensionSyncData(extPlaceable)
    local uid = nil
    local multi = RealSiloExtensionManager.linkedMulti[extPlaceable]
    if multi then uid = multi[1].uid end
    local single = RealSiloExtensionManager.linked[extPlaceable]
    if single then uid = single.uid end
    if not uid then return nil, nil end

    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return nil, nil end

    local comps = {}
    for _, slot in ipairs(data.slots) do
        if slot.extPlaceable == extPlaceable then
            table.insert(comps, {
                cap       = slot.capacity or 0,
                fillType  = slot.fillType or 0,
                fillLevel = slot.fillLevel or 0,
                isActive  = slot.isActive or false,
            })
        end
    end
    if #comps == 0 then return nil, nil end
    return uid, comps
end

-- ----- Sync-verzoek: client -> server -----
RealSiloSyncRequestEvent = {}
local RealSiloSyncRequestEvent_mt = Class(RealSiloSyncRequestEvent, Event)
InitEventClass(RealSiloSyncRequestEvent, "RealSiloSyncRequestEvent")

function RealSiloSyncRequestEvent.emptyNew()
    return Event.new(RealSiloSyncRequestEvent_mt)
end

function RealSiloSyncRequestEvent.new()
    return RealSiloSyncRequestEvent.emptyNew()
end

function RealSiloSyncRequestEvent:writeStream(streamId, connection)
end

function RealSiloSyncRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

function RealSiloSyncRequestEvent:run(connection)
    if g_server == nil or connection == nil then return end

    -- Stuur de configuratie van elke silo, gericht aan deze ene
    -- verbinding (niet broadcast naar alle andere clients).
    for uid, silo in pairs(realSiloManager.silos) do
        local cfg = silo.config
        connection:sendEvent(RealSiloConfigEvent.new(
            uid,
            cfg.numCompartments,
            cfg.capacityPerCompartment,
            realSiloManager.getSiloName(uid),
            cfg.transferRate or 1000,
            true,
            realSiloManager.isConfigured(uid)))
    end

    -- Stuur de koppeling van elke gekoppelde extension, eveneens
    -- gericht aan deze ene verbinding.
    for extPlaceable, _ in pairs(RealSiloExtensionManager.linked) do
        local uid, comps = collectExtensionSyncData(extPlaceable)
        if uid then
            connection:sendEvent(RealSiloExtensionSyncEvent.new(uid, extPlaceable, comps))
        end
    end
    for extPlaceable, _ in pairs(RealSiloExtensionManager.linkedMulti) do
        local uid, comps = collectExtensionSyncData(extPlaceable)
        if uid then
            connection:sendEvent(RealSiloExtensionSyncEvent.new(uid, extPlaceable, comps))
        end
    end

    -- Stuur ook de slot-inhoud per silo
    for uid, _ in pairs(realSiloManager.silos) do
        RealSiloEvents.sendSlotSync(uid, connection)
    end

    RealSiloDebug.print("[realSilo] Sync-verzoek beantwoord voor nieuwe verbinding")
end

function RealSiloEvents.requestSync()
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(RealSiloSyncRequestEvent.new())
        RealSiloDebug.print("[realSilo] Sync-verzoek verstuurd naar server")
    end
end

-- ============================================================
-- 7) Slot-inhoud sync: server → één client of broadcast
--    Stuurt de daadwerkelijke vulling (fillType + fillLevel)
--    per vak van een silo. Nodig omdat de config-sync alleen
--    capaciteit/aantallen meestuurt, niet de inhoud.
-- ============================================================
RealSiloSlotSyncEvent = {}
local RealSiloSlotSyncEvent_mt = Class(RealSiloSlotSyncEvent, Event)
InitEventClass(RealSiloSlotSyncEvent, "RealSiloSlotSyncEvent")

function RealSiloSlotSyncEvent.emptyNew()
    return Event.new(RealSiloSlotSyncEvent_mt)
end

function RealSiloSlotSyncEvent.new(uid, slots, isBroadcast)
    local self = RealSiloSlotSyncEvent.emptyNew()
    self.uid         = uid
    self.slots       = slots
    self.isBroadcast = isBroadcast or false
    return self
end

function RealSiloSlotSyncEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.uid)
    streamWriteBool(streamId, self.isBroadcast)
    streamWriteUIntN(streamId, math.min(#self.slots, 63), 6)
    for _, s in ipairs(self.slots) do
        streamWriteUIntN(streamId, math.min(math.max(s.fillType  or 0, 0), 16383), 14)
        streamWriteUIntN(streamId, math.min(math.max(math.floor(s.fillLevel or 0), 0), 4294967295), 32)
        streamWriteUIntN(streamId, math.min(math.max(math.floor(s.capacity  or 0), 0), 4294967295), 32)
        streamWriteBool(streamId, s.isActive or false)
    end
end

function RealSiloSlotSyncEvent:readStream(streamId, connection)
    self.uid         = streamReadString(streamId)
    self.isBroadcast = streamReadBool(streamId)
    local n = streamReadUIntN(streamId, 6)
    self.slots = {}
    for _ = 1, n do
        table.insert(self.slots, {
            fillType  = streamReadUIntN(streamId, 14),
            fillLevel = streamReadUIntN(streamId, 32),
            capacity  = streamReadUIntN(streamId, 32),
            isActive  = streamReadBool(streamId),
        })
    end
    self:run(connection)
end

function RealSiloSlotSyncEvent:run(connection)
    if g_server ~= nil and not self.isBroadcast then
        -- Ontvangen op server: stuur terug naar alle clients als broadcast
        g_server:broadcastEvent(
            RealSiloSlotSyncEvent.new(self.uid, self.slots, true), true, nil, nil)
        return
    end

    -- Ontvangen op client: pas lokale boekhouding aan
    local data = RealSiloCompartmentStorage.siloSlots[self.uid]
    if not data then return end

    for i, incoming in ipairs(self.slots) do
        local slot = data.slots[i]
        if slot then
            -- Extension-slots bijwerken als ze al bestaan op de client
            -- (aangemaakt via RealSiloExtensionSyncEvent). Als ze er nog
            -- niet zijn, slaan we ze over — ze worden later aangemaakt.
            slot.fillType  = incoming.fillType
            slot.fillLevel = incoming.fillLevel
            if incoming.capacity > 0 then slot.capacity = incoming.capacity end
            slot.isActive  = incoming.isActive
        end
    end

    -- Actief vak bijwerken
    for i, slot in ipairs(data.slots) do
        if slot.isActive then data.activeSlot = i end
    end

    RealSiloEvents.refreshDialog(self.uid)
end

-- Bouw de slot-data op uit de lokale boekhouding (voor verzenden)
local function buildSlotSyncData(uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return nil end
    local slots = {}
    for _, slot in ipairs(data.slots) do
        -- Alle slots meesturen: zowel gewone als extension-vakken.
        -- Extension-vakken zijn op de client al aangemaakt via
        -- RealSiloExtensionSyncEvent; we updaten hier alleen de inhoud.
        table.insert(slots, {
            fillType  = slot.fillType  or 0,
            fillLevel = slot.fillLevel or 0,
            capacity  = slot.capacity  or 0,
            isActive  = slot.isActive  or false,
        })
    end
    return #slots > 0 and slots or nil
end

-- Stuur slot-inhoud van één silo naar één verbinding
function RealSiloEvents.sendSlotSync(uid, connection)
    local slots = buildSlotSyncData(uid)
    if not slots or not connection then return end
    connection:sendEvent(RealSiloSlotSyncEvent.new(uid, slots, false))
end

-- Broadcast slot-inhoud naar alle clients (bv. na transfer)
function RealSiloEvents.broadcastSlotSync(uid)
    if g_server == nil then return end
    local slots = buildSlotSyncData(uid)
    if not slots then return end
    g_server:broadcastEvent(RealSiloSlotSyncEvent.new(uid, slots, true), true, nil, nil)
end

