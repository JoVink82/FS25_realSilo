-- ============================================================
-- RealSiloDialog.lua  v10
-- Config-pagina gebruikt een SmoothList (gegarandeerd binnen venster)
-- net als AdjustStorageCapacity. Inputs zitten IN de lijstrijen.
-- ============================================================

RealSiloDialog = {}
local RealSiloDialog_mt = Class(RealSiloDialog, MessageDialog)

-- Rij-types voor de config lijst
local ROW_INFO  = 1  -- informatietekst
local ROW_CALC  = 2  -- berekening (groen)
local ROW_INPUT = 3  -- label + invoerveld

RealSiloDialog.CONTROLS = {
    "pageOverview", "pageConfig", "pageEditSlot", "pageTransfer",
    "compartmentList", "listSlider",
    "configList", "configListSliderBox",
    "activeSlotInfo",
    "transferStatus", "buttonAction", "buttonTransfer", "buttonClose",
}

RealSiloDialog.currentUniqueId  = nil
RealSiloDialog.currentPlaceable = nil

function RealSiloDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or RealSiloDialog_mt)
    self.compartmentEntries = {}
    self.configRows         = {}
    self.currentPage        = 1
    self.selectedIndex      = 1
    self.editingSlotIndex   = nil
    self._goToExtensionsAfterSilo = false
    return self
end

function RealSiloDialog:onGuiSetupFinished()
    RealSiloDialog:superClass().onGuiSetupFinished(self)
    self.compartmentList:setDataSource(self)
    self.configList:setDataSource(self)
end

function RealSiloDialog:onCreate()
    RealSiloDialog:superClass().onCreate(self)
end

-- Live update: ververst de lijst terwijl het menu open is
function RealSiloDialog:update(dt)
    RealSiloDialog:superClass().update(self, dt)
    if self.currentPage == 1 then
        self._refreshTimer = (self._refreshTimer or 0) + dt
        if self._refreshTimer >= 500 then  -- elke 0.5 seconde verversen
            self._refreshTimer = 0
            self:refreshList()
            self.compartmentList:reloadData()
            self:updateTransferStatus()
        end
    end
end

function RealSiloDialog:onOpen()
    RealSiloDialog:superClass().onOpen(self)

    -- Echte, native toets-badges op de footer-knoppen (zelfde methode als
    -- vele andere mods gebruiken: ButtonElement:setInputAction). Settings
    -- krijgt zo een echte X-badge, Transfer een echte T-badge - nooit meer
    -- gedeeld of onzichtbaar.
    if self.buttonAction then
        self.buttonAction:setInputAction(InputAction.MENU_EXTRA_1)
    end
    if self.buttonTransfer and InputAction.REALSILO_TRANSFER then
        self.buttonTransfer:setInputAction(InputAction.REALSILO_TRANSFER)
    end

    -- Registreer T-toets voor Transfer (naast de knop)
    if g_inputBinding and InputAction.REALSILO_TRANSFER then
        local _, eventId = g_inputBinding:registerActionEvent(
            InputAction.REALSILO_TRANSFER, self, self.onClickTransfer,
            false, true, false, true)
        self._transferActionEventId = eventId
        if eventId then
            g_inputBinding:setActionEventText(eventId,
                g_i18n:getText("realSilo_transfer") or "Transfer")
        end
    end

    local uid = RealSiloDialog.currentUniqueId
    if not uid or not realSiloManager.getSilo(uid) then self:close(); return end

    self.selectedIndex = RealSiloCompartmentStorage.getActiveSlot(uid)

    if not realSiloManager.isConfigured(uid) then
        -- Silo is nog niet geconfigureerd. Alleen de admin (of de
        -- host/singleplayer) mag dat doen; een gewone speler kan hier
        -- toch niets mee (geen opslagrecht) en zou anders vastlopen
        -- in het configuratiescherm zonder eruit te kunnen (niet
        -- opslaan, niet annuleren). Toon in dat geval direct een
        -- duidelijke melding en sluit het menu weer.
        local canConfigure = g_currentMission:getIsServer() or g_currentMission.isMasterUser == true
        if not canConfigure then
            g_currentMission:showBlinkingWarning(
                g_i18n:getText("realSilo_notConfiguredYet") or
                "Silo moet geconfigureerd worden door Admin", 4000)
            self:close()
            return
        end
        self:showPage(2)
    else
        self:showPage(1)
        self:refreshList()
        self.compartmentList:reloadData()
        self:updateTransferStatus()
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.compartmentList)
        self:setSoundSuppressed(false)
    end
end

function RealSiloDialog:onClose()
    if self._transferActionEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self._transferActionEventId)
        self._transferActionEventId = nil
    end
    self.compartmentEntries = {}
    self.configRows = {}
    RealSiloDialog:superClass().onClose(self)
end

-- Vang de fysieke X-toets (MENU_EXTRA_1) op en koppel 'm aan dezelfde
-- actie als de knop zelf. MessageDialog routeert systeem-inputActions
-- niet automatisch naar een custom knop-callback (dat doet alleen
-- TabbedMenu voor zijn eigen footer) - vandaar deze expliciete override,
-- dezelfde aanpak die ook andere silo/productie-menu-mods gebruiken.
function RealSiloDialog:inputEvent(action, value, eventUsed)
    if eventUsed then
        return eventUsed
    end
    if value == 0 then
        return eventUsed
    end

    if action == InputAction.MENU_EXTRA_1 then
        if self.buttonAction and self.buttonAction:getIsVisible() then
            self:onClickAction()
        end
        return true
    end

    return RealSiloDialog:superClass().inputEvent(self, action, value, eventUsed)
