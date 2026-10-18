-- One scheduler per shard. Plan from a shared snapshot before touching resources:
-- a donation is never budgeted twice, and received resources cannot be relayed.
local THRESHOLD = 20
local TARGET = 80
local RESERVE = 50
local COOLDOWN = 300
local EPSILON = 0.000001
local CAUSE = "sympathetic_pendant_rescue"

local function IsAlive(player)
  return player:IsValid() and not player:HasTag("playerghost")
      and not player:HasTag("INLIMBO") and not player.is_teleporting
      and player.components.health ~= nil and not player.components.health:IsDead()
end

local function IsAvailable(state)
  return IsAlive(state.player) and state.pendant.equipped ~= nil
      and state.pendant:GetRescueCooldown() <= 0
end

local function GetResource(player, kind)
  local component = player.components[kind]
  if component == nil then
    return nil
  end
  -- Age and redirected/disabled sanity are not transferable point pools.
  if kind == "health" then
    if player.components.oldager ~= nil then return nil end
    return component, component.currenthealth, component:GetMaxWithPenalty()
  end
  if component.ignore or component.redirect ~= nil then return nil end
  return component, component.current, component:GetMaxWithPenalty()
end

local function ChangeResource(player, kind, amount)
  local component, before = GetResource(player, kind)
  if component == nil then return 0 end
  if kind == "health" then
    -- A transfer is a resource cost, not an attack. SetVal is the native exact
    -- health setter; damage redirects, absorption and damage caps must not turn
    -- a paid donation into free healing or push the donor below the reserve.
    local oldpercent = component:GetPercent()
    component:SetVal(before + amount, CAUSE)
    local actual = component.currenthealth - before
    player:PushEvent("healthdelta", {
      oldpercent = oldpercent, newpercent = component:GetPercent(),
      overtime = true, cause = CAUSE, amount = actual,
    })
    if component.ondelta ~= nil then
      component.ondelta(player, oldpercent, component:GetPercent(), true, CAUSE, nil, actual)
    end
  else
    component:DoDelta(amount, true)
  end
  local _, after = GetResource(player, kind)
  return after ~= nil and after - before or 0
end

local function GetReserve(player, kind)
  -- Do not touch a health floor that could trigger a character's death-save.
  local health = player.components.health
  return kind == "health" and math.max(RESERVE, (health.minhealth or 0) + EPSILON) or RESERVE
end

