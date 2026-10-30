-------------------------------------------------------------------
-- ark_flyer 组件副本 (replica)
--
-- 网络变量唯一安装点：net_mode / net_percent / net_height_suspended。
-- 主机端 AddComponent 时同样会创建 replica（ReplicateComponent），
-- 因此组件不重复定义网络变量，直接通过 inst.replica.ark_flyer 读写。
-------------------------------------------------------------------

local MODES = require("ark_flyer_modes")
local FLY_HEIGHT = 0.5
local MOTOR_K = 32

local function IsPredictionEnabled(inst)
    local locomotor = inst.components and inst.components.locomotor
    return locomotor ~= nil and locomotor.is_prediction_enabled == true
end

local function RefreshClientState(inst)
    local replica = inst.replica and inst.replica.ark_flyer
    if replica ~= nil then
        replica:RefreshClientUpdate()
    end
end

local function OnNetStateDirty(inst)
    RefreshClientState(inst)
end

local function OnModeDirty(inst)
    local replica = inst.replica and inst.replica.ark_flyer
    if replica ~= nil then
        local mode, oldmode = replica:GetMode(), replica._lastmode
        replica._lastmode = mode
        RefreshClientState(inst)
        if oldmode ~= mode and inst.sg ~= nil and IsPredictionEnabled(inst) then
            inst:PushEvent("ark_flyer_modechanged", { oldmode = oldmode, mode = mode })
        end
    end
end

local function OnMovementPrediction(inst, enable)
    local replica = inst.replica and inst.replica.ark_flyer
    if replica == nil then
        return
    end

    if enable then
        -- player_common 在推送事件后才创建 locomotor，延后一帧再检查。
        inst:DoTaskInTime(0, RefreshClientState)
    else
        replica:StopClientUpdate()
        replica:RestoreGroundPhysics()
    end
end

local ArkFlyerReplica = Class(function(self, inst)
    self.inst = inst
    self.updating = false
    self.physics_flying = false
    self._lastmode = MODES.GROUND

    -- 0 地面、1 飞行、2 近地悬浮；高度仍由 net_percent 驱动。
    self.net_mode = net_tinybyte(inst.GUID, "ark_flyer_mode", "ark_flyer_mode_dirty")
    self.net_percent = net_float(inst.GUID, "ark_flyer_percent", "ark_flyer_percent_dirty")
    self.net_height_suspended = net_bool(inst.GUID, "ark_flyer_height_suspended", "ark_flyer_height_suspended_dirty")

    if not TheWorld.ismastersim then
        inst:ListenForEvent("ark_flyer_mode_dirty", OnModeDirty)
        inst:ListenForEvent("ark_flyer_percent_dirty", OnNetStateDirty)
        inst:ListenForEvent("ark_flyer_height_suspended_dirty", OnNetStateDirty)
        inst:ListenForEvent("enablemovementprediction", OnMovementPrediction)
    end
end)

function ArkFlyerReplica:GetMode()
    return self.net_mode:value()
end

function ArkFlyerReplica:IsFlying()
    return self:GetMode() == MODES.FLYING
end

function ArkFlyerReplica:IsHovering()
    return self:GetMode() == MODES.HOVERING
end

function ArkFlyerReplica:IsAirborne()
    return self:GetMode() ~= MODES.GROUND
end

function ArkFlyerReplica:GetPercent()
    return self.net_percent:value()
end

function ArkFlyerReplica:IsHeightSuspended()
    return self.net_height_suspended:value()
end

function ArkFlyerReplica:DriveHeight()
    local inst = self.inst
    if not inst.Physics or self:IsHeightSuspended() then
        return
    end

    local vx, _, vz = inst.Physics:GetMotorVel()
    local _, y = inst.Transform:GetWorldPosition()
    inst.Physics:SetMotorVel(vx, (FLY_HEIGHT * self:GetPercent() - y) * MOTOR_K, vz)
end

function ArkFlyerReplica:ApplyFlyingPhysics()
    if self.physics_flying or not self.inst.Physics then
        return
    end

    RemovePhysicsColliders(self.inst)
    self.physics_flying = true
end

function ArkFlyerReplica:RestoreGroundPhysics()
    if not self.physics_flying then
        return
    end

    if not self.inst:HasTag("playerghost") and self.inst.Physics then
        ChangeToCharacterPhysics(self.inst)
    end
    self.physics_flying = false
end

function ArkFlyerReplica:StartClientUpdate()
    if not self.updating then
        self.updating = true
        self.inst:StartUpdatingComponent(self)
    end
end

function ArkFlyerReplica:StopClientUpdate()
    if self.updating then
        self.updating = false
        self.inst:StopUpdatingComponent(self)
    end
end

function ArkFlyerReplica:RefreshClientUpdate()
    if TheWorld.ismastersim then
        return
    end

    if IsPredictionEnabled(self.inst) and self:IsAirborne() then
        self:ApplyFlyingPhysics()
        self:StartClientUpdate()
        self:DriveHeight()
    else
        self:StopClientUpdate()
        self:RestoreGroundPhysics()
    end
end

function ArkFlyerReplica:OnUpdate()
    if not IsPredictionEnabled(self.inst) or not self:IsAirborne() then
        self:StopClientUpdate()
        self:RestoreGroundPhysics()
        return
    end

    self:DriveHeight()
end

function ArkFlyerReplica:OnRemoveFromEntity()
    if not TheWorld.ismastersim then
        self.inst:RemoveEventCallback("ark_flyer_mode_dirty", OnModeDirty)
        self.inst:RemoveEventCallback("ark_flyer_percent_dirty", OnNetStateDirty)
        self.inst:RemoveEventCallback("ark_flyer_height_suspended_dirty", OnNetStateDirty)
        self.inst:RemoveEventCallback("enablemovementprediction", OnMovementPrediction)
    end

    self:StopClientUpdate()
    self:RestoreGroundPhysics()
end

return ArkFlyerReplica