end

-- ================================================================
-- Helpers
-- ================================================================
function RealSiloDialog:getDisplayName(uid)
    local naam = realSiloManager.getSiloName(uid)
    return (naam and naam ~= "") and naam or "realSilo"
end

function RealSiloDialog:getTotalCapacity(uid)
    local silo = realSiloManager.getSilo(uid)
    if not silo then return 0 end
    if silo.config.totalStorageCapacity and silo.config.totalStorageCapacity > 0 then
        return silo.config.totalStorageCapacity
    end
    return realSiloManager.getStorageCapacity(RealSiloDialog.currentPlaceable) or 400000
end

-- ================================================================
-- Pagina beheer
-- ================================================================
function RealSiloDialog:showPage(pageNum)
    self.currentPage = pageNum
    local uid         = RealSiloDialog.currentUniqueId
    local silo        = uid and realSiloManager.getSilo(uid) or nil
    local displayName = uid and self:getDisplayName(uid) or "realSilo"
    local isConfigured= uid and realSiloManager.isConfigured(uid) or false

    local showList   = (pageNum == 1)
    local showConfig = (pageNum == 2 or pageNum == 3 or pageNum == 4 or pageNum == 5)

    self.compartmentList:setVisible(showList)
    self.listSlider:setVisible(showList)
    if self.activeSlotInfo then self.activeSlotInfo:setVisible(showList) end
    self.configList:setVisible(showConfig)
    if self.configListSliderBox then self.configListSliderBox:setVisible(showConfig) end

    -- Mag deze speler de silo-instellingen beheren? In singleplayer
    -- (of als host/server) altijd; in multiplayer als client alleen
    -- als admin (master user). Transfer blijft voor iedereen
    -- beschikbaar (operationele actie, geen instelling).
    self._canManageSilo = g_currentMission:getIsServer() or g_currentMission.isMasterUser == true

    -- Transfer knop: alleen op pagina 1, verberg op andere pagina's
    if self.buttonTransfer then
        self.buttonTransfer:setVisible(pageNum == 1)
    end

    if pageNum == 1 then
        self.dialogTitleElement:setText(displayName .. " – " .. g_i18n:getText("realSilo_overview"))
        self.buttonAction:setText((g_i18n:getText("realSilo_settings") or "Settings"))
        self.buttonAction:setVisible(self._canManageSilo)
        self:updateActiveSlotInfo()

        if self.buttonTransfer then
            self.buttonTransfer:setVisible(true)
            self.buttonTransfer:setText((g_i18n:getText("realSilo_transfer") or "Transfer"))
        end

    elseif pageNum == 2 then
        self.buttonAction:setVisible(true)
        if not isConfigured then
            self.dialogTitleElement:setText("realSilo – " .. g_i18n:getText("realSilo_firstSetup"))
            self.buttonAction:setText((g_i18n:getText("realSilo_activate") or "Activate"))
        else
            self.dialogTitleElement:setText(displayName .. " – " .. g_i18n:getText("realSilo_settings"))
            if self._goToExtensionsAfterSilo then
                self.buttonAction:setText((g_i18n:getText("realSilo_next") or "Volgende"))
            else
                self.buttonAction:setText((g_i18n:getText("realSilo_save") or "Save"))
            end
        end
        self:buildConfigRows(uid, silo)
        self.configList:reloadData()
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.configList)
        self:setSoundSuppressed(false)

    elseif pageNum == 4 then
        self.dialogTitleElement:setText(self:getDisplayName(uid) .. " – " .. g_i18n:getText("realSilo_transferTitle"))
        self.buttonAction:setText((g_i18n:getText("realSilo_transferStart") or "Start transfer"))
        self:buildTransferRows(uid)
        self.configList:reloadData()
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.configList)
        self:setSoundSuppressed(false)

    elseif pageNum == 3 then
        local slotIdx = self.editingSlotIndex or self.selectedIndex
        local slots   = RealSiloCompartmentStorage.getSlots(uid)
        local slot    = slots and slots[slotIdx]
        if not slot then self:showPage(1); return end
        local naam = g_i18n:getText("realSilo_empty")
        if slot.fillType ~= 0 then
            local d = g_fillTypeManager:getFillTypeByIndex(slot.fillType)
            if d then naam = d.title or d.name or "?" end
        end
        self.dialogTitleElement:setText(string.format("%s – %s %d",
            displayName, g_i18n:getText("realSilo_compartment"), slotIdx))
        self.buttonAction:setText((g_i18n:getText("realSilo_save") or "Save"))
        self:buildSlotEditRows(slotIdx, slot, naam)
        self.configList:reloadData()
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.configList)
        self:setSoundSuppressed(false)

    elseif pageNum == 5 then
        self.dialogTitleElement:setText(displayName .. " – " .. (g_i18n:getText("realSilo_extensionConfig") or "Extensions"))
        self.buttonAction:setText((g_i18n:getText("realSilo_save") or "Opslaan"))
        if self.buttonTransfer then self.buttonTransfer:setVisible(false) end
        -- Hint boven de lijst (activeSlotInfo) in plaats van als configRow:
        -- alle configRows worden zo uitsluitend ROW_INPUT (gelijke hoogte 60px),
        -- wat het SmoothList rendering-probleem met een ontbrekende rij oplost.
        if self.activeSlotInfo then
            local hint = g_i18n:getText("realSilo_extensionConfigHint")
                or "Capacity per silo: click the compartment in the overview."
            -- Knip de hint in op 80 tekens zodat hij in de balk past
            if #hint > 78 then hint = hint:sub(1, 75) .. "..." end
            self.activeSlotInfo:setText(hint)
            self.activeSlotInfo:setVisible(true)
        end
        self:buildExtensionRows(uid)
        self.configList:reloadData()
        self:setSoundSuppressed(true)
        FocusManager:setFocus(self.configList)
        self:setSoundSuppressed(false)
    end
