local LIGHT_TRANSITION_ALPHA = 0.14
local LIGHT_TRANSITION_INTERVAL = 2 * FRAMES

local default_light = {
  colour = { 1, 1, 1 },
  radius = 1,
  falloff = 0.5,
  intensity = 0.8,
}

local function CopyLightState(state)
  local colour = state and state.colour or default_light.colour
  return {
    colour = { colour[1], colour[2], colour[3] },
    radius = state and state.radius or default_light.radius,
    falloff = state and state.falloff or default_light.falloff,
    intensity = state and state.intensity or default_light.intensity,
  }
end

local function IsLightStateClose(current, target)
  return math.abs((current.radius or 0) - (target.radius or 0)) <= 0.02
      and math.abs((current.intensity or 0) - (target.intensity or 0)) <= 0.02
      and math.abs((current.falloff or 0) - (target.falloff or 0)) <= 0.02
      and math.abs((current.colour[1] or 0) - (target.colour[1] or 0)) <= 0.02
      and math.abs((current.colour[2] or 0) - (target.colour[2] or 0)) <= 0.02
      and math.abs((current.colour[3] or 0) - (target.colour[3] or 0)) <= 0.02
end
local function ApplyLightState(inst, state)
  inst.Light:SetRadius(state.radius)
  inst.Light:SetFalloff(state.falloff)
  inst.Light:SetIntensity(state.intensity)
  inst.Light:SetColour(unpack(state.colour))
  inst.Light:Enable(not inst._rescue_dormant:value() and (state.intensity > 0.01 or state.radius > 0.01))
end
local function StopLightTransition(inst)
  if inst._transition_task ~= nil then
    inst._transition_task:Cancel()
    inst._transition_task = nil
  end
end

local function UpdateLightTransition(inst)
  if inst.current_light == nil or inst.target_light == nil then
    StopLightTransition(inst)
    return
  end

  local current = inst.current_light
  local target = inst.target_light
  current.radius = Lerp(current.radius, target.radius, LIGHT_TRANSITION_ALPHA)
  current.intensity = Lerp(current.intensity, target.intensity, LIGHT_TRANSITION_ALPHA)
  current.falloff = Lerp(current.falloff, target.falloff, LIGHT_TRANSITION_ALPHA)
  current.colour[1] = Lerp(current.colour[1], target.colour[1], LIGHT_TRANSITION_ALPHA)
  current.colour[2] = Lerp(current.colour[2], target.colour[2], LIGHT_TRANSITION_ALPHA)
  current.colour[3] = Lerp(current.colour[3], target.colour[3], LIGHT_TRANSITION_ALPHA)

  if IsLightStateClose(current, target) then
    inst.current_light = CopyLightState(target)
    current = inst.current_light
    StopLightTransition(inst)
  end

  ApplyLightState(inst, current)
end

local function UpdateLight(inst, state)
  inst.target_light = CopyLightState(state)
  if inst.current_light == nil or IsLightStateClose(inst.current_light, inst.target_light) then
    inst.current_light = CopyLightState(inst.target_light)
    ApplyLightState(inst, inst.current_light)
    StopLightTransition(inst)
    return
  end
  if inst._transition_task == nil then
    inst._transition_task = inst:DoPeriodicTask(LIGHT_TRANSITION_INTERVAL, UpdateLightTransition)
  end
end

local function HasPendant(inst, owner)
  -- Other players' inventory_classified is private to their owning client.
  -- Check the visible symbol instead, including the networked skin build.
  local build = owner ~= nil and owner.AnimState:GetSymbolOverride("swap_body") or nil
  return build ~= nil and build == inst._pendant_build:value()
end

local function SetPendantBuild(inst, build)
  inst._pendant_build:set(hash(build ~= nil and build ~= "" and build or "torso_sympathetic_pendants"))
end

