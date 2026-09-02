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
        if slot.name ~= nil and slot.name ~= "" then
            setXMLString(xmlFile, slotKey .. "#name", slot.name)
        end
        if slot.moisture ~= nil then setXMLFloat(xmlFile, slotKey .. "#moisture", slot.moisture) end
        if slot.quality  ~= nil then setXMLFloat(xmlFile, slotKey .. "#quality",  slot.quality)  end
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
        slot.name      = getXMLString(xmlFile, slotKey .. "#name") or slot.name or ""
        slot.fillType  = fillType
        slot.fillLevel = fillLevel
        slot.isActive  = (i == activeSlot)
        -- Eigen per-vak vocht/kwaliteit (alleen aanwezig als dit vak
        -- ooit via een droogtransfer is aangeraakt; anders blijft dit
        -- nil en valt de UI terug op de gedeelde MoistureSystem-waarde)
        slot.moisture  = getXMLFloat(xmlFile, slotKey .. "#moisture")
        slot.quality   = getXMLFloat(xmlFile, slotKey .. "#quality")
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

    -- v18 -- BUGFIX: "vak krijgt de waarde van het andere vak" bij het
    -- samenvoegen van twee gevulde vakken. Oorzaak: sinds vakken elk
    -- een EIGEN record in MoistureSystem's droogsysteem kunnen hebben
    -- (ms.objectInfo["<uid>#vak<N>"], zie realSiloDryerCompat.lua) is
    -- DAT record leidend zodra het bestaat (getEffectiveMoistureInfo
    -- checkt het altijd eerst) -- maar de blend hieronder werkte tot
    -- nu toe rechtstreeks op fromSlot.moisture/toSlot.moisture, zonder
    -- die eerst te verversen. Resultaat: de blend rekende soms met een
    -- VERSTE waarde, en zodra de UI daarna opnieuw tekende won het
    -- (ongewijzigde) per-vak record van MoistureSystem alsnog van de
    -- zojuist berekende blend -- het leek dan of het doelvak gewoon de
    -- waarde van het andere vak overnam.
    --
    -- Fix: eerst BEIDE vakken verversen via getEffectiveMoistureInfo
    -- (die het per-vak record checkt als dat bestaat), dan pas blenden,
    -- en het resultaat meteen terugschrijven naar het doelvak se eigen
    -- per-vak record zodat een latere weergave niet opnieuw de oude
    -- (voor-de-merge) waarde laat "winnen".
    local function ownerPlaceableFor(slot)
        if slot.isExtension then return slot.extPlaceable end
        return data.placeable
    end
    if RealSiloCompartmentStorage.getEffectiveMoistureInfo then
        pcall(RealSiloCompartmentStorage.getEffectiveMoistureInfo, ownerPlaceableFor(fromSlot), fromSlot, uid, fromIndex)
        pcall(RealSiloCompartmentStorage.getEffectiveMoistureInfo, ownerPlaceableFor(toSlot), toSlot, uid, toIndex)
    end

    -- Vocht/kwaliteit meenemen naar het doelvak — ALLEEN relevant voor
    -- vakken die al een eigen waarde hebben. Heeft het bronvak geen
    -- eigen waarde (slot.moisture == nil, het normale geval), dan
    -- gebeurt hier niets: beide vakken blijven op de gedeelde
    -- MoistureSystem-waarde vertrouwen, exact het bestaande gedrag.
    -- Komt product met een eigen vochtwaarde terecht in een vak dat al
    -- iets bevat, dan wordt de nieuwe waarde een volume-gewogen
    -- gemiddelde van oud + nieuw (zelfde principe als MoistureSystem's
    -- eigen transferObjectInfo voor voertuig-transfers) — dit is de
    -- "grade A mengt met grade A, vochtwaarden mengen" regel.
    if fromSlot.moisture ~= nil then
        local toFillBefore     = toSlot.fillLevel
        local toMoistureBefore = toSlot.moisture or fromSlot.moisture
        local toQualityBefore  = toSlot.quality  or fromSlot.quality
        local newTotal = toFillBefore + moved
        if newTotal > 0.0001 then
            toSlot.moisture = ((toFillBefore * toMoistureBefore) + (moved * fromSlot.moisture)) / newTotal
            toSlot.quality  = ((toFillBefore * (toQualityBefore or 0)) + (moved * (fromSlot.quality or 0))) / newTotal

            -- Meteen terugschrijven naar het doelvak se eigen per-vak
            -- MoistureSystem-record (als dat systeem actief is), zodat
            -- de zojuist berekende blend niet meteen weer overschreven
            -- wordt door het oude record zodra iets de UI ververst.
            local ms = g_currentMission and g_currentMission.MoistureSystem
            if ms ~= nil and ms.objectInfo ~= nil and RealSiloDryerCompat ~= nil and RealSiloDryerCompat.buildVirtualId ~= nil then
                local fillTypeName = g_fillTypeManager and g_fillTypeManager:getFillTypeNameByIndex(fillType)
                if fillTypeName ~= nil then
                    local virtualId = RealSiloDryerCompat.buildVirtualId(uid, toIndex)
                    ms.objectInfo[virtualId] = ms.objectInfo[virtualId] or {}
                    ms.objectInfo[virtualId][fillTypeName] = { moisture = toSlot.moisture, quality = toSlot.quality }
                end
            end
        end
    end

    fromSlot.fillLevel = fromSlot.fillLevel - moved
    if fromSlot.fillLevel <= 0.0001 then
        fromSlot.fillLevel = 0
        fromSlot.fillType  = 0
        fromSlot.moisture  = nil
        fromSlot.quality   = nil
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