end

function RealSiloDialog:updateActiveSlotInfo()
    if not self.activeSlotInfo then return end
    local uid    = RealSiloDialog.currentUniqueId
    local active = uid and RealSiloCompartmentStorage.getActiveSlot(uid) or 1
    self.activeSlotInfo:setText(string.format(
        g_i18n:getText("realSilo_activeSlotInfo"), active))
end

-- ================================================================
-- Config lijst rijen bouwen (pagina 2)
-- ================================================================
function RealSiloDialog:buildConfigRows(uid, silo)
    self.configRows = {}
    local totalCap = self:getTotalCapacity(uid)
    local isConfigured = uid and realSiloManager.isConfigured(uid) or false

    -- Status rij
    local slots = RealSiloCompartmentStorage.getSlots(uid)
    local totalFill = 0
    for _, slot in ipairs(slots or {}) do totalFill = totalFill + slot.fillLevel end
    local statusTxt
    if not isConfigured then
        statusTxt = g_i18n:getText("realSilo_enterNumCompartments")
    elseif totalFill > 0 then
        statusTxt = g_i18n:getText("realSilo_notEmptyWarning")
    else
        statusTxt = g_i18n:getText("realSilo_emptyCanChange")
    end
    table.insert(self.configRows, { type=ROW_INFO, text=statusTxt })

    -- Aantal vakken invoer
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_askNumCompartments"),
        value   = tostring(silo and silo.config.numCompartments or 4),
        maxChar = 2,
        key     = "numComps",
        digits  = true,
    })

    -- Naam invoer
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_siloName"),
        value   = realSiloManager.getSiloName(uid) or "",
        maxChar = 24,
        key     = "siloName",
        digits  = false,
    })

    -- Transfer snelheid
    local transferRate = (silo and silo.config.transferRate) or 1000
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_transferRate"),
        value   = tostring(math.floor(transferRate)),
        maxChar = 6,
        key     = "transferRate",
        digits  = true,
    })

    -- Zoekbereik voor extensions (meters)
    local extRange = (silo and silo.config.extensionRange) or 50
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_extensionRange"),
        value   = tostring(math.floor(extRange)),
        maxChar = 3,
        key     = "extensionRange",
        digits  = true,
    })

    -- Berekening rij
    table.insert(self.configRows, { type=ROW_CALC,
        numComps = silo and silo.config.numCompartments or 4,
        totalCap = totalCap,
        extCap   = self:getExtCap(uid),
    })
end

function RealSiloDialog:getExtCap(uid)
    local extCap = 0
    if uid then
        for _, slot in ipairs(RealSiloCompartmentStorage.getSlots(uid)) do
            if slot.isExtension then extCap = extCap + slot.capacity end
        end
    end
    return extCap
end

-- ================================================================
-- Slot-edit lijst rijen bouwen (pagina 3)
-- ================================================================
function RealSiloDialog:buildSlotEditRows(slotIdx, slot, naam)
    self.configRows = {}
    self._editSlotFilled = (slot.fillLevel > 0)

    -- Info rij: inhoud + capaciteit
    local infoTxt = string.format(g_i18n:getText("realSilo_editSlotFill"),
        g_i18n:formatVolume(slot.fillLevel, 0),
        g_i18n:formatVolume(slot.capacity, 0))
    table.insert(self.configRows, { type=ROW_INFO,
        text = string.format("%s %d: %s  |  %s",
            g_i18n:getText("realSilo_compartment"), slotIdx, naam, infoTxt)
    })

    -- Naam-invoerveld: altijd bewerkbaar (ook als het vak gevuld is).
    -- Leeg = standaardnaam (Silo N).
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_slotNameLabel") or "Naam",
        value   = slot.name or "",
        maxChar = 24,
        key     = "slotName",
        digits  = false,
    })

    if slot.fillLevel > 0 then
        -- Vak is niet leeg: toon waarschuwing, geen capaciteit-invoer
        table.insert(self.configRows, { type=ROW_INFO,
            text = g_i18n:getText("realSilo_slotNotEmpty")
        })
    else
        -- Vak is leeg: toon capaciteit invoer
        -- Gebruik de echte capaciteit (customCap heeft voorrang)
        local cap = slot.capacity or 0
        table.insert(self.configRows, { type=ROW_INPUT,
            label   = g_i18n:getText("realSilo_slotCapacity"),
            value   = string.format("%d", math.floor(cap)),
            maxChar = 8,
            key     = "slotCap",
            digits  = true,
        })
    end
end

