require "prefabutil"

local Visuals = require("ark_lambda_visuals")
local assets = {
    Asset("ANIM", "anim/closure_command_native.zip"),
    Asset("ANIM", "anim/ark_lambda_range.zip"),
}
local prefabs = {
    "ark_lambda_background_fx", "ark_lambda_aim_fx", "ark_lambda_cast_fx",
    "ark_lambda_hit_fx",
}

local function TrackFx(inst, fx)
    inst._ownedfx[fx] = true
    fx:ListenForEvent("onremove", function() inst._ownedfx[fx] = nil end)
    return fx
end

local function CleanupFx(inst)
    for fx in pairs(inst._ownedfx) do
        if fx:IsValid() then
            fx:Remove()
        end
    end
    inst._aimfx = {}
    inst._backgroundfx = nil
end

local function OnTargetChanged(inst, target, index)
    local previous = inst._aimfx[index]
    if previous ~= nil and previous:IsValid() then
        previous:Remove()
    end
    inst._aimfx[index] = nil
    if target ~= nil then
        local fx = TrackFx(inst, SpawnPrefab("ark_lambda_aim_fx"))
        fx:SetTarget(target)
        inst._aimfx[index] = fx
    end
end

local function OnAttack(inst, target)
    if inst._lastcasttime ~= GetTime() then
        inst._lastcasttime = GetTime()
        local cast = TrackFx(inst, SpawnPrefab("ark_lambda_cast_fx"))
        cast:SetTarget(inst)
    end
    -- Set the world position before damage can remove the target.
    local hit = TrackFx(inst, SpawnPrefab("ark_lambda_hit_fx"))
    hit:SetTarget(target)
end

local function OnCombatActiveChanged(inst, active)
    if active and inst._backgroundfx == nil then
        inst._backgroundfx = TrackFx(inst, SpawnPrefab("ark_lambda_background_fx"))
        inst._backgroundfx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    elseif not active and inst._backgroundfx ~= nil then
        inst._backgroundfx:Remove()
        inst._backgroundfx = nil
    end
end

local function OnRangeStateChanged(inst, state)
    if inst:IsValid() then
        inst._rangestate:set(state)
    end
end

local function GetStatus(inst)
    local state = inst._rangestate:value()
    if state == 2 then
        return "ATTACKING"
    elseif state == 3 then
        return "NOFUNDS"
    end
end

local function Dismantle(inst)
    if inst._dismantling then
        return
    end
    inst._dismantling = true
    inst.persists = false
    inst.components.ark_lambda_defense:SetEnabled(false)
    CleanupFx(inst)
    Visuals.Cleanup(inst)
    inst.components.workable:SetWorkable(false)
    inst.AnimState:PlayAnimation("Die")
    RemovePhysicsColliders(inst)
    inst:DoTaskInTime(inst.AnimState:GetCurrentAnimationLength() + FRAMES, inst.Remove)
end

local function OnHammered(inst)
    if not inst._dismantling then
        inst.components.lootdropper:DropLoot()
        Dismantle(inst)
    end
end

local function GetWorkMultiplier(inst, worker)
    -- Boss attacks and their projectiles use the same workable path as hammers.
    return worker:HasTag("player") and 1 or 0
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()
    MakeObstaclePhysics(inst, 0.5)

    local config = TUNING.ARK_LAMBDA_COMMAND_CENTER
    inst.AnimState:SetBank("closure_command_native")
    inst.AnimState:SetBuild("closure_command_native")
    inst.AnimState:SetScale(config.BODY_SCALE, config.BODY_SCALE, config.BODY_SCALE)
    inst.AnimState:PlayAnimation("Start")
    inst.AnimState:PushAnimation("Idle", true)
    inst:AddTag("structure")
    inst:AddTag("engineering")
    inst:AddTag("ark_lambda_command_center")

    inst._range = net_float(inst.GUID, "ark_lambda.range")
    inst._rangestate = net_tinybyte(inst.GUID, "ark_lambda.rangestate")
    Visuals.Attach(inst)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst._ownedfx = {}
    inst._aimfx = {}
    inst:ListenForEvent("onremove", CleanupFx)
    inst:ListenForEvent("death", Dismantle)
    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetStatus
    inst:AddComponent("lootdropper")
    inst:AddComponent("combat")
    inst.components.combat:SetDefaultDamage(config.DAMAGE)
    inst.components.combat:SetRange(config.RANGE)
    inst:AddComponent("ark_lambda_defense")
    local defense = inst.components.ark_lambda_defense
    defense:SetRange(config.RANGE)
    defense:SetAttackPeriod(config.ATTACK_PERIOD)
    defense:SetActivationDelay(config.STARTUP_TIME)
    defense:SetTargetWindup(config.AIM_TIME)
    defense:SetSlow(config.SLOW_MULT, config.SLOW_DURATION)
    defense:SetTargetChangedFn(OnTargetChanged)
    defense:SetOnAttackFn(OnAttack)
    defense:SetCombatActiveChangedFn(OnCombatActiveChanged)
    defense:SetRangeStateChangedFn(OnRangeStateChanged)
    inst.SetAttackRange = function(self, radius)
        defense:SetRange(radius)
        self.components.combat:SetRange(defense:GetRange())
        self._range:set(defense:GetRange())
    end
    inst:SetAttackRange(config.RANGE)

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(4)
    inst.components.workable:SetWorkMultiplierFn(GetWorkMultiplier)
    inst.components.workable:SetOnFinishCallback(OnHammered)
    inst:DoTaskInTime(0, function()
        if not inst._dismantling then
            defense:SetEnabled(true)
        end
    end)
    MakeHauntableWork(inst)
    return inst
end

local placer = MakePlacer("ark_lambda_command_center_placer", "closure_command_native", "closure_command_native", "Idle", nil, nil, nil, nil, nil, nil,
    Visuals.CreatePlacementRange)
placer.assets = {
    Asset("ANIM", "anim/closure_command_native.zip"),
    Asset("ANIM", "anim/ark_lambda_range.zip"),
}

return Prefab("ark_lambda_command_center", fn, assets, prefabs), placer