local function ResetRescueFlash(inst)
  local owner = inst._flash_owner or inst.entity:GetParent()
  if owner ~= nil and owner:IsValid() and HasPendant(inst, owner) then
    if inst._rescue_dormant:value() then
      owner.AnimState:ClearSymbolBloom("swap_body")
      owner.AnimState:SetSymbolLightOverride("swap_body", 0)
      owner.AnimState:SetSymbolAddColour("swap_body", 0, 0, 0, 1)
    else
      owner.AnimState:SetSymbolBloom("swap_body")
      owner.AnimState:SetSymbolLightOverride("swap_body", 1)
      owner.AnimState:SetSymbolAddColour("swap_body", 0.05, 0.05, 0.05, 0.5)
    end
  end
  inst._flash_owner = nil
end

local function UpdateRescueFlash(inst)
  local owner = inst.entity:GetParent()
  if owner ~= inst._flash_owner then ResetRescueFlash(inst) end
  if owner ~= nil and owner:IsValid() and HasPendant(inst, owner) then
    inst._flash_owner = owner
    -- All pendants use the same local clock phase, including a partner that
    -- enters the client's view later. Only the on/off flag is a custom netvar.
    local pulse = (1 + math.cos(GetTime() * 2 * PI / 0.8)) * 0.5
    owner.AnimState:SetSymbolLightOverride("swap_body", 0.1 + 0.9 * pulse)
    local glow = 0.65 * pulse
    owner.AnimState:SetSymbolAddColour("swap_body", glow, glow, glow, pulse)
  end
end

local function OnRescueFlashDirty(inst)
  -- Light enablement is also replicated natively by the server. Applying the
  -- dormancy flag locally closes the gap if its packet arrives first.
  inst.Light:Enable(not inst._rescue_dormant:value())
  if inst._rescue_flashing:value() and not inst._rescue_dormant:value() then
    if inst._flash_task == nil then
      inst._flash_task = inst:DoPeriodicTask(2 * FRAMES, UpdateRescueFlash)
    end
    UpdateRescueFlash(inst)
  else
    if inst._flash_task ~= nil then
      inst._flash_task:Cancel()
      inst._flash_task = nil
    end
    ResetRescueFlash(inst)
  end
end

local function SetRescueDormant(inst, dormant)
  if inst._rescue_dormant:value() ~= dormant then
    inst._rescue_dormant:set(dormant)
    -- Keep the ordinary light state cached while disabling its emission, so
    -- changes of emotion/range during cooldown cannot switch it back on.
    ApplyLightState(inst, inst.current_light or inst.target_light)
    if not TheNet:IsDedicated() then OnRescueFlashDirty(inst) end
  end
end

local function SetRescueFlashing(inst, flashing)
  if inst._rescue_flashing:value() ~= flashing then
    inst._rescue_flashing:set(flashing)
    if not TheNet:IsDedicated() then OnRescueFlashDirty(inst) end
  end
end

local function lightfn()
  local inst = CreateEntity()
  inst.entity:AddTransform()
  inst.entity:AddLight()
  inst.entity:AddNetwork()

  inst._rescue_flashing = net_bool(inst.GUID, "sympathetic_pendant_light.rescue_flashing", "rescueflashdirty")
  inst._rescue_dormant = net_bool(inst.GUID, "sympathetic_pendant_light.rescue_dormant", "rescueflashdirty")
  inst._pendant_build = net_hash(inst.GUID, "sympathetic_pendant_light.pendant_build")
  SetPendantBuild(inst)

  inst:AddTag("FX")
  inst:AddTag("NOCLICK")
  inst.target_light = CopyLightState(default_light)
  inst.current_light = nil
  inst.UpdateLight = UpdateLight
  inst.SetRescueFlashing = SetRescueFlashing
  inst.SetRescueDormant = SetRescueDormant
  inst.SetPendantBuild = SetPendantBuild
  ApplyLightState(inst, inst.target_light)
  inst.entity:SetPristine()

  if not TheNet:IsDedicated() then
    inst:ListenForEvent("rescueflashdirty", OnRescueFlashDirty)
    inst:ListenForEvent("onremove", ResetRescueFlash)
    inst:DoTaskInTime(0, OnRescueFlashDirty)
  end

  if not TheWorld.ismastersim then
    return inst
  end

  inst.persists = false
  inst.entity:SetCanSleep(false)
  return inst
end
return Prefab("sympathetic_pendant_light", lightfn)