-- ================================================================
-- Transfer rijen bouwen (pagina 4)
-- ================================================================
function RealSiloDialog:buildTransferRows(uid)
    self.configRows = {}
    local silo = realSiloManager.getSilo(uid)
    local transfer = realSiloManager.getTransfer(uid)
    local slots = RealSiloCompartmentStorage.getSlots(uid)

    -- Status rij
    if transfer then
        table.insert(self.configRows, { type=ROW_INFO,
            text = string.format(g_i18n:getText("realSilo_transferActive"),
                transfer.fromSlot, transfer.toSlot,
                g_i18n:formatVolume(transfer.rate, 0))
        })
    else
        table.insert(self.configRows, { type=ROW_INFO,
            text = g_i18n:getText("realSilo_transferHint")
        })
    end

    -- Van vak
    local fromOptions = ""
    for _, slot in ipairs(slots) do
        if slot.fillLevel > 0 then
            local naam = g_i18n:getText("realSilo_empty")
            if slot.fillType ~= 0 then
                local d = g_fillTypeManager:getFillTypeByIndex(slot.fillType)
                if d then naam = d.title or d.name or "?" end
            end
            fromOptions = fromOptions .. string.format("%d(%s) ", slot.index, naam)
        end
    end
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_transferFrom"),
        value   = tostring(transfer and transfer.fromSlot or self.selectedIndex),
        maxChar = 2,
        key     = "transferFrom",
        digits  = true,
    })

    -- Naar vak
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_transferTo"),
        value   = tostring(transfer and transfer.toSlot or 1),
        maxChar = 2,
        key     = "transferTo",
        digits  = true,
    })

    -- Snelheid (L/min)
    local rate = (silo and silo.config.transferRate) or 1000
    table.insert(self.configRows, { type=ROW_INPUT,
        label   = g_i18n:getText("realSilo_transferRate"),
        value   = tostring(transfer and transfer.rate or rate),
        maxChar = 6,
        key     = "transferRate",
        digits  = true,
    })
end

-- ================================================================
-- SmoothList data source voor config + compartiment lijst
-- ================================================================
function RealSiloDialog:getNumberOfItemsInSection(list, section)
    if list == self.compartmentList then
        return #self.compartmentEntries
    elseif list == self.configList then
        return #self.configRows
    end
    return 0
end

-- Verplicht voor SmoothList — altijd hetzelfde celtype zodat de
-- cel-pool nooit corrumpeert door gemengde typen.
function RealSiloDialog:getCellTypeForItemInSection(list, section, index)
    if list == self.compartmentList then
        return "compartmentRowTemplate"
    end
    return "configRowInput"
end

function RealSiloDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.compartmentList then
        self:populateCompartmentCell(index, cell)
    elseif list == self.configList then
        self:populateConfigCell(index, cell)
    end
end

function RealSiloDialog:populateCompartmentCell(index, cell)
    local e = self.compartmentEntries[index]
    if not e then return end
    local iconEl = cell:getAttribute("fillTypeIcon")
    local nameEl = cell:getAttribute("compartmentText")
    local fillEl = cell:getAttribute("fillLevelText")
    local markEl = cell:getAttribute("activeMarker")
    local extEl  = cell:getAttribute("extTag")
    if iconEl then
        if e.iconFile then iconEl:setImageFilename(e.iconFile); iconEl:setVisible(true)
        else iconEl:setVisible(false) end
    end
    if nameEl then nameEl:setText(string.format("%s %d: %s",
        g_i18n:getText("realSilo_compartment"), e.index, e.name)) end
    if fillEl then fillEl:setText(string.format("%s / %s",
        g_i18n:formatVolume(e.fillLevel, 0),
        g_i18n:formatVolume(e.capacity, 0))) end
    if markEl then markEl:setText(e.isActive and ">" or "") end
    if extEl  then extEl:setText(e.isExtension and g_i18n:getText("realSilo_extTag") or "") end
end

function RealSiloDialog:populateConfigCell(index, cell)
    local row = self.configRows[index]
    if not row then return end

    -- Nu alle cellen configRowInput zijn, halen we alleen rowLabel en rowInput op.
    -- Er zijn geen infoText of calcText elementen meer in de cel.
    local labelEl = cell:getAttribute("rowLabel")
    local inputEl = cell:getAttribute("rowInput")

    -- Begin met alles verbergen
    if labelEl then labelEl:setVisible(false) end
    if inputEl then inputEl:setVisible(false) end

    if row.type == ROW_INFO then
        -- Info-tekst in het label-veld, zonder invoerveld
        if labelEl then
            labelEl:setText(row.text or "")
            labelEl:setVisible(true)
        end

    elseif row.type == ROW_CALC then
        -- Berekend resultaat in het label-veld
        if labelEl then
            local numStr = self:getConfigValue("numComps") or tostring(row.numComps)
            local n = tonumber(numStr)
            local tekst = ""
            if n and n >= 1 and n <= 32 and row.totalCap > 0 then
                local capPerComp = math.floor(row.totalCap / n)
                tekst = string.format(g_i18n:getText("realSilo_calcResult"),
                    n, g_i18n:formatVolume(capPerComp, 0), g_i18n:formatVolume(row.totalCap, 0))
                if row.extCap and row.extCap > 0 then
                    tekst = tekst .. string.format("  +%s [EXT]", g_i18n:formatVolume(row.extCap, 0))
                end
            end
            labelEl:setText(tekst)
            labelEl:setVisible(true)
        end

    elseif row.type == ROW_INPUT then
        if labelEl and inputEl then
            labelEl:setText(row.label or "")
            labelEl:setVisible(true)
            -- maxCharacters EERST, dan setText (voorkomt afkappen bij recycling)
            inputEl.maxCharacters = row.maxChar or 32
            inputEl:setText(row.value or "")
            inputEl:setVisible(true)
            row._inputElement = inputEl
        end
    end
