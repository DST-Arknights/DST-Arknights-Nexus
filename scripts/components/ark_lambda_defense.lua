local NoStagger = require("ark_lambda_no_stagger")
local FIND_MUST_TAGS = { "_combat", "_health" }
local FIND_CANT_TAGS = {
    "INLIMBO", "invisible", "notarget", "debugnoattack", "player", "playerghost", "ghost",
    "companion", "pet", "critter", "player_aligned", "domesticated", "engineering", "eyeturret",
}
local THREAT_MEMORY_TIME = 3

local function DoScan(inst, defense)
    defense:Scan()
end

local function CompareDistance(a, b)
    return a.distance < b.distance
end

local function CheckNumber(value, minimum, label, allow_equal)
    assert(type(value) == "number" and value == value and value < math.huge
        and (value > minimum or allow_equal and value == minimum), label)
end

local function IsPlayerAlly(target)
    if target.bedazzled then
        return true
    end
    local visited = {}
    local leader = target.components.follower ~= nil and target.components.follower:GetLeader() or nil
    while leader ~= nil and not visited[leader] do
        if leader:HasTag("player") or leader:HasTag("companion") or leader.components.inventoryitem ~= nil then
            return true
        end
        visited[leader] = true
        leader = leader.components.follower ~= nil and leader.components.follower:GetLeader() or nil
    end
    return false
end

local function IsActivePlayer(player)
    local health = player.components.health
    return player:IsValid() and not player:IsInLimbo() and not player:HasTag("playerghost")
        and health ~= nil and not health:IsDead()
end

local function IsProtectedUnit(target)
    if target == nil or not target:IsValid() or target:HasAnyTag("INLIMBO", "playerghost", "ghost")
        or target.components.health ~= nil and target.components.health:IsDead() then
        return false
    end
    return target:HasAnyTag("player", "companion", "pet", "critter", "player_aligned", "domesticated",
            "engineering", "eyeturret")
        or target.components.ark_lambda_defense ~= nil or IsPlayerAlly(target)
end

local function ClearSlows(target)
    local sources = target._ark_lambda_slows
    if sources == nil then
        return
    end
    target._ark_lambda_slows = nil
    for key, source in pairs(sources) do
        if source.task ~= nil then
            source.task:Cancel()
        end
        if target.components.locomotor ~= nil then
            target.components.locomotor:RemoveExternalSpeedMultiplier(target, key)
        end
    end
    target:RemoveEventCallback("death", ClearSlows)
    target:RemoveEventCallback("onremove", ClearSlows)
end

