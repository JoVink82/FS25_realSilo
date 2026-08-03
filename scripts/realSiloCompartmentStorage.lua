-- ============================================================
-- realSiloCompartmentStorage.lua  v2 - multiplayer-veilig
--
-- BELANGRIJK ARCHITECTUURVERSCHIL met v1:
-- Deze versie maakt GEEN eigen Storage-objecten meer aan en
-- vervangt NOOIT placeable.spec_silo.storages / spec_siloExtension.storage.
--
-- Waarom: Giants' eigen PlaceableSilo:onWriteStream/onReadStream
-- (en PlaceableSiloExtension's varianten) lopen over
-- "#spec.storages" met `ipairs` en sturen/lezen exact zoveel
-- storage-blokken als er entries in die lijst staan. Als de
-- server en de client een ANDER aantal entries hebben (omdat
-- v1 dat aantal zelf bepaalde, en de client geen toegang had tot
-- realSiloData.xml), raakt de hele netwerk-stream vanaf dat punt
-- corrupt — niet alleen voor onze silo, maar voor ELK object dat
-- daarna in dezelfde stream meegestuurd wordt. Dat verklaarde de
-- crashes in Storage.lua én (ongerelateerd) FeedingRobot.lua bij
-- het joinen, en de hang die daarna volgde.
--
-- Oplossing: de ECHTE, door Giants aangemaakte en gesynchroniseerde
-- storage(s) blijven exact zoals de placeable-XML ze definieert
-- (zelfde aantal, dezelfde identiteit, op server én client).
-- "Vakken" bestaan alleen nog als ONZE EIGEN boekhouding (fillType,
-- fillLevel, capacity per vak) boven op die echte storage. Een
-- Storage-method-hook (zie realSiloStorageHook.lua) zorgt dat
-- storten alleen in het actieve vak terechtkomt en geclampt wordt
-- op de capaciteit van dat vak; de ECHTE storage krijgt daarna
-- gewoon de nieuwe, juiste totaalwaarde via de normale
-- Storage:setFillLevel-API, die door Giants zelf al correct over
-- het netwerk gesynchroniseerd wordt (dirty-flag systeem) — exact
-- zoals een gewone, onaangepaste silo dat al doet.
-- ============================================================

RealSiloCompartmentStorage = {}

-- [silo uniqueId] = { placeable=, activeSlot=1, slots={ {index, fillType,
--   fillLevel, capacity, isActive, storage=<echt Storage-object>,
--   isExtension, xmlLocked, extPlaceable}, ... } }
RealSiloCompartmentStorage.siloSlots = {}

-- ----------------------------------------------------------------
-- Initialiseer de vak-boekhouding voor een silo. Raakt de echte
-- storage(s) van de placeable NIET aan (geen vervanging, geen
-- nieuwe registratie) — alleen onze eigen boekhouding wordt
-- (opnieuw) opgebouwd.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.initialize(placeable, uid, numSlots, capacity)
    local spec = placeable.spec_silo
    if spec == nil or spec.storages == nil or #spec.storages == 0 then
        RealSiloDebug.print("[realSilo] FOUT: geen spec_silo.storages op placeable")
        return false
    end

    -- We koppelen alle gewone vakken aan de eerste echte storage.
    -- (Silo's met meerdere XML-storages, bv. "storagePerFarm", worden
    -- hierdoor niet apart per storage opgesplitst — dat is een zeldzame
    -- situatie die buiten de scope van deze mod valt.)
    local realStorage = spec.storages[1]

    local slots = {}
    for i = 1, numSlots do
        table.insert(slots, {
            index    = i,
            fillType = 0,
            fillLevel = 0,
            capacity = capacity,
            isActive = (i == 1),
            storage  = realStorage,
        })
    end

    RealSiloCompartmentStorage.siloSlots[uid] = {
        placeable  = placeable,
        activeSlot = 1,
        slots      = slots,
    }

    realSiloStorageLink[realStorage] = uid

    RealSiloDebug.print(string.format("[realSilo] %d vak(ken) geïnitialiseerd voor %s (boekhouding, geen nieuwe storage-objecten)",
        numSlots, uid))
    return true
end

-- ----------------------------------------------------------------
-- Opruimen: alleen onze eigen boekhouding. De echte storage wordt
-- door Giants' eigen PlaceableSilo:onDelete al netjes opgeruimd.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.cleanup(placeable, uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end

    for _, slot in ipairs(data.slots) do
        if slot.storage and realSiloStorageLink[slot.storage] == uid then
            realSiloStorageLink[slot.storage] = nil
        end
    end

    RealSiloCompartmentStorage.siloSlots[uid] = nil
    RealSiloDebug.print(string.format("[realSilo] Vak-boekhouding verwijderd voor %s", uid))
end

-- ----------------------------------------------------------------
-- Haal het actieve vak-nummer op
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.getActiveSlot(uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    return data and data.activeSlot or 1
end

-- ----------------------------------------------------------------
-- Stel het actieve vak in (voor vullen). De Storage-hook leest
-- data.activeSlot live, dus er is geen aparte capaciteiten-cache
-- meer nodig zoals in v1.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.setActiveSlot(uid, slotIndex)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end
    if not data.slots[slotIndex] then return end

    data.activeSlot = slotIndex
    for i, slot in ipairs(data.slots) do
        slot.isActive = (i == slotIndex)
    end

    -- v11: bij het wisselen van actief vak vervalt de "rapporterende"
    -- storage van het vorige vak. Val terug op active.storage totdat
    -- er via het nieuwe vak daadwerkelijk gestort/gehaald wordt.
    data.reportStorage = nil

    RealSiloDebug.print(string.format("[realSilo] Actief vak voor %s: vak %d", uid, slotIndex))
end

-- ----------------------------------------------------------------
-- Geef slot-data terug voor weergave in GUI (zelfde vorm als v1,
-- zodat RealSiloDialog.lua ongewijzigd kan blijven)
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.getSlots(uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return {} end

    local result = {}
    for i, slot in ipairs(data.slots) do
        table.insert(result, {
            index        = i,
            isActive     = slot.isActive,
            isExtension  = slot.isExtension or false,
            xmlLocked    = slot.xmlLocked or false,
            extPlaceable = slot.extPlaceable,
            fillType     = slot.fillType,
            fillLevel    = slot.fillLevel,
            capacity     = slot.capacity,
        })
    end
    return result
end

-- ----------------------------------------------------------------
-- Legen van een specifiek vak: trek dit vak se bijdrage af van de
-- ECHTE storage (via de normale API, dus correct gesynchroniseerd)
-- en wis de boekhouding van dit vak.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.emptySlot(uid, slotIndex)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end

    local slot = data.slots[slotIndex]
    if not slot or slot.fillLevel <= 0 or slot.fillType == 0 then return false end

    local storage  = slot.storage
    local fillType = slot.fillType
    local amount   = slot.fillLevel

    if storage then
        local currentReal = RealSiloStorageHook.getRealFillLevel(storage, fillType)
        storage._realSiloApplying = true
        storage:setFillLevel(math.max(currentReal - amount, 0), fillType)
        storage._realSiloApplying = false
    end

    slot.fillLevel = 0
    slot.fillType  = 0

    RealSiloDebug.print(string.format("[realSilo] Vak %d geleegd (%.0f L verwijderd)", slotIndex, amount))
    return true
end

-- ----------------------------------------------------------------
-- Sla vak-data op in XML (per vak: fillType + fillLevel). De ECHTE
-- storage-data wordt al door Giants zelf opgeslagen — dit is alleen
-- onze eigen verdeling over de vakken.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.saveToXML(xmlFile, key, uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end

    setXMLInt(xmlFile, key .. "#activeSlot", data.activeSlot)
    local savedCount = 0
    for i, slot in ipairs(data.slots) do
        local slotKey = string.format("%s.slot(%d)", key, i - 1)
        setXMLInt(xmlFile,   slotKey .. "#fillType",  slot.fillType or 0)
        setXMLFloat(xmlFile, slotKey .. "#fillLevel", slot.fillLevel or 0)
        setXMLInt(xmlFile,   slotKey .. "#isExt",     slot.isExtension and 1 or 0)
        setXMLInt(xmlFile,   slotKey .. "#cap",       math.floor(slot.capacity or 0))
        savedCount = savedCount + 1
    end
    RealSiloDebug.print(string.format("[realSilo] %d vak(ken) opgeslagen voor %s", savedCount, uid))
end

-- ----------------------------------------------------------------
-- Laad vak-data vanuit XML (na initialize). Herstelt alleen onze
-- eigen verdeling — de werkelijke hoeveelheden in de echte storage
-- zijn al door Giants zelf herladen.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.loadFromXML(xmlFile, key, uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end

    local activeSlot = getXMLInt(xmlFile, key .. "#activeSlot") or 1
    data.activeSlot = activeSlot

    for i, slot in ipairs(data.slots) do
        local slotKey   = string.format("%s.slot(%d)", key, i - 1)
        local fillType  = getXMLInt(xmlFile,   slotKey .. "#fillType")  or 0
        local fillLevel = getXMLFloat(xmlFile, slotKey .. "#fillLevel") or 0
        local cap       = getXMLInt(xmlFile,   slotKey .. "#cap")
        if cap and cap > 0 then slot.capacity = cap end
        slot.fillType  = fillType
        slot.fillLevel = fillLevel
        slot.isActive  = (i == activeSlot)
    end

    RealSiloDebug.print(string.format("[realSilo] Vak-verdeling geladen voor %s (actief: vak %d)", uid, activeSlot))
end

-- ----------------------------------------------------------------
-- setSlotCapacity: pas de capaciteit van één vak aan (boekhouding)
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.setSlotCapacity(uid, slotIndex, newCap)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end
    local slot = data.slots[slotIndex]
    if not slot then return false end

    if slot.isExtension and slot.xmlLocked then
        RealSiloDebug.print("[realSilo] Kan capaciteit van XML-locked extension-vak niet aanpassen")
        return false
    end

    slot.capacity = newCap
    RealSiloDebug.print(string.format("[realSilo] Vak %d capaciteit: %d L", slotIndex, newCap))
    return true
end

-- ----------------------------------------------------------------
-- Verplaats product van het ene vak naar het andere (transfersysteem).
-- Dit is een EXPLICIETE, door de speler gekozen verplaatsing en
-- omzeilt daarom de actief-vak-restrictie uit de Storage-hook door
-- de echte storage(s) rechtstreeks via de normale setFillLevel-API
-- aan te passen, met de "_realSiloApplying"-vlag zodat de hook niet
-- nogmaals ingrijpt. Retourneert hoeveel liter daadwerkelijk is
-- verplaatst (0 als er niets kon worden verplaatst — bron leeg,
-- doel vol, of ongeldige combinatie van producten).
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.moveBetweenSlots(uid, fromIndex, toIndex, amount)
    if not amount or amount <= 0 then return 0 end
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return 0 end

    local fromSlot = data.slots[fromIndex]
    local toSlot    = data.slots[toIndex]
    if not fromSlot or not toSlot then return 0 end
    if fromSlot.fillType == 0 or fromSlot.fillLevel <= 0 then return 0 end
    if toSlot.fillType ~= 0 and toSlot.fillType ~= fromSlot.fillType then return 0 end

    local room  = math.max(toSlot.capacity - toSlot.fillLevel, 0)
    local moved = math.min(amount, fromSlot.fillLevel, room)
    if moved <= 0 then return 0 end

    local fillType = fromSlot.fillType
    local sameStorage = (fromSlot.storage == toSlot.storage)

    fromSlot.fillLevel = fromSlot.fillLevel - moved
    if fromSlot.fillLevel <= 0.0001 then
        fromSlot.fillLevel = 0
        fromSlot.fillType  = 0
    end
    toSlot.fillLevel = toSlot.fillLevel + moved
    if toSlot.fillType == 0 then toSlot.fillType = fillType end

    if sameStorage then
        -- Beide vakken zitten in dezelfde echte storage: het TOTAAL
        -- verandert niet, alleen onze verdeling. We roepen hier BEWUST
        -- niets aan op de echte storage — geen setFillLevel (zou
        -- zichzelf opheffen), maar ook GEEN raiseDirtyFlags meer.
        --
        -- Giants' eigen netwerk-sync codeert de te verzenden waarde bij
        -- een dirty-flag kennelijk via storage:getFillLevel() — en die
        -- functie is sinds de per-vak-isolatie GEHOOKT naar een
        -- virtuele waarde (alleen het actieve vak, zie
        -- realSiloStorageHook.lua). Een dirty-flag activeren stuurde
        -- daardoor het verkeerde getal (alleen het actieve vak i.p.v.
        -- het echte totaal) over het netwerk, wat boekhouding en echte
        -- storage op clients uit elkaar liet lopen — precies het
        -- "bronsilo wordt 16000"-symptoom. Onze eigen
        -- RealSiloEvents.broadcastSlotSync (periodiek tijdens transfer
        -- en bij het stoppen) informeert clients al correct over deze
        -- boekhoudkundige verschuiving — een extra dirty-flag is
        -- overbodig én schadelijk.
    else
        -- Twee aparte storages (bv. hoofdsilo + extension): verplaats
        -- daadwerkelijk product via de echte API. We gebruiken hier
        -- bewust het ECHTE (ongehookte) totaal van elke storage, niet
        -- storage:getFillLevel() — die geeft sinds de per-vak-isolatie
        -- alleen het ACTIEVE vak van die storage terug, wat hier tot
        -- een verkeerd basisgetal zou leiden (bv. als vak1 en vak2
        -- dezelfde storage delen maar vak2 actief is, terwijl we hier
        -- vanuit vak1 transfereren).
        if fromSlot.storage then
            local cur = RealSiloStorageHook.getRealFillLevel(fromSlot.storage, fillType)
            fromSlot.storage._realSiloApplying = true
            fromSlot.storage:setFillLevel(math.max(cur - moved, 0), fillType)
            fromSlot.storage._realSiloApplying = false
        end
        if toSlot.storage then
            local cur = RealSiloStorageHook.getRealFillLevel(toSlot.storage, fillType)
            toSlot.storage._realSiloApplying = true
            toSlot.storage:setFillLevel(cur + moved, fillType)
            toSlot.storage._realSiloApplying = false
        end
    end

    return moved
end

-- ----------------------------------------------------------------
-- Na de EERSTE configuratie: lees de werkelijke storage-inhoud uit
-- en verdeel die over de nieuw aangemaakte vakken.
-- De hooks lieten ongeconfigureerde silo's volledig pass-through,
-- dus de werkelijke storage heeft de correcte waarden.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.captureAndDistribute(uid)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end

    -- Verzamel de werkelijke storage-inhoud per fillType
    local storageContent = {}
    for _, slot in ipairs(data.slots) do
        if slot.storage and not slot.isExtension then
            local stor = slot.storage
            -- Lees storage.fillLevels direct uit (ongehookt, want we
            -- zijn nu geconfigureerd en de hooks kijken naar boekhouding)
            if stor.fillLevels then
                for fillType, level in pairs(stor.fillLevels) do
                    if level and level > 0.0001 then
                        storageContent[fillType] = (storageContent[fillType] or 0) + level
                    end
                end
            end
            break -- alle gewone slots delen dezelfde storage
        end
    end

    -- Reset de slot-boekhouding
    for _, slot in ipairs(data.slots) do
        if not slot.isExtension then
            slot.fillType  = 0
            slot.fillLevel = 0
        end
    end

    -- Verdeel de werkelijke inhoud over de vakken (fillType voor fillType)
    for fillType, total in pairs(storageContent) do
        local remaining = total
        for _, slot in ipairs(data.slots) do
            if remaining <= 0.0001 then break end
            if not slot.isExtension and (slot.fillType == 0 or slot.fillType == fillType) then
                local room  = math.max(slot.capacity - slot.fillLevel, 0)
                local added = math.min(remaining, room)
                if added > 0 then
                    slot.fillLevel = slot.fillLevel + added
                    if slot.fillType == 0 then slot.fillType = fillType end
                    remaining = remaining - added
                end
            end
        end
        -- Overflow in laatste vak (beter tijdelijk te vol dan verlies)
        if remaining > 0.0001 then
            for i = #data.slots, 1, -1 do
                local slot = data.slots[i]
                if not slot.isExtension and (slot.fillType == 0 or slot.fillType == fillType) then
                    slot.fillLevel = slot.fillLevel + remaining
                    if slot.fillType == 0 then slot.fillType = fillType end
                    break
                end
            end
        end
        RealSiloDebug.print(
            "[realSilo] Bestaande inhoud verdeeld voor %s: fillType=%d totaal=%.0f L",
            tostring(uid), fillType, total)
    end

    -- Scan ook de extension-slots: die hebben tijdens de pass-through
    -- (ongeconfigureerd) hun echte storage behouden, maar de boekhouding
    -- staat nog op 0. Lees de werkelijke extension-storage uit en sla
    -- het eerste aanwezige product op in de boekhouding van dat slot.
    local seenExtStorage = {}
    for _, slot in ipairs(data.slots) do
        if slot.isExtension and slot.storage and slot.fillLevel <= 0.0001 then
            local stor = slot.storage
            if not seenExtStorage[stor] then
                seenExtStorage[stor] = true
                if stor.fillLevels then
                    for fillType, level in pairs(stor.fillLevels) do
                        if level and level > 0.0001 then
                            slot.fillType  = fillType
                            slot.fillLevel = level
                            RealSiloDebug.print(
                                "[realSilo] Extension-inhoud vastgelegd slot %d: fillType=%d level=%.0f L",
                                slot.index, fillType, level)
                            break  -- één product per extension-slot
                        end
                    end
                end
            end
        end
    end

    RealSiloDebug.print("[realSilo] captureAndDistribute klaar voor %s", tostring(uid))
end

RealSiloDebug.print("[realSilo] RealSiloCompartmentStorage (boekhoud-versie) geladen")
