-- ============================================================
-- realSiloStorageHook.lua  v11 - geconfigureerde silo's beheren
--
-- Alle hooks geven ONGECONFIGUREERDE silo's volledig door aan de
-- originele Giants-functies. Hierdoor:
--   • werkt een silo die al graan bevat (van vóór de mod) gewoon
--     zoals voorheen — storten, lossen, verkopen, alles werkt —
--     totdat de admin de silo configureert via het mod-menu
--   • gaat er nooit graan verloren bij het eerste activeren
--     van de mod op een bestaande save
--   • hoeft de mod niets te weten van de laad-timing
--
-- Bij de EERSTE configuratie door de admin leest de mod de
-- werkelijke storage-inhoud uit (storage.fillLevels) en verdeelt
-- die over de nieuw aangemaakte vakken.
--
-- GECONFIGUREERDE silo's worden wel volledig beheerd:
--   • getFillLevel/getFillLevels: alleen de "rapporterende" storage
--   • getFreeCapacity: alleen actief vak (globaal, elke storage)
--   • getCapacity: actief vak
--   • setFillLevel: boekhouding + echte storage
--
-- v10-WIJZIGING (fix "geen los-optie bij extensie"):
--   Hoofdsilo en zijn extensie(s) zijn fysiek verschillende
--   Giants-storage-objecten, maar delen ÉÉN "actief vak"-concept.
--   getFreeCapacity/getCapacity antwoorden daarom op ELKE storage
--   die bij deze silo-uid hoort, gebaseerd op het ene globale
--   actieve vak — ongeacht op welk fysiek gebouw dat vak staat.
--
-- v11-WIJZIGING (fix "kar blijft vol, extensie vult tot max"):
--   v10 loste het "0 vrije capaciteit"-probleem op, maar niet dit:
--   als je via de hoofdsilo-ingang stort terwijl het actieve vak op
--   de extensie staat, schreef de mod het graan wél correct weg naar
--   de extensie — maar getFillLevel(hoofdsilo) bleef daarna ALTIJD 0
--   melden (want dat werd enkel gerapporteerd op de storage die het
--   vak fysiek bezit). Giants gebruikt getFillLevel van PRECIES de
--   storage waar het zonet in stortte om te bepalen hoeveel er is
--   afgeleverd (voor/na-verschil) — en zag daardoor altijd 0
--   afgeleverd, waardoor de kar nooit leegde, ook al vulde de
--   boekhouding en de echte extensie-storage intussen wel degelijk.
--
--   Oplossing: we onthouden per silo-uid welke storage MOMENTEEL
--   daadwerkelijk gebruikt wordt om het actieve vak te vullen/legen
--   (data.reportStorage, bijgewerkt bij elke succesvolle setFillLevel-
--   aanroep). Alleen DIE ene storage rapporteert het actieve
--   vak-niveau; alle andere storages van dezelfde silo-groep blijven
--   op 0 — zo blijft dubbeltelling (het oude "34000 L i.p.v. 11600 L"
--   probleem) uitgesloten, terwijl de storage die daadwerkelijk in
--   gebruik is nu wél een correct, oplopend/aflopend niveau laat zien
--   aan Giants, ongeacht of dat de hoofdsilo of de extensie is.
-- ============================================================

realSiloStorageLink = realSiloStorageLink or {}

local originalGetFillLevel    = Storage.getFillLevel
local originalGetFillLevels   = Storage.getFillLevels
local originalGetFreeCapacity = Storage.getFreeCapacity
local originalGetCapacity     = Storage.getCapacity
local originalSetFillLevel    = Storage.setFillLevel

RealSiloStorageHook = RealSiloStorageHook or {}
RealSiloStorageHook.getRealFillLevel = function(storage, fillType)
    return originalGetFillLevel(storage, fillType)
end

-- ----------------------------------------------------------------
-- Virtueel fill level: enkel voor de storage die op dit moment als
-- "rapporterende" storage voor het actieve vak geldt (data.reportStorage,
-- valt terug op active.storage zolang er nog niets via de mod is
-- gestort/gehaald sinds het laatste actief-vak-wissel). Zo rapporteert
-- nooit meer dan één storage tegelijk een niveau > 0 voor dit vak —
-- dubbeltelling blijft uitgesloten — maar wel altijd de storage die
-- Giants op dit moment daadwerkelijk aanspreekt.
-- ----------------------------------------------------------------
local function reportingStorage(data, active)
    return data.reportStorage or (active and active.storage) or nil
end

local function virtualFillLevel(data, self, fillType)
    local active = data.slots[data.activeSlot]
    if not active then return 0 end
    if reportingStorage(data, active) ~= self then return 0 end
    return (active.fillType == fillType) and active.fillLevel or 0
end

-- ----------------------------------------------------------------
-- getFillLevels (MEERVOUD): toont het actieve vak aan laad-triggers
-- zodat de "selecteer silo"-dialoog slechts één product tegelijk
-- aanbiedt. Enkel op de rapporterende storage — zie virtualFillLevel.
-- Ongeconfigureerde silo's: pass-through.
-- ----------------------------------------------------------------
if originalGetFillLevels ~= nil then
    Storage.getFillLevels = function(self)
        local uid  = realSiloStorageLink[self]
        local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
        if not data or not realSiloManager.isConfigured(uid) then
            return originalGetFillLevels(self)
        end
        local active = data.slots[data.activeSlot]
        if not active or reportingStorage(data, active) ~= self
            or active.fillType == 0 or active.fillLevel <= 0 then
            return {}
        end
        return { [active.fillType] = active.fillLevel }
    end
end

