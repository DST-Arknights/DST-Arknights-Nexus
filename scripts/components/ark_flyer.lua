-------------------------------------------------------------------
-- ark_flyer 飞行组件
--
-- 参考伊蕾娜模组 (elenaflyer) 的实现思路：
--   - 用物理马达速度 SetMotorVel 控制垂直高度，而非直接改 y 坐标
--   - 目标高度 = FLY_HEIGHT * percent，percent 为 0~1 的 net_float
--   - 每帧把垂直马达速度设为 (目标高度 - 当前y) * MOTOR_K，平滑趋近
--
-- 网络变量装在 replica（inst.replica.ark_flyer）上，本组件不重复定义，
-- 写入时通过 inst.replica.ark_flyer.net_xxx:set() 完成同步。
-------------------------------------------------------------------

local MODES = require("ark_flyer_modes")
local FLY_HEIGHT = 0.5       -- 最高飞行高度
local FLY_SPEED   = 10     -- 飞行移动速度
local RISE_RATE   = 1.4    -- 起飞快照每秒 percent 增量
local FALL_RATE   = 2.0    -- 降落每秒 percent 减量
local MOTOR_K     = 32     -- 垂直马达比例系数

local function GetReplica(inst)
    return inst.replica and inst.replica.ark_flyer
end

------------------------------------------------------------------------

local function ApplyFlyingPhysics(inst)
    if inst.Physics then
        RemovePhysicsColliders(inst)
    end
    local locomotor = inst.components.locomotor
    if locomotor then
        locomotor:SetSlowMultiplier(.6)
        locomotor.pathcaps = { player = true, ignorecreep = true, allowocean = true }
        locomotor.fasteronroad = false
        locomotor:SetTriggersCreep(false)
        locomotor:SetAllowPlatformHopping(false)
    end
end

local function RestoreGroundPhysics(inst)
    if not inst:HasTag("playerghost") and inst.Physics then
        ChangeToCharacterPhysics(inst)
    end
    local locomotor = inst.components.locomotor
    if locomotor then
        locomotor:SetSlowMultiplier(1)
        locomotor.pathcaps = { player = true, ignorecreep = true }
        locomotor.fasteronroad = true
        locomotor:SetTriggersCreep(true)
        locomotor:SetAllowPlatformHopping(true)
    end
end

local function RestoreFlyingColliders(inst)
    local flyer = inst.components.ark_flyer
    if flyer ~= nil and flyer:IsAirborne() and flyer._target > 0
        and not inst:HasTag("playerghost")
        and not (inst.components.health and inst.components.health:IsDead()) then
        RemovePhysicsColliders(inst)
    end
end

local function OnNewState(inst)
    local laststate = inst.sg and inst.sg.laststate
    if laststate ~= nil and laststate.name == "jumpout" then
        -- 虫洞出口会恢复地面碰撞；newstate 在旧状态 onexit 后触发。
        RestoreFlyingColliders(inst)
    end
end

------------------------------------------------------------------------

local ArkFlyer = Class(function(self, inst)
    self.inst    = inst
    self.speed   = FLY_SPEED
    self.height  = 0
    self._target = 0

    inst:ListenForEvent("newstate", OnNewState)
    inst:ListenForEvent("ms_respawnedfromghost", function()
        self:Land()
    end)
end)

------------------------------------------------------------------------
-- 高度 (percent) 读写：网络变量在 replica 上

function ArkFlyer:GetPercent()
    local r = GetReplica(self.inst)
    return r ~= nil and r:GetPercent() or 0
end

function ArkFlyer:SetPercent(v)
    local r = GetReplica(self.inst)
    if r then r.net_percent:set(v) end
end

function ArkFlyer:GetMode()
    local r = GetReplica(self.inst)
    return r ~= nil and r:GetMode() or MODES.GROUND
end

function ArkFlyer:IsFlying()
    return self:GetMode() == MODES.FLYING
end

function ArkFlyer:IsHovering()
    return self:GetMode() == MODES.HOVERING
end

function ArkFlyer:IsAirborne()
    return self:GetMode() ~= MODES.GROUND
end

-- 跳跃等状态临时接管马达时，只暂停高度驱动，保留飞行物理和开关。
-- 这是瞬时动作状态，不写入存档。
function ArkFlyer:SetHeightSuspended(suspended)
    local r = GetReplica(self.inst)
    if r then r.net_height_suspended:set(suspended == true) end
    if not suspended and self:IsAirborne() then
        self:DriveHeight()
    end
end

function ArkFlyer:GetFlyTargetHeight()
    self.height = FLY_HEIGHT * self:GetPercent()
    return self.height
end

