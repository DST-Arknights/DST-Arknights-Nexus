local Visuals = {}
local RANGE_COLOURS = {
    [1] = { 0.55, 0.80, 1.00 }, -- alert
    [2] = { 1.00, 0.18, 0.15 }, -- attacking
    [3] = { 1.00, 0.83, 0.20 }, -- resource blocked
}
local ROTATION_PERIOD = 20
local PULSE_PERIOD = 4

local function RemoveRange(fx)
    if fx ~= nil and fx:IsValid() then
        fx:Remove()
    end
end

-- The mesh is white. State tint, rotation and breathing are applied locally.
local function CreateRange()
    local fx = CreateEntity()
    fx.entity:AddTransform()
    fx.entity:AddAnimState()
    fx.entity:SetCanSleep(false)
    fx:AddTag("DECOR")
    fx:AddTag("NOCLICK")
    fx.persists = false
    fx.AnimState:SetBank("ark_lambda_range")
    fx.AnimState:SetBuild("ark_lambda_range")
    fx.AnimState:PlayAnimation("idle", true)
    fx.AnimState:SetLightOverride(0)
    fx.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    fx.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
    fx.AnimState:SetSortOrder(3)
    return fx
end

local function UpdateStyle(fx, state)
    local colour = RANGE_COLOURS[state]
    local time = GetTime()
    local pulse = 0.5 + 0.5 * math.sin(time * 2 * math.pi / PULSE_PERIOD)
    fx.AnimState:SetMultColour(colour[1], colour[2], colour[3], 0.24 * pulse)
    fx.Transform:SetRotation(time * 360 / ROTATION_PERIOD % 360)
end

function Visuals.CreatePlacementRange(placer)
    local fx = CreateRange()
    local config = TUNING.ARK_LAMBDA_COMMAND_CENTER
    placer.AnimState:SetScale(config.BODY_SCALE, config.BODY_SCALE, config.BODY_SCALE)
    fx.AnimState:SetScale(config.RANGE, config.RANGE)
    fx.Transform:SetPosition(placer.Transform:GetWorldPosition())
    UpdateStyle(fx, 1)
    placer:ListenForEvent("onremove", function() RemoveRange(fx) end)
    placer:DoPeriodicTask(FRAMES, function()
        fx.Transform:SetPosition(placer.Transform:GetWorldPosition())
        UpdateStyle(fx, 1)
    end)
end

local function UpdateRange(inst)
    local state = inst._rangestate:value()
    if RANGE_COLOURS[state] == nil then
        RemoveRange(inst._rangefx)
        inst._rangefx = nil
        return
    end
    if inst._rangefx == nil then
        inst._rangefx = CreateRange()
    end
    local fx = inst._rangefx
    UpdateStyle(fx, state)
    fx.AnimState:SetScale(inst._range:value(), inst._range:value())
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
end

local function PauseRange(inst)
    if inst._rangetask ~= nil then
        inst._rangetask:Cancel()
        inst._rangetask = nil
    end
    RemoveRange(inst._rangefx)
    inst._rangefx = nil
end

function Visuals.Cleanup(inst)
    inst._rangevisualsstopped = true
    PauseRange(inst)
end

local function ResumeRange(inst)
    if inst._rangetask == nil and not inst._rangevisualsstopped and not inst._dismantling
        and inst:IsValid() and not inst:IsAsleep() then
        inst._rangetask = inst:DoPeriodicTask(FRAMES, UpdateRange, 0)
    end
end

function Visuals.Attach(inst)
    if TheNet:IsDedicated() then
        return
    end
    inst:ListenForEvent("onremove", Visuals.Cleanup)
    inst:ListenForEvent("entitysleep", PauseRange)
    inst:ListenForEvent("entitywake", ResumeRange)
    ResumeRange(inst)
end

return Visuals