end
-- Lees huidige waarde van een config-veld
-- Gebruik de cel-referentie als beschikbaar, anders de opgeslagen waarde
function RealSiloDialog:getConfigValue(key)
    for _, row in ipairs(self.configRows) do
        if row.type == ROW_INPUT and row.key == key then
            -- Probeer eerst via de live cel
            if row._inputElement then
                local txt = row._inputElement:getText()
                if txt then
                    row.value = txt  -- bewaar voor als cel ongeldig wordt
                    return txt
                end
            end
            -- Fallback: opgeslagen waarde
            return row.value
        end
    end
    return nil
end

-- Sla huidige invoerwaarden op (voor na reloadData)
function RealSiloDialog:saveConfigValues()
    for _, row in ipairs(self.configRows) do
        if row.type == ROW_INPUT and row._inputElement then
            row.value = row._inputElement:getText() or row.value
        end
    end
end

-- Unicode filter voor config inputs
function RealSiloDialog:onRowInputUnicode(unicode)
    -- Zoek de huidige actieve rij
    for _, row in ipairs(self.configRows) do
        if row.type == ROW_INPUT and row._inputElement
           and row._inputElement:getIsFocused() then
            if row.digits then
                return unicode >= 48 and unicode <= 57
            else
                return true
            end
        end
    end
    return true
end

-- ================================================================
-- Compartiment lijst
-- ================================================================
function RealSiloDialog:refreshList()
    self.compartmentEntries = {}
    local uid = RealSiloDialog.currentUniqueId
    if not uid then return end
    local slots = RealSiloCompartmentStorage.getSlots(uid)
    for _, slot in ipairs(slots) do
        local naam = g_i18n:getText("realSilo_empty")
        local iconFile = nil
        if slot.fillType ~= 0 then
            local d = g_fillTypeManager:getFillTypeByIndex(slot.fillType)
            if d then naam = d.title or d.name or "?"; iconFile = d.hudOverlayFilename end
        end
        table.insert(self.compartmentEntries, {
            index       = slot.index,
            name        = naam,
            iconFile    = iconFile,
            fillType    = slot.fillType,
            fillLevel   = slot.fillLevel,
            capacity    = slot.capacity,
            isActive    = slot.isActive,
            isExtension = slot.isExtension or false,
            xmlLocked   = slot.xmlLocked or false,
        })
    end
end

function RealSiloDialog:onListClick(list, section, index)
    if list ~= self.compartmentList then return end
    if not index or index < 1 or index > #self.compartmentEntries then return end
    if index == self.selectedIndex then return end
    local now = getTimeSec and getTimeSec() or 0
    if self._lastClickTime and (now - self._lastClickTime) < 0.3 then return end
    self._lastClickTime = now
    local uid = RealSiloDialog.currentUniqueId
    if not uid then return end
    self.selectedIndex = index
    RealSiloEvents.sendActiveSlot(uid, index)
    self:refreshList()
    self.compartmentList:reloadData()
    self:updateActiveSlotInfo()
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
        string.format(g_i18n:getText("realSilo_slotActivated"), index))
end

function RealSiloDialog:onListDoubleClick(list, section, index)
    if list ~= self.compartmentList then return end
    if not index or index < 1 or index > #self.compartmentEntries then return end
    local uid  = RealSiloDialog.currentUniqueId
    local silo = uid and realSiloManager.getSilo(uid) or nil
    if not silo then return end

    local e = self.compartmentEntries[index]

    if e and e.isExtension then
        if e.xmlLocked then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
                g_i18n:getText("realSilo_lockedByMod"))
            return
        end
        -- Extension-vakken zijn altijd bewerkbaar (onafhankelijk van silo.config.locked)
        self.editingSlotIndex = index
        self:showPage(3)
        return
    end

    if silo.config.locked then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_lockedByMod"))
        return
    end

    self.editingSlotIndex = index
    self:showPage(3)
end

-- ================================================================
-- Knoppen
-- ================================================================
-- Controleer of er minstens één extension-vak is dat NIET via XML
-- is vastgelegd (dus door de speler instelbaar is).
function RealSiloDialog:hasEditableExtensions(uid)
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end
    for _, slot in ipairs(data.slots or {}) do
        if slot.isExtension and not slot.xmlLocked then
            return true
        end
    end
    return false
end

function RealSiloDialog:onClickAction()
    local uid  = RealSiloDialog.currentUniqueId
    local silo = uid and realSiloManager.getSilo(uid) or nil
    if self.currentPage == 1 then
        local siloLocked     = silo and silo.config.locked
        local hasExtEditable = self:hasEditableExtensions(uid)

        if siloLocked and not hasExtEditable then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("realSilo_lockedByMod"))
            return
        end

        -- Onthoud of we na de silo-instellingen ook nog naar de
        -- extension-instellingen moeten doorgaan.
        self._goToExtensionsAfterSilo = hasExtEditable

        if not siloLocked then
            self:showPage(2)
        else
            -- Silo-instellingen zijn vast; ga direct naar extension-instellingen.
            self._goToExtensionsAfterSilo = false
            self:showPage(5)
        end
    elseif self.currentPage == 2 then
        self:onConfirm()
    elseif self.currentPage == 3 then
        self:onConfirmSlot()
    elseif self.currentPage == 4 then
        self:onConfirmTransfer()
    elseif self.currentPage == 5 then
        self:onConfirmExtensions()
    end
