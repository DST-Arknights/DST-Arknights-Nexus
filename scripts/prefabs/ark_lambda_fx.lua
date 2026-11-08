local FxPosition = require("ark_lambda_fx_position")

local function ClearTarget(inst)
    if inst._followtask ~= nil then
        inst._followtask:Cancel()
        inst._followtask = nil
    end
    if inst._target ~= nil then
        inst:RemoveEventCallback("death", inst._ontargetgone, inst._target)
        inst:RemoveEventCallback("onremove", inst._ontargetgone, inst._target)
        inst._target = nil
    end
end

local function FollowTarget(inst)
    if inst._target ~= nil and inst._target:IsValid() then
        inst.Transform:SetPosition(FxPosition.GetWorldPosition(inst._target, inst._targetsymbol))
    end
end

local function SetTarget(inst, target)
    ClearTarget(inst)
    inst._target = target
    inst._targetsymbol = FxPosition.GetHitSymbol(target)
    FollowTarget(inst)
    inst:ListenForEvent("death", inst._ontargetgone, target)
    inst:ListenForEvent("onremove", inst._ontargetgone, target)
    inst._followtask = inst:DoPeriodicTask(FRAMES, FollowTarget)
end

-- Each combat effect has its own network AnimState. The server owns animation
-- playback and lifetime, and every viewer receives the same persistent entity.
local function MakeNetworkFx(definition)
    local function OnTargetGone(inst)
        if not inst:IsValid() then
            return
        end
        -- Freeze at the last world position when the body is removed or dies.
        ClearTarget(inst)
        if definition.loop then
            inst:Remove()
        end
    end

    local function fn()
        local inst = CreateEntity()
        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        if definition.sound ~= nil then
            inst.entity:AddSoundEmitter()
        end
        if definition.light_radius ~= nil then
            inst.entity:AddLight()
            inst.Light:SetRadius(definition.light_radius)
            inst.Light:SetIntensity(0.5)
            inst.Light:SetFalloff(0.7)
            inst.Light:SetColour(1, 0.65, 0.8)
        end
        inst.entity:AddNetwork()
        inst.entity:SetCanSleep(false)
        inst:AddTag("FX")
        inst:AddTag("DECOR")
        inst:AddTag("NOCLICK")

        inst.AnimState:SetBank(definition.bank)
        inst.AnimState:SetBuild(definition.bank)
        local scale = TUNING.ARK_LAMBDA_COMMAND_CENTER.FX_SCALE
        inst.AnimState:SetScale(scale, scale, scale)
        inst.AnimState:SetFinalOffset(definition.offset)
        if definition.light then
            inst.AnimState:SetLightOverride(1)
        end
        inst.AnimState:PlayAnimation(definition.anim, definition.loop == true)

        inst.entity:SetPristine()
        if not TheWorld.ismastersim then
            return inst
        end

        inst.persists = false
        inst.SetTarget = SetTarget
        inst._ontargetgone = function() OnTargetGone(inst) end
        inst:ListenForEvent("onremove", ClearTarget)
        if definition.sound ~= nil then
            inst:DoTaskInTime(0, function()
                inst.SoundEmitter:PlaySound(definition.sound, nil, definition.sound_volume or 1)
            end)
        end
        if not definition.loop then
            if definition.sound_duration == nil then
                inst:ListenForEvent("animover", function()
                    if inst.AnimState:AnimDone() then
                        inst:Remove()
                    end
                end)
            end
            local duration = math.max(inst.AnimState:GetCurrentAnimationLength(), definition.sound_duration or 0)
            inst:DoTaskInTime(duration + FRAMES, inst.Remove)
        end
        return inst
    end

    return Prefab(definition.name, fn, { Asset("ANIM", "anim/"..definition.bank..".zip") })
end

local definitions = {
    {
        name = "ark_lambda_background_fx", bank = "ark_closure_s3_background",
        anim = "idle", loop = true, offset = -1, light = true, light_radius = 0.8,
    },
    {
        name = "ark_lambda_aim_fx", bank = "ark_closure_s3_target",
        anim = "idle", loop = true, offset = 1, light = true, light_radius = 0.45,
    },
    {
        name = "ark_lambda_cast_fx", bank = "ark_closure_s3_cast",
        anim = "cast", offset = 1, light = true,
    },
    {
        name = "ark_lambda_hit_fx", bank = "ark_closure_s3_hit",
        anim = "hit", offset = 2, light = true,
        sound = "ark_lambda/sfx/hit", sound_duration = 0.56, sound_volume = 0.8,
    },
}

local prefabs = {}
for _, definition in ipairs(definitions) do
    table.insert(prefabs, MakeNetworkFx(definition))
end
return unpack(prefabs)