-- 把角色物理驱动到目标高度（保留水平分量，避免覆盖移动马达）。
-- 移动会重新设置 SetMotorVel 覆盖垂直分量，故 locomotor.RunForward 后需再次调用。
function ArkFlyer:DriveHeight()
    local inst = self.inst
    local r = GetReplica(inst)
    if not inst.Physics or (r and r:IsHeightSuspended()) then return end
    local vx, vy, vz = inst.Physics:GetMotorVel()
    local _, y = inst.Transform:GetWorldPosition()
    inst.Physics:SetMotorVel(vx, (self:GetFlyTargetHeight() - y) * MOTOR_K, vz)
end

function ArkFlyer:OnUpdate(dt)
    if not self:IsAirborne() then
        self.inst:StopUpdatingComponent(self)
        return
    end

    -- percent 渐变到目标
    local percent = self:GetPercent()
    if self._target > percent then
        self:SetPercent(math.min(percent + RISE_RATE * dt, self._target))
    elseif self._target < percent then
        self:SetPercent(math.max(percent - FALL_RATE * dt, self._target))
    end

    self:DriveHeight()

    -- 降落完成才切回地面模式，保留原有等待 IsFlying() 结束的时序。
    if self._target <= 0 and self:GetFlyTargetHeight() <= 0 then
        self:FinishLand()
    end
end

------------------------------------------------------------------------

function ArkFlyer:SetMode(mode)
    if mode == MODES.GROUND then
        self:Land()
        return
    elseif mode ~= MODES.FLYING and mode ~= MODES.HOVERING then
        return
    end

    local oldmode = self:GetMode()
    if oldmode == mode and self._target > 0 then return end
    self._target = 1

    local inst = self.inst
    inst:AddTag("flying")
    ApplyFlyingPhysics(inst)

    -- drownable 处理
    if inst.components.drownable then
        if TheWorld:HasTag("cave") then
            inst:RemoveComponent("drownable")
        else
            inst.components.drownable.enabled = false
        end
    end

    -- 暂时保留飞行时的地面阴影
    -- if inst.DynamicShadow then
    --     inst.DynamicShadow:Enable(false)
    -- end

    -- mode 是唯一模式来源；两种空中模式共用物理与高度。
    local r = GetReplica(inst)
    if r then r.net_mode:set(mode) end
    inst:StartUpdatingComponent(self)
    if oldmode ~= mode then
        inst:PushEvent("ark_flyer_modechanged", { oldmode = oldmode, mode = mode })
    end
    inst:PushEvent("ark_takeoff")
end

function ArkFlyer:TakeOff()
    self:SetMode(MODES.FLYING)
end

-- 降落：恢复地面物理，高度由 OnUpdate 渐降到 0 后关闭飞行
function ArkFlyer:Land()
    if not self:IsAirborne() or self._target <= 0 then return end
    self._target = 0

    local inst = self.inst
    RestoreGroundPhysics(inst)
    inst:RemoveTag("flying")

    -- drownable 恢复
    if TheWorld:HasTag("cave") then
        if not inst.components.drownable then
            inst:AddComponent("drownable")
        end
    elseif inst.components.drownable then
        inst.components.drownable.enabled = true
    end

    -- 起飞时未关闭地面阴影，这里不需要恢复
    -- if inst.DynamicShadow then
    --     inst.DynamicShadow:Enable(true)
    -- end
end

function ArkFlyer:FinishLand()
    local oldmode = self:GetMode()
    local r = GetReplica(self.inst)
    if r then r.net_mode:set(MODES.GROUND) end
    self.inst:PushEvent("ark_flyer_modechanged", { oldmode = oldmode, mode = MODES.GROUND })
    self.inst:PushEvent("ark_land")
end

function ArkFlyer:Toggle()
    if self:IsAirborne() then self:Land() else self:TakeOff() end
end

------------------------------------------------------------------------
-- 持久化

function ArkFlyer:OnSave()
    return { mode = self:GetMode() }
end

function ArkFlyer:OnLoad(data)
    local mode = data ~= nil and (data.mode or (data.flying and MODES.FLYING)) or nil
    if mode == MODES.FLYING or mode == MODES.HOVERING then
        self:SetMode(mode)
        -- 读档直接满高度
        self._target = 1
        self:SetPercent(1)
        self:DriveHeight()
    end

    -- inventory 读档装备也会起飞，组件加载顺序不固定。
    -- 等本轮读档结束后按当前飞行状态补一次碰撞，不能只依赖 data.flying。
    if self._loadtask ~= nil then
        self._loadtask:Cancel()
    end
    self._loadtask = self.inst:DoTaskInTime(0, function(inst)
        self._loadtask = nil
        RestoreFlyingColliders(inst)
    end)
end

function ArkFlyer:OnRemoveFromEntity()
    if self._loadtask ~= nil then
        self._loadtask:Cancel()
        self._loadtask = nil
    end
    self.inst:RemoveEventCallback("newstate", OnNewState)
end

------------------------------------------------------------------------

return ArkFlyer