local function UpdateSlow(target, key)
    local sources = target._ark_lambda_slows
    local source = sources ~= nil and sources[key] or nil
    if source == nil then
        return
    end
    if source.task ~= nil then
        source.task:Cancel()
        source.task = nil
    end

    local now = GetTime()
    while source.expires[1] ~= nil and source.expires[1] <= now do
        table.remove(source.expires, 1)
    end
    local locomotor = target.components.locomotor
    if #source.expires == 0 then
        if locomotor ~= nil then
            locomotor:RemoveExternalSpeedMultiplier(target, key)
        end
        sources[key] = nil
        if next(sources) == nil then
            ClearSlows(target)
        end
        return
    end

    if locomotor ~= nil then
        local stacks = math.min(#source.expires, source.maxstacks)
        local mult = 1 - (1 - source.mult) * stacks / source.maxstacks
        locomotor:SetExternalSpeedMultiplier(target, key, mult)
    end
    source.task = target:DoTaskInTime(source.expires[1] - now, UpdateSlow, key)
end

local ArkLambdaDefense = Class(function(self, inst)
    self.inst = inst
    self.enabled = false
    self.range = 8
    self.attackperiod = 1
    self.scaninterval = .25
    self.slowmult = .5
    self.slowduration = 8
    self.activationdelay = 0
    self.targetwindup = 0
    self.target = nil
    self.targets = {}
    self._targetreadytimes = {}
    self._playertargets = {}
    self._threats = {}
    self._attackrounds = 0
    self._combatactive = false
    self.resourceblocked = false
    self._paymentblocked = false
    self._hasenemy = false
    self._rangestate = 0
    self._ismastersim = TheWorld.ismastersim
    self._slowkey = "ark_lambda_slow_"..tostring(inst.GUID)
    self:SetRange(self.range)
    self:SetAttackPeriod(self.attackperiod)
end)

function ArkLambdaDefense:SetTargetChangedFn(fn)
    assert(fn == nil or type(fn) == "function", "target callback must be a function")
    self.ontargetchangedfn = fn
end

function ArkLambdaDefense:SetOnAttackFn(fn)
    assert(fn == nil or type(fn) == "function", "attack callback must be a function")
    self.onattackfn = fn
end

function ArkLambdaDefense:SetCombatActiveChangedFn(fn)
    assert(fn == nil or type(fn) == "function", "combat callback must be a function")
    self.oncombatactivechangedfn = fn
    if fn ~= nil and self._ismastersim then
        fn(self.inst, self._combatactive)
    end
end

function ArkLambdaDefense:_SetCombatActive(active)
    if self._combatactive ~= active then
        self._combatactive = active
        if self.oncombatactivechangedfn ~= nil then
            self.oncombatactivechangedfn(self.inst, active)
        end
    end
end

function ArkLambdaDefense:SetRangeStateChangedFn(fn)
    assert(fn == nil or type(fn) == "function", "range state callback must be a function")
    self.onrangestatechangedfn = fn
    if fn ~= nil and self._ismastersim then
        fn(self.inst, self._rangestate)
    end
end

function ArkLambdaDefense:_UpdateRangeState()
    local state = 0
    if self.enabled then
        state = 1
        if self._hasenemy then
            state = (self.resourceblocked or self._paymentblocked) and 3 or 2
        end
    end
    if self._rangestate ~= state then
        self._rangestate = state
        if self.onrangestatechangedfn ~= nil then
            self.onrangestatechangedfn(self.inst, state)
        end
    end
end

-- Additional resource conditions can block firing alongside the currency check.
function ArkLambdaDefense:SetResourceBlocked(blocked)
    assert(type(blocked) == "boolean", "resource blocked must be a boolean")
    self.resourceblocked = blocked
    self:_UpdateRangeState()
end

function ArkLambdaDefense:_GetNearbyPlayers()
    local x, _, z = self.inst.Transform:GetWorldPosition()
    local radius_sq = self.range * self.range * 4
    local players = {}
    for _, player in ipairs(AllPlayers) do
        if IsActivePlayer(player) then
            local px, _, pz = player.Transform:GetWorldPosition()
            if (px-x)*(px-x) + (pz-z)*(pz-z) <= radius_sq then
                table.insert(players, player)
            end
        end
    end
    return players
end

function ArkLambdaDefense:_GetPaymentPlan()
    local payments = {}
    local available = {}
    local total = 0
    for _, player in ipairs(self:_GetNearbyPlayers()) do
        local currency = player.components.ark_currency
        if currency ~= nil then
            local balance = math.max(0, currency:GetArkGold())
            local payment = { currency = currency, amount = 0, balance = balance }
            table.insert(payments, payment)
            total = total + balance
            if balance > 0 then
                table.insert(available, payment)
            end
        end
    end
    local cost = math.max(0, math.ceil(self.inst.components.combat.defaultdamage))
    if #payments == 0 or total < cost then
        return nil
    end

    -- Split equally, then redistribute any shortfall among wallets with funds.
    -- Integer remainders rotate between successful attack rounds.
    local remaining = cost
    while remaining > 0 do
        local count = #available
        local share = math.floor(remaining / count)
        local remainder = remaining % count
        local next_available = {}
        for i, payment in ipairs(available) do
            local extra = (i - 1 - self._attackrounds) % count < remainder and 1 or 0
            local amount = math.min(payment.balance, share + extra)
            payment.amount = payment.amount + amount
            payment.balance = payment.balance - amount
            remaining = remaining - amount
            if payment.balance > 0 then
                table.insert(next_available, payment)
            end
        end
        available = next_available
    end
    return payments
end

function ArkLambdaDefense:_PayForRound()
    -- Rebuild from current players and balances before changing any wallet.
    -- This also redistributes funds changed since the range-state check.
    local payments = self:_GetPaymentPlan()
    if payments == nil then
        return false
    end
    for _, payment in ipairs(payments) do
        if payment.amount > 0 then
            payment.currency:AddArkGold(-payment.amount)
        end
    end
    return true
end

function ArkLambdaDefense:SetRange(range)
    CheckNumber(range, 0, "range must be finite and nonnegative", true)
    self.range = range
    if self._ismastersim and self.inst.components.combat ~= nil then
        self.inst.components.combat:SetRange(range, range)
    end
    for target in pairs(self._threats) do
        if not self:IsValidTarget(target) then
            self._threats[target] = nil
        end
    end
    for i = 1, 7 do
        if self.targets[i] ~= nil and not self:IsValidTarget(self.targets[i]) then
            self:_SetTarget(i, nil)
        end
    end
end

function ArkLambdaDefense:GetRange()
    return self.range
end

function ArkLambdaDefense:SetAttackPeriod(period)
    CheckNumber(period, 0, "attack period must be finite and positive")
    self.attackperiod = period
    if self._ismastersim and self.inst.components.combat ~= nil then
        self.inst.components.combat:SetAttackPeriod(period)
    end
end

function ArkLambdaDefense:SetScanInterval(interval)
    CheckNumber(interval, 0, "scan interval must be finite and positive")
    self.scaninterval = interval
    if self._scantask ~= nil then
        self._scantask:Cancel()
        self._scantask = nil
        if not self.inst:IsAsleep() then
            self._scantask = self.inst:DoPeriodicTask(interval, DoScan, 0, self)
        end
    end
end

function ArkLambdaDefense:SetSlow(mult, duration)
    CheckNumber(mult, 0, "slow multiplier must be between zero and one", true)
    assert(mult <= 1, "slow multiplier must be between zero and one")
    CheckNumber(duration, 0, "slow duration must be finite and nonnegative", true)
    self.slowmult = mult
    self.slowduration = duration
end

function ArkLambdaDefense:SetActivationDelay(seconds)
    CheckNumber(seconds, 0, "activation delay must be finite and nonnegative", true)
    self.activationdelay = seconds
end

function ArkLambdaDefense:SetTargetWindup(seconds)
    CheckNumber(seconds, 0, "target windup must be finite and nonnegative", true)
    self.targetwindup = seconds
end

function ArkLambdaDefense:GetEnabled()
    return self.enabled
end

function ArkLambdaDefense:GetTarget()
    return self.target
end

function ArkLambdaDefense:_SetTarget(index, target)
    if self.targets[index] == target then
        return
    end
    self.targets[index] = target
    self._targetreadytimes[index] = target ~= nil and GetTime()+self.targetwindup or nil
    if index == 1 then
        self.target = target
    end
    if index == 1 and self.inst.components.combat ~= nil then
        self.inst.components.combat:SetTarget(target)
    end
    if self.ontargetchangedfn ~= nil then
        self.ontargetchangedfn(self.inst, target, index)
    end
end

function ArkLambdaDefense:_HasCombatRelation(target)
    local victim = target.components.combat.target
    return self._playertargets[target] == true or victim == self.inst or IsProtectedUnit(victim)
end

function ArkLambdaDefense:IsValidTarget(target)
    if target == nil or target == self.inst or not target:IsValid() or target.Transform == nil
        or target:HasAnyTag(unpack(FIND_CANT_TAGS)) or not target.entity:IsVisible()
        or target.components.health == nil or target.components.health:IsDead()
        or target.components.combat == nil or target.components.ark_lambda_defense ~= nil
        or self.inst.prefab ~= nil and target.prefab == self.inst.prefab
        or IsPlayerAlly(target) then
        return false
    end
    local combat = self.inst.components.combat
    if combat == nil or not combat:CanTarget(target) then
        return false
    end
    local x, _, z = self.inst.Transform:GetWorldPosition()
    local tx, _, tz = target.Transform:GetWorldPosition()
    if (tx-x)*(tx-x)+(tz-z)*(tz-z) > self.range*self.range then
        return false
    end
    return self:_HasCombatRelation(target)
        or self._threats[target] ~= nil and GetTime() < self._threats[target]
end

function ArkLambdaDefense:_ApplySlow(target)
    if self.slowmult == 1 or self.slowduration == 0 or target.components.locomotor == nil
        or not target:IsValid() or target.components.health == nil or target.components.health:IsDead() then
        return
    end
    -- Hits contribute independent layers. Their original expiry times let the
    -- victim recover in hit order, with a per-tower cap on total slowing.
    -- Use the victim as modifier source so layers outlive a removed tower.
    local sources = target._ark_lambda_slows
    if sources == nil then
        sources = {}
        target._ark_lambda_slows = sources
        target:ListenForEvent("death", ClearSlows)
        target:ListenForEvent("onremove", ClearSlows)
    end
    local key = self._slowkey
    local source = sources[key]
    if source == nil then
        source = { expires = {} }
        sources[key] = source
    end
    source.mult = self.slowmult
    source.maxstacks = math.max(1, math.ceil(self.slowduration / self.attackperiod))
    table.insert(source.expires, GetTime() + self.slowduration)
    table.sort(source.expires)
    UpdateSlow(target, key)
end

function ArkLambdaDefense:Scan()
    if not self._ismastersim or not self.enabled or self._removed then
        return
    end
    if not self.inst:IsValid() then
        self:SetEnabled(false)
        return
    end
    if self.inst:IsAsleep() then
        return
    end
    local now = GetTime()
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local found = TheSim:FindEntities(x, y, z, self.range, FIND_MUST_TAGS, FIND_CANT_TAGS)
    -- Like native turrets, assist players' current combat targets. Use the same
    -- nearby area as payment, without an additional entity search for players.
    self._playertargets = {}
    local nearby_players = #found > 0 and self:_GetNearbyPlayers() or {}
    for _, player in ipairs(nearby_players) do
        local combat = player.components.combat
        if combat ~= nil and combat.target ~= nil then
            self._playertargets[combat.target] = true
        end
    end
    for target, expires in pairs(self._threats) do
        if expires <= now or not self:IsValidTarget(target) then
            self._threats[target] = nil
        end
    end
    local candidates = {}
    for _, candidate in ipairs(found) do
        if self:IsValidTarget(candidate) then
            -- Only real combat relations refresh memory. The tower's own hits
            -- must not keep a now-neutral creature hostile indefinitely.
            if self:_HasCombatRelation(candidate) then
                self._threats[candidate] = now + THREAT_MEMORY_TIME
            end
            local tx, _, tz = candidate.Transform:GetWorldPosition()
            table.insert(candidates, { target = candidate, distance = (tx-x)*(tx-x)+(tz-z)*(tz-z) })
        end
    end
    self._hasenemy = #candidates > 0
    local canpay = false
    if self._hasenemy then
        local total, has_payer = 0, false
        for _, player in ipairs(nearby_players) do
            local currency = player.components.ark_currency
            if currency ~= nil then
                has_payer = true
                total = total + math.max(0, currency:GetArkGold())
            end
        end
        canpay = has_payer and total >= math.max(0, math.ceil(self.inst.components.combat.defaultdamage))
    end
    self._paymentblocked = self._hasenemy and not canpay
    self:_UpdateRangeState()
    if #candidates > 0 then
        self._lastenemytime = now
        self:_SetCombatActive(true)
    elseif self._lastenemytime ~= nil and now-self._lastenemytime >= 5 then
        self._lastenemytime = nil
        self._attackrounds = 0
        self:_SetCombatActive(false)
    end

    local limit = math.min(7, 1 + math.floor(self._attackrounds / 9))
    local selected = {}
    local vacancies = {}
    for i = 1, 7 do
        local target = self.targets[i]
        if target ~= nil and (i > limit or not self:IsValidTarget(target)) then
            self:_SetTarget(i, nil)
        elseif target ~= nil then
            selected[target] = true
        end
        if i <= limit and self.targets[i] == nil then
            table.insert(vacancies, i)
        end
    end
    if #vacancies > 0 and #candidates > 0 then
        table.sort(candidates, CompareDistance)
        local next_slot = 1
        for _, candidate in ipairs(candidates) do
            if not selected[candidate.target] then
                self:_SetTarget(vacancies[next_slot], candidate.target)
                selected[candidate.target] = true
                next_slot = next_slot + 1
                if next_slot > #vacancies then
                    break
                end
            end
        end
    end
    local combat = self.inst.components.combat
    if canpay and not self.resourceblocked and now >= self._activationreadytime
        and (self._lastattacktime == nil or now-self._lastattacktime >= self.attackperiod) then
        local ready = {}
        for i = 1, limit do
            local target = self.targets[i]
            if target ~= nil and now >= self._targetreadytimes[i]
                and self:IsValidTarget(target) and combat:CanAttack(target) and combat:CanHitTarget(target) then
                table.insert(ready, { target = target, index = i })
            end
        end
        if #ready == 0 then
            return
        end
        if not self:_PayForRound() then
            self._paymentblocked = true
            self:_UpdateRangeState()
            return
        end
        local attacked = false
        for _, attack in ipairs(ready) do
            local target = attack.target
            if self.onattackfn ~= nil then
                self.onattackfn(self.inst, target, attack.index)
            end
            if self.enabled and not self.resourceblocked and not self._removed and self:IsValidTarget(target) then
                NoStagger.Prepare(target)
                combat:DoAttack(target)
                self:_ApplySlow(target)
                attacked = true
            end
        end
        if attacked then
            self._lastattacktime = now
            self._attackrounds = self._attackrounds + 1
            combat:RestartCooldown()
        end
    end
end

function ArkLambdaDefense:_StartScanning()
    if not self._ismastersim or not self.enabled or self._removed or self._scantask ~= nil
        or not self.inst:IsValid() or self.inst:IsAsleep() then
        return
    end
    self._activationreadytime = GetTime()+self.activationdelay
    self._scantask = self.inst:DoPeriodicTask(self.scaninterval, DoScan, 0, self)
end

function ArkLambdaDefense:_StopScanning()
    if self._scantask ~= nil then
        self._scantask:Cancel()
        self._scantask = nil
    end
    for i = 1, 7 do
        self:_SetTarget(i, nil)
    end
    self._lastenemytime = nil
    self._attackrounds = 0
    self._hasenemy = false
    self._paymentblocked = false
    self._playertargets = {}
    self._threats = {}
    self:_SetCombatActive(false)
    self:_UpdateRangeState()
end

function ArkLambdaDefense:SetEnabled(enabled)
    assert(type(enabled) == "boolean", "enabled must be a boolean")
    if not self._ismastersim or self._removed or self.enabled == enabled then
        return
    end
    self.enabled = enabled
    if enabled then
        self:_StartScanning()
    else
        self:_StopScanning()
    end
    self:_UpdateRangeState()
end

function ArkLambdaDefense:OnEntitySleep()
    if self._ismastersim and not self._removed then
        self:_StopScanning()
    end
end

function ArkLambdaDefense:OnEntityWake()
    self:_StartScanning()
end

function ArkLambdaDefense:OnLoad()
    if self._ismastersim then
        self:SetEnabled(true)
    end
end

function ArkLambdaDefense:OnRemoveFromEntity()
    self:SetEnabled(false)
    self._removed = true
end

ArkLambdaDefense.OnRemoveEntity = ArkLambdaDefense.OnRemoveFromEntity

return ArkLambdaDefense