end

function RealSiloDialog:onClickTransfer()
    local uid = RealSiloDialog.currentUniqueId
    if not uid then return end
    -- Als er al een transfer actief is: stop hem
    if realSiloManager.getTransfer(uid) then
        RealSiloEvents.sendTransfer(uid, false)
        self:updateTransferStatus()
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("realSilo_transferStopped"))
        return
    end
    self:showPage(4)
end

function RealSiloDialog:onCancel()
    local uid = RealSiloDialog.currentUniqueId
    local isConfigured = uid and realSiloManager.isConfigured(uid) or false

    self._goToExtensionsAfterSilo = false

    -- v19 -- BUGFIX: ESC/Cancel deed tot nu toe NIETS bij de eerste
    -- (nog niet voltooide) configuratie -- de admin/host kreeg alleen
    -- de melding "eerst configureren" te zien en zat vast in het
    -- scherm. Nu mag annuleren altijd. Bij een nog niet geconfigureerde
    -- silo bestaat er geen pagina 1 om naar terug te gaan (die toont
    -- compartimentdata die nog niet bestaat), dus dan sluiten we het
    -- menu direct -- de silo blijft gewoon ongeconfigureerd (werkt als
    -- normale vanilla silo) tot iemand het menu later weer opent en de
    -- configuratie alsnog afmaakt.
    if not isConfigured then
        self:close()
        return
    end

    if self.currentPage == 2 or self.currentPage == 3 or self.currentPage == 4 or self.currentPage == 5 then
        self:showPage(1)
        self:refreshList()
        self.compartmentList:reloadData()
    else
        self:close()
    end
end

function RealSiloDialog:onlyDigits(unicode)
    return unicode >= 48 and unicode <= 57
end

-- ================================================================
-- Opslaan pagina 2
-- ================================================================
function RealSiloDialog:onConfirm()
    local uid = RealSiloDialog.currentUniqueId
    if not uid then self:close(); return end

    self:saveConfigValues()
    local numCompsStr  = self:getConfigValue("numComps")
    local naam         = self:getConfigValue("siloName") or ""
    local transferStr  = self:getConfigValue("transferRate")
    local extRangeStr  = self:getConfigValue("extensionRange")
    local numComps     = tonumber(numCompsStr)
    local transferRate = math.max(tonumber(transferStr) or 1000, 10)
    -- Zoekbereik extensions: 1 t/m 300 m (buiten dat bereik heeft het
    -- geen zin; 0 zou alle extensions loskoppelen).
    local extRange     = math.floor(math.min(math.max(tonumber(extRangeStr) or 50, 1), 300))

    if not numComps or numComps < 1 or numComps > 32 then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_invalidNumber"))
        return
    end
    numComps = math.floor(numComps)

    local totalCap   = self:getTotalCapacity(uid)
    local cap        = math.max(math.floor(totalCap / numComps), 1000)
    local isConfigured = realSiloManager.isConfigured(uid)

    RealSiloDebug.print(
        "[realSilo][DIAG] onConfirm: uid=%s numComps=%d totalCap=%d cap=%d isConfigured=%s naam=%s",
        tostring(uid), numComps, totalCap, cap, tostring(isConfigured), tostring(naam))

    if isConfigured then
        -- Controleer of silo leeg is bij ELKE config-wijziging (ook alleen naam is OK)
        local silo = realSiloManager.getSilo(uid)
        local numChanged = silo and (numComps ~= silo.config.numCompartments)

        if numChanged then
            -- Aantal vakken wijzigen: silo moet leeg zijn
            local slots = RealSiloCompartmentStorage.getSlots(uid)
            local totalFill = 0
            for _, slot in ipairs(slots) do totalFill = totalFill + slot.fillLevel end
            if totalFill > 0 then
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                    g_i18n:getText("realSilo_mustBeEmpty"))
                return
            end
        end
    end

    local ok, err = RealSiloEvents.sendConfig(uid, numComps, cap, naam, transferRate, extRange)
    RealSiloDebug.print("[realSilo][DIAG] sendConfig resultaat: ok=%s err=%s", tostring(ok), tostring(err))
    if ok then
        local silo = realSiloManager.getSilo(uid)
        local msg = string.format(g_i18n:getText("realSilo_configSaved"),
            silo.config.numCompartments,
            g_i18n:formatVolume(silo.config.capacityPerCompartment, 0))
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, msg)
        RealSiloDebug.print("[realSilo] " .. msg)
        self.selectedIndex = 1
        if self._goToExtensionsAfterSilo then
            self._goToExtensionsAfterSilo = false
            self:showPage(5)
        else
            self:showPage(1)
        end
        self:refreshList()
        self.compartmentList:reloadData()
    else
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_configError") .. " " .. tostring(err))
    end
end