-- ----------------------------------------------------------------
-- Seed de per-vak vocht/kwaliteit-boekhouding vanuit MoistureSystem's
-- gedeelde waarde (silo+fillType), als dit vak nog geen eigen waarde
-- had. Aangeroepen bij het STARTEN van een droogtransfer: vanaf dat
-- moment houdt het bronvak zijn EIGEN, onafhankelijke vochtcijfer bij
-- (nodig omdat MoistureSystem zelf geen vakken kent, alleen silo's).
-- Geen effect als MoistureSystem niet actief is of er geen data is.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.seedMoistureFromMoistureSystem(uid, slotIndex, placeable)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    local slot = data and data.slots[slotIndex]
    if not slot or slot.moisture ~= nil then return false end
    if not slot.fillType or slot.fillType == 0 then return false end
    if not placeable or not placeable.uniqueId then return false end

    local ms = g_currentMission and g_currentMission.MoistureSystem
    if not ms then return false end

    local ok, info = pcall(function() return ms:getObjectInfo(placeable.uniqueId, slot.fillType) end)
    if not ok or info == nil or info.moisture == nil then return false end

    slot.moisture = info.moisture
    slot.quality  = info.quality
    return true
end

-- ----------------------------------------------------------------
-- Geef de vocht/kwaliteit-info terug die de UI voor dit vak moet
-- tonen: de eigen per-vak waarde als die er is (na een
-- droogtransfer), anders de gedeelde MoistureSystem-waarde voor deze
-- silo+fillType (huidig gedrag, ongewijzigd voor alle "normale"
-- vakken die nooit via een droogtransfer zijn aangeraakt).
-- Retourneert { moisture=, quality= } of nil.
-- ----------------------------------------------------------------
function RealSiloCompartmentStorage.getEffectiveMoistureInfo(placeable, slot, uid, slotIndex)
    if slot == nil or slot.fillType == nil or slot.fillType == 0 then return nil end

    -- v16 -- BUGFIX: nu drogen per vak via MoistureSystem's Grain
    -- Drying-menu loopt (zie realSiloDryerCompat.lua), heeft een vak
    -- dat daar gezien is een EIGEN, apart record in ms.objectInfo
    -- staan (sleutel "<uid>#vak<N>") dat door het drogen bijgewerkt
    -- wordt. Dat record is dan ALTIJD leidend -- ook als dit vak al
    -- eerder een gepinde slot.moisture had -- anders blijft de R-menu/
    -- infobox-weergave hangen op de waarde van vóór het drogen begon.
    if uid ~= nil and slotIndex ~= nil and RealSiloDryerCompat ~= nil and RealSiloDryerCompat.buildVirtualId ~= nil then
        local ms = g_currentMission and g_currentMission.MoistureSystem
        if ms ~= nil and ms.objectInfo ~= nil then
            local fillTypeName = g_fillTypeManager and g_fillTypeManager:getFillTypeNameByIndex(slot.fillType)
            if fillTypeName ~= nil then
                local virtualId = RealSiloDryerCompat.buildVirtualId(uid, slotIndex)
                local virtualEntry = ms.objectInfo[virtualId]
                local vInfo = virtualEntry and virtualEntry[fillTypeName]
                if vInfo ~= nil and vInfo.moisture ~= nil then
                    slot.moisture = vInfo.moisture
                    slot.quality  = vInfo.quality
                    return { moisture = slot.moisture, quality = slot.quality }
                end
            end
        end
    end

    if slot.moisture ~= nil then
        return { moisture = slot.moisture, quality = slot.quality }
    end
    local ms = g_currentMission and g_currentMission.MoistureSystem
    if not ms or not placeable or not placeable.uniqueId then return nil end
    local ok, info = pcall(function() return ms:getObjectInfo(placeable.uniqueId, slot.fillType) end)
    if ok and info ~= nil and info.moisture ~= nil then
        -- v11 -- BUGFIX: "silo 1 nam de waarde van silo 2 over". Reden:
        -- MoistureSystem kent GEEN compartimenten -- het houdt maar één
        -- gedeelde waarde bij per (silo-uid, gewas). Een vak dat nog
        -- nooit via een droogtransfer een EIGEN slot.moisture kreeg,
        -- viel hier altijd terug op die ene gedeelde waarde -- dus
        -- wanneer ELDERS in dezelfde silo vers graan van hetzelfde
        -- gewas arriveert (en MoistureSystem zijn gedeelde waarde
        -- bijwerkt), leek het net of DIT vak van waarde veranderde,
        -- terwijl er in dit vak niets gebeurd was.
        --
        -- Fix: de EERSTE keer dat we voor dit vak succesvol een waarde
        -- ophalen, "pinnen" we hem direct op het vak zelf (slot.moisture/
        -- slot.quality). Vanaf dat moment gaat de allereerste regel van
        -- deze functie (slot.moisture ~= nil) hem gebruiken, en is dit
        -- vak niet meer gevoelig voor latere wijzigingen elders in de
        -- silo -- exact hetzelfde principe als bij een droogtransfer,
        -- nu voor ELK vak dat al gevuld is zodra het voor het eerst
        -- bekeken wordt (T-menu openen of bij de silo staan volstaat).
        slot.moisture = info.moisture
        slot.quality  = info.quality
        return { moisture = slot.moisture, quality = slot.quality }
    end

    -- v9 -- DIAG: getObjectInfo gaf niets terug. Om definitief vast te
    -- stellen of dit een verkeerde sleutel is (data bestaat wel, maar
    -- onder een andere naam/uid) of een echt lege boekhouding, dumpen we
    -- hier eenmalig per uid+fillType de RUWE staat: welke fillTypeName
    -- verwachten we, en welke keys staan er daadwerkelijk in
    -- ms.objectInfo[uid] (als dat object al bestaat)?
    if RealSiloDebug and RealSiloDebug.enabled then
        local expectedName = g_fillTypeManager and g_fillTypeManager.getFillTypeNameByIndex
            and g_fillTypeManager:getFillTypeNameByIndex(slot.fillType)
        local rawData = ms.objectInfo and ms.objectInfo[placeable.uniqueId]
        local keys = {}
        if rawData ~= nil then
            for k, _ in pairs(rawData) do table.insert(keys, tostring(k)) end
        end
        RealSiloDebug.print(string.format(
            "[realSilo][DIAG] getEffectiveMoistureInfo RAW: uid=%s slot.fillType=%s verwachteNaam=%s objectInfo[uid]=%s keys=[%s]",
            tostring(placeable.uniqueId), tostring(slot.fillType), tostring(expectedName),
            tostring(rawData ~= nil), table.concat(keys, ",")))
    end

    if ok then return info end
    return nil
end

RealSiloDebug.print("[realSilo] RealSiloCompartmentStorage (boekhoud-versie) geladen")