local function PlanTransfers(states, links, kind)
  local budgets, needs, edges = {}, {}, {}
  for i, state in ipairs(states) do
    local resource = state[kind]
    budgets[i] = state.available and resource ~= nil and math.max(0, resource.current - GetReserve(state.player, kind)) or 0
    needs[i] = state.available and resource ~= nil and resource.current < THRESHOLD
        and math.max(0, math.min(TARGET, resource.max) - resource.current) or 0
  end

  -- Every donor offers to all linked requests in proportion to their unmet
  -- needs. Scale oversubscribed requests together, then redistribute leftovers.
  -- Each round exhausts at least one budget or request; no player-order winner.
  for _ = 1, #states + 1 do
    local offers, totals = {}, {}
    for i = 1, #states do
      if budgets[i] > EPSILON then
        local demand = 0
        for j = 1, #states do
          if links[i][j] then demand = demand + needs[j] end
        end
        if demand > EPSILON then
          offers[i] = {}
          for j = 1, #states do
            if links[i][j] and needs[j] > EPSILON then
              local amount = budgets[i] * needs[j] / demand
              offers[i][j] = amount
              totals[j] = (totals[j] or 0) + amount
            end
          end
        end
      end
    end
    local moved = 0
    for j = 1, #states do
      if totals[j] ~= nil then
        local scale = math.min(1, needs[j] / totals[j])
        for i = 1, #states do
          local amount = offers[i] and offers[i][j]
          if amount ~= nil then
            amount = amount * scale
            edges[i] = edges[i] or {}
            edges[i][j] = (edges[i][j] or 0) + amount
            budgets[i] = math.max(0, budgets[i] - amount)
            needs[j] = math.max(0, needs[j] - amount)
            moved = moved + amount
          end
        end
      end
    end
    if moved <= EPSILON then break end
  end

  -- A specialist donor may only reach a request already filled partly by a
  -- more flexible donor. Use residual paths to rearrange the PLAN, freeing the
  -- flexible donor for another request. No actual resource is moved twice.
  local count = #states
  while true do
    local previous, queue = {}, {}
    for i = 1, count do
      if budgets[i] > EPSILON then previous[i] = 0; queue[#queue + 1] = i end
    end
    local head, finish = 1, nil
    while head <= #queue and finish == nil do
      local node = queue[head]
      head = head + 1
      if node <= count then
        for j = 1, count do
          if links[node][j] and previous[count + j] == nil then
            previous[count + j] = node
            queue[#queue + 1] = count + j
            if needs[j] > EPSILON then finish = count + j; break end
          end
        end
      else
        local j = node - count
        for i = 1, count do
          if previous[i] == nil and edges[i] ~= nil and (edges[i][j] or 0) > EPSILON then
            previous[i] = node
            queue[#queue + 1] = i
          end
        end
      end
    end
    if finish == nil then break end
    local amount, node = needs[finish - count], finish
    while previous[node] ~= 0 do
      local parent = previous[node]
      if node <= count then amount = math.min(amount, edges[node][parent - count]) end
      node = parent
    end
    local start = node
    amount = math.min(amount, budgets[start])
    node = finish
    while previous[node] ~= 0 do
      local parent = previous[node]
      if node > count then
        edges[parent] = edges[parent] or {}
        edges[parent][node - count] = (edges[parent][node - count] or 0) + amount
      else
        edges[node][parent - count] = math.max(0, edges[node][parent - count] - amount)
      end
      node = parent
    end
    budgets[start] = math.max(0, budgets[start] - amount)
    needs[finish - count] = math.max(0, needs[finish - count] - amount)
  end
  return edges
end

local function ApplyTransfers(states, edges, kind, rescued)
  for i, donor in ipairs(states) do
    for j, receiver in ipairs(states) do
      local planned = edges[i] and edges[i][j]
      if planned ~= nil and planned > EPSILON and IsAvailable(donor) and IsAvailable(receiver) then
        local _, current = GetResource(donor.player, kind)
        local _, targetcurrent, targetmax = GetResource(receiver.player, kind)
        if current ~= nil and targetcurrent ~= nil then
          local amount = math.min(planned, math.max(0, current - GetReserve(donor.player, kind)),
              math.max(0, math.min(TARGET, targetmax) - targetcurrent))
          if amount > EPSILON then
            local paid = math.max(0, -ChangeResource(donor.player, kind, -amount))
            local received = 0
            if paid > EPSILON and IsAvailable(receiver) then
              local _, now, max = GetResource(receiver.player, kind)
              if now ~= nil then
                received = math.max(0, ChangeResource(receiver.player, kind,
                    math.min(paid, math.max(0, math.min(TARGET, max) - now))))
              end
            end
            if paid > received + EPSILON and IsAlive(donor.player) then
              ChangeResource(donor.player, kind, paid - received)
            end
            if received > EPSILON then rescued[j] = true end
          end
        end
      end
    end
  end
end

local function CollectStates(players)
  local states = {}
  for _, player in ipairs(players) do
    local pendant = player.components.sympathetic_pendant
    if pendant ~= nil and IsAlive(player) and pendant.equipped ~= nil then
      local state = { player = player, pendant = pendant, available = pendant:GetRescueCooldown() <= 0 }
      for _, kind in ipairs({ "health", "sanity" }) do
        local component, current, max = GetResource(player, kind)
        if component ~= nil then state[kind] = { current = current, max = max } end
      end
      states[#states + 1] = state
    end
  end
  table.sort(states, function(a, b) return a.player.GUID < b.player.GUID end)
  return states
end

local function UpdateAlerts(states, players)
  local flashing = {}
  for _, receiver in ipairs(states) do
    local _, health = GetResource(receiver.player, "health")
    local _, sanity = GetResource(receiver.player, "sanity")
    if IsAvailable(receiver) and ((health ~= nil and health < THRESHOLD) or (sanity ~= nil and sanity < THRESHOLD)) then
      for _, partner in ipairs(states) do
        if partner ~= receiver and IsAlive(partner.player) and partner.pendant.equipped ~= nil
            and receiver.pendant:IsResonanceMaxed(partner.player) then
          flashing[receiver.player] = true
          -- A cooling-down partner cannot flash or donate. The requester's own
          -- warning can still wait for that worn partner's ability to recover.
          if IsAvailable(partner) then flashing[partner.player] = true end
        end
      end
    end
  end
  for _, player in ipairs(players) do
    local pendant = player.components.sympathetic_pendant
    if pendant ~= nil then pendant:SetRescueFlashing(flashing[player] == true) end
  end
end

local function Update(players)
  local states = CollectStates(players)
  local links = {}
  for i, state in ipairs(states) do
    links[i] = {}
    for j, other in ipairs(states) do
      if i ~= j and state.available and other.available and state.pendant:IsResonanceMaxed(other.player) then
        -- Full resonance ignores distance for ordinary buffs, never for aid.
        local range = math.min(state.pendant.player_near_dist, other.pendant.player_near_dist)
        links[i][j] = state.player:GetDistanceSqToPoint(other.player.Transform:GetWorldPosition()) <= range * range
      end
    end
  end
  local healthplan = PlanTransfers(states, links, "health")
  local sanityplan = PlanTransfers(states, links, "sanity")
  local rescued = {}
  ApplyTransfers(states, healthplan, "health", rescued)
  ApplyTransfers(states, sanityplan, "sanity", rescued)
  -- Both resources and reciprocal aid settle as one batch. Only recipients
  -- enter cooldown, after the batch; donors are free to help again next tick.
  for i in pairs(rescued) do states[i].pendant:StartRescueCooldown(COOLDOWN) end
  UpdateAlerts(states, players)
end

return { Update = Update }