-- ================================================================
-- Transfer starten (pagina 4)
-- ================================================================
function RealSiloDialog:onConfirmTransfer()
    local uid = RealSiloDialog.currentUniqueId
    if not uid then return end

    self:saveConfigValues()
    local fromSlot = tonumber(self:getConfigValue("transferFrom"))
    local toSlot   = tonumber(self:getConfigValue("transferTo"))
    local rate     = tonumber(self:getConfigValue("transferRate"))

    if not fromSlot or fromSlot < 1 then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_transferInvalidSlot"))
        return
    end
    if not toSlot or toSlot < 1 or toSlot == fromSlot then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_transferInvalidDest"))
        return
    end
    if not rate or rate < 1 then rate = 1000 end

    -- v19 -- BUGFIX: een transfer naar een vak met een ANDER gewas werd
    -- tot nu toe gewoon "gestart" (bevestiging in de UI), maar
    -- moveBetweenSlots weigert zo'n verplaatsing stilzwijgend op de
    -- eerste update-tick -- de speler zag dus "transfer aan" terwijl er
    -- feitelijk nooit iets bewoog, zonder duidelijke reden. Nu vooraf
    -- checken en direct een duidelijke foutmelding geven.
    local slotsForCheck = RealSiloCompartmentStorage.getSlots(uid)
    local fromSlotInfo  = slotsForCheck and slotsForCheck[math.floor(fromSlot)]
    local toSlotInfo    = slotsForCheck and slotsForCheck[math.floor(toSlot)]
    if not fromSlotInfo or not fromSlotInfo.fillType or fromSlotInfo.fillType == 0
       or not fromSlotInfo.fillLevel or fromSlotInfo.fillLevel <= 0 then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_transferSourceEmpty") or "Source compartment is empty.")
        return
    end
    if toSlotInfo and toSlotInfo.fillType and toSlotInfo.fillType ~= 0
       and toSlotInfo.fillType ~= fromSlotInfo.fillType then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_transferFillTypeMismatch") or "Destination compartment already contains a different crop.")
        return
    end

    local ok, err = RealSiloEvents.sendTransfer(uid, true, math.floor(fromSlot), math.floor(toSlot), math.floor(rate))
    if ok then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("realSilo_transferStarted"),
                fromSlot, toSlot, g_i18n:formatVolume(rate, 0)))
        self:showPage(1)
        self:refreshList()
        self.compartmentList:reloadData()
        self:updateTransferStatus()
    elseif err == "beingDried" then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("realSilo_transferBlockedDrying") or
            "Cannot transfer while this silo is being dried.")
    else
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            tostring(err))
    end
end

function RealSiloDialog:updateTransferStatus()
    if not self.transferStatus then return end
    local uid = RealSiloDialog.currentUniqueId
    local transfer = uid and realSiloManager.getTransfer(uid) or nil
    if transfer then
        self.transferStatus:setText(string.format(
            g_i18n:getText("realSilo_transferRunning"),
            transfer.fromSlot, transfer.toSlot,
            g_i18n:formatVolume(transfer.rate, 0)))
        self.transferStatus:setVisible(true)
        if self.buttonTransfer then
            self.buttonTransfer:setText((g_i18n:getText("realSilo_transferStop") or "Stop transfer"))
        end
    else
        self.transferStatus:setVisible(false)
        if self.buttonTransfer then
            self.buttonTransfer:setText((g_i18n:getText("realSilo_transfer") or "Transfer"))
        end
    end
end

-- ================================================================
-- Opslaan pagina 3
-- ================================================================
function RealSiloDialog:onConfirmSlot()
    local uid     = RealSiloDialog.currentUniqueId
    local slotIdx = self.editingSlotIndex
    if not uid or not slotIdx then self:showPage(1); return end

    self:saveConfigValues()

    -- Naam altijd opslaan (ook als het vak gevuld is)
    local newName = self:getConfigValue("slotName") or ""
    RealSiloEvents.sendSlotName(uid, slotIdx, newName)

    local slots = RealSiloCompartmentStorage.getSlots(uid)
    local slot  = slots and slots[slotIdx]

    -- Capaciteit alleen aanpassen als het vak leeg is (dan bestaat het veld)
    local capStr = self:getConfigValue("slotCap")
    if capStr ~= nil then
        local cap = tonumber(capStr)
        if not cap or cap < 1000 then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("realSilo_invalidCapacity"))
            return
        end
        cap = math.floor(cap)
        if slot and cap < slot.fillLevel then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                string.format(g_i18n:getText("realSilo_capBelowFill"),
                    g_i18n:formatVolume(slot.fillLevel, 0)))
            return
        end
        RealSiloEvents.sendSlotCapacity(uid, slotIdx, cap)
        local msg = string.format(g_i18n:getText("realSilo_slotCapSaved"),
            slotIdx, g_i18n:formatVolume(cap, 0))
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, msg)
        RealSiloDebug.print("[realSilo] " .. msg)
    end

    self:showPage(1)
    self:refreshList()
    self.compartmentList:reloadData()
end

