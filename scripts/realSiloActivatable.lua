-- ============================================================
-- realSiloActivatable.lua  v9
-- run() opent de GUI dialoog en geeft de placeable mee
-- zodat het overzicht de echte storage kan lezen.
-- ============================================================

RealSiloActivatable = {}
local RealSiloActivatable_mt = Class(RealSiloActivatable)

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
        return MathUtil.vector3Length(x - tx, y - ty, z - tz)
    end
    return math.huge
end

function RealSiloActivatable:run()
    local uid = self.placeable.realSiloUniqueId
    if not uid then return end
    RealSiloDialog.show(uid, self.placeable)
end