-- ----------------------------------------------------------------
-- getFillLevel: het actieve vak (geconfigureerd) of echt (niet).
-- Enkel op de storage die op dit moment "rapporteert" voor dit vak.
-- ----------------------------------------------------------------
Storage.getFillLevel = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFillLevel(self, fillType)
    end
    return virtualFillLevel(data, self, fillType)
end

-- ----------------------------------------------------------------
-- getFreeCapacity: het actieve vak (geconfigureerd) of echt.
-- Elke storage die bij deze uid hoort geeft hetzelfde, correcte
-- antwoord over het ene globale actieve vak, ongeacht op welk
-- fysiek gebouw (hoofdsilo/extensie) dat vak staat. (v10, ongewijzigd)
-- ----------------------------------------------------------------
Storage.getFreeCapacity = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFreeCapacity(self, fillType)
    end
    local active = data.slots[data.activeSlot]
    if not active then return 0 end
    if active.fillType ~= 0 and fillType ~= nil and active.fillType ~= fillType then return 0 end
    return math.max(active.capacity - active.fillLevel, 0)
end

-- ----------------------------------------------------------------
-- getCapacity: actief vak (geconfigureerd) of echt.
-- ----------------------------------------------------------------
Storage.getCapacity = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetCapacity(self, fillType)
    end
    local active = data.slots[data.activeSlot]
    if active and active.storage == self then return active.capacity end
    for _, slot in ipairs(data.slots) do
        if slot.storage == self then return slot.capacity end
    end
    return 0
end

-- ----------------------------------------------------------------
-- setFillLevel: kern-logica (alleen voor geconfigureerde silo's).
-- Schrijft de echte Giants-waarde altijd naar het storage-object
-- van het ACTIEVE vak (active.storage), ongeacht via welke storage
-- (hoofdsilo of extensie) de aanvraag binnenkwam als "self". Zet
-- daarnaast data.reportStorage op "self", zodat DIE storage vanaf nu
-- (tot het actieve vak wisselt) het correcte, oplopende/aflopende
-- niveau laat zien aan Giants — cruciaal voor het voor/na-verschil
-- waarmee Giants bepaalt hoeveel er daadwerkelijk is afgeleverd.
-- ----------------------------------------------------------------
Storage.setFillLevel = function(self, fillLevel, fillType, fillInfo)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or self._realSiloApplying then
        return originalSetFillLevel(self, fillLevel, fillType, fillInfo)
    end

    -- Ongeconfigureerde silo: volledig pass-through.
    -- Hierdoor werkt bestaand graan gewoon, ook van vóór de mod.
    if not realSiloManager.isConfigured(uid) then
        return originalSetFillLevel(self, fillLevel, fillType, fillInfo)
    end

    -- Boekhouding-totaal voor déze storage (voor de load-bypass hieronder)
    local bookTotal = 0
    for _, s in ipairs(data.slots) do
        if s.storage == self and s.fillType == fillType then
            bookTotal = bookTotal + s.fillLevel
        end
    end

    local virtualCurrent = virtualFillLevel(data, self, fillType)
    local delta = fillLevel - virtualCurrent

    if delta > 0.0001 then
        -- Bypass: boekhouding klopt al → Giants laadt vanuit onze savegame
        if math.abs(bookTotal - fillLevel) < 0.5 then
            self._realSiloApplying = true
            originalSetFillLevel(self, fillLevel, fillType, fillInfo)
            self._realSiloApplying = false
            return
        end

        -- Storten in het (globale) actieve vak, ongeacht op welke
        -- storage dat vak fysiek staat.
        local active = data.slots[data.activeSlot]
        if not active then return end
        if active.fillType ~= 0 and active.fillType ~= fillType then return end

        local room  = math.max(active.capacity - active.fillLevel, 0)
        local added = math.min(delta, room)
        if added <= 0 then return end

        active.fillLevel = active.fillLevel + added
        if active.fillType == 0 then active.fillType = fillType end

        -- Vanaf nu rapporteert DEZE storage (waarlangs de storting
        -- binnenkwam) het niveau van het actieve vak aan Giants.
        data.reportStorage = self

        -- Schrijf de echte waarde naar het ECHTE storage-object van
        -- het actieve vak (kan de extensie zijn, ook al kwam de
        -- aanvraag via de hoofdsilo's storage binnen).
        local targetStorage = active.storage
        local realCurrent   = originalGetFillLevel(targetStorage, fillType)
        targetStorage._realSiloApplying = true
        originalSetFillLevel(targetStorage, realCurrent + added, fillType, fillInfo)
        targetStorage._realSiloApplying = false

    elseif delta < -0.0001 then
        local toRemove    = -delta
        local totalDrained = 0
        local active       = data.slots[data.activeSlot]

        if active and active.fillType == fillType and active.fillLevel > 0 then
            local removed = math.min(toRemove, active.fillLevel)
            active.fillLevel = active.fillLevel - removed
            if active.fillLevel <= 0.0001 then active.fillLevel = 0; active.fillType = 0 end
            toRemove     = toRemove - removed
            totalDrained = totalDrained + removed
        end

        if totalDrained > 0 then
            -- Ook bij afhalen/verkopen rapporteert DEZE storage vanaf nu.
            data.reportStorage = self

            local targetStorage = active.storage
            local realCurrent   = originalGetFillLevel(targetStorage, fillType)
            targetStorage._realSiloApplying = true
            originalSetFillLevel(targetStorage, math.max(realCurrent - totalDrained, 0), fillType, fillInfo)
            targetStorage._realSiloApplying = false
        end
    end
end

RealSiloDebug.print("[realSilo] Storage hooks geïnstalleerd (v11 - rapporterende storage volgt actieve los-/laadpunt)")