-- ================================================================
-- Pagina 5: Extension configuratie
--
-- Extension-vakken worden gegroepeerd per extension-placeable (een
-- extension kan meerdere vakken hebben). Per groep:
--   - locked (via XML): alleen read-only info
--   - niet locked: alleen "aantal silo's" instelbaar; de capaciteit
--     per vak wordt op pagina 1 ingesteld door op het vak te klikken
--     (zelfde flow als gewone silo-compartimenten).
-- ================================================================
function RealSiloDialog:buildExtensionRows(uid)
    self.configRows  = {}
    self._extGroups  = {}
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return end

    -- (hint tekst wordt getoond via activeSlotInfo boven de lijst,
    --  niet als configRow — zo zijn alle rijen ROW_INPUT en gelijke hoogte)

    -- Groepeer extension-vakken per extension-placeable
    local groups     = {}
    local groupByExt = {}
    for i, slot in ipairs(data.slots or {}) do
        if slot.isExtension then
            local ext = slot.extPlaceable
            local g = groupByExt[ext]
            if not g then
                g = { extPlaceable = ext, locked = slot.xmlLocked, items = {} }
                groupByExt[ext] = g
                table.insert(groups, g)
            end
            table.insert(g.items, { slot = slot, dataIndex = i })
        end
    end

    local hasLocked   = false
    local hasEditable = false

    for gIdx, g in ipairs(groups) do
        local extName = (g.extPlaceable and g.extPlaceable._realSiloDisplayName)
            or g_i18n:getText("realSilo_defaultExtensionName")

        if g.locked then
            hasLocked = true
            for _, it in ipairs(g.items) do
                local cap = it.slot.capacity or 0
                table.insert(self.configRows, {
                    type = ROW_INFO,
                    text = string.format("[VAST] %s – Silo %d – %s L (vast door mod)",
                        extName, it.dataIndex, g_i18n:formatNumber(math.floor(cap), 0)),
                })
            end
        else
            hasEditable = true

            -- Aantal vakken voor deze extension
            local dataIndices = {}
            for _, it in ipairs(g.items) do table.insert(dataIndices, it.dataIndex) end
            table.insert(self.configRows, {
                type    = ROW_INPUT,
                label   = string.format("%s (silo %s) – %s",
                    extName, table.concat(dataIndices, "/"),
                    g_i18n:getText("realSilo_numCompartmentsLabel") or "aantal silo's"),
                value   = tostring(#g.items),
                maxChar = 1,
                key     = string.format("extNumComps_%d", gIdx),
                digits  = true,
            })
        end

        g.groupIndex = gIdx
    end

    self._extGroups = groups

    -- Voeg lege spacer-rijen toe tot de totale lijsthoogte de viewport
    -- overschrijdt (>410px). De SmoothList rendert in scroll-modus
    -- betrouwbaarder dan wanneer alle content in het viewport past.
    -- 60px per ROW_INPUT rij; 7 rijen = 420px > 410px viewport.
    local minRows = 7
    for i = #self.configRows + 1, minRows do
        table.insert(self.configRows, {
            type    = ROW_INPUT,
            label   = "",
            value   = "",
            maxChar = 0,
            key     = "_spacer" .. i,
            digits  = false,
        })
    end

    if #groups == 0 then
        table.insert(self.configRows, {
            type = ROW_INFO,
            text = "Geen extension-silo's gevonden.",
        })
    elseif hasLocked and not hasEditable then
        table.insert(self.configRows, {
            type = ROW_INFO,
            text = g_i18n:getText("realSilo_extensionAllLocked") or
                   "Alle extension-silo's zijn vastgelegd door de mod.",
        })
    end
end

function RealSiloDialog:onConfirmExtensions()
    local uid = RealSiloDialog.currentUniqueId
    if not uid then self:showPage(1); return end

    self:saveConfigValues()

    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then self:showPage(1); return end

    local changed = false
    local blocked = false

    for gIdx, g in ipairs(self._extGroups or {}) do
        if not g.locked then
            local oldNum = #g.items
            local numStr = self:getConfigValue(string.format("extNumComps_%d", gIdx))
            local newNum = tonumber(numStr)
            newNum = newNum and math.floor(newNum) or oldNum
            newNum = math.max(math.min(newNum, 8), 1)

            if newNum ~= oldNum then
                local ok, err = RealSiloEvents.sendExtensionRelink(uid, g.extPlaceable, newNum)
                if ok then
                    changed = true
                elseif err == "extMustBeEmpty" then
                    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                        g_i18n:getText("realSilo_extMustBeEmpty") or
                        "Leeg de extension eerst om het aantal silo's te wijzigen.")
                    blocked = true
                end
            end
        end
    end

    if changed then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            g_i18n:getText("realSilo_extensionSaved") or "Extension capaciteit opgeslagen.")
    end

    if blocked and not changed then
        -- Blijf op deze pagina zodat de speler de melding ziet en kan corrigeren
        self:buildExtensionRows(uid)
        self.configList:reloadData()
        return
    end

    self._goToExtensionsAfterSilo = false
    self:showPage(1)
    self:refreshList()
    self.compartmentList:reloadData()
end

-- ================================================================
-- Registratie
-- ================================================================
function RealSiloDialog.register(modDirectory)
    g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")
    local dialog = RealSiloDialog.new(g_i18n)
    g_gui:loadGui(modDirectory .. "gui/RealSiloDialog.xml", "RealSiloDialog", dialog)
    RealSiloDialog.INSTANCE = dialog
    RealSiloDebug.print("[realSilo] RealSiloDialog geregistreerd (v10)")
end

function RealSiloDialog.show(uniqueId, placeable)
    if uniqueId == nil then return end
    RealSiloDialog.currentUniqueId  = uniqueId
    RealSiloDialog.currentPlaceable = placeable
    g_gui:showDialog("RealSiloDialog")
end
