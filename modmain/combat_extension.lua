local SourceModifierList = require("util/sourcemodifierlist")
local SpDamageUtil = GLOBAL.require("components/spdamageutil")

SpDamageUtil.DefineSpType("true_damage", {
    GetDamage = function(ent)
        if not ent.components.weapon then
            return 0
        end
        local multi = ent.components.weapon.truedamagemultipliers:Get() or 1
        local damage = ent.components.weapon.true_damage or 0
        return damage * multi
    end,
    -- 真实伤害不考虑防御，所以总是返回0
    GetDefense = function(ent)
        return 0
    end,
})

-- 使用 Symbol 作为缓存标记
local TIMELINE_RESCALED_KEY = GLOBAL.Symbol("timeline_rescaled")
local ORIGINAL_TIMES_KEY = GLOBAL.Symbol("original_times")

local function RescaleTimeline(self, val)
    local timeline = self.currentstate and self.currentstate.timeline
    if not timeline then
        return
    end

    -- 如果要重置（val == nil 或 1）
    if val == nil or val == 1 then
        -- 如果已经是原始状态，无需重置
        if not timeline[TIMELINE_RESCALED_KEY] then
            return
        end
        
        -- 恢复原始时间
        local original_times = timeline[ORIGINAL_TIMES_KEY]
        if original_times then
            for i, v in ipairs(timeline) do
                v.time = original_times[i]
            end
        end
        
        -- 清除标记
        timeline[TIMELINE_RESCALED_KEY] = nil
        timeline[ORIGINAL_TIMES_KEY] = nil
    else
        -- 如果已经缩放过相同的值，跳过
        if timeline[TIMELINE_RESCALED_KEY] == val then
            return
        end
        
        -- 保存原始时间（如果还没保存过）
        if not timeline[ORIGINAL_TIMES_KEY] then
            timeline[ORIGINAL_TIMES_KEY] = {}
            for i, v in ipairs(timeline) do
                timeline[ORIGINAL_TIMES_KEY][i] = v.time
            end
        end
        
        -- 应用新的缩放
        local original_times = timeline[ORIGINAL_TIMES_KEY]
        for i, v in ipairs(timeline) do
            v.time = original_times[i] / val
        end
        
        -- 标记当前缩放值
        timeline[TIMELINE_RESCALED_KEY] = val
    end
end

local function UpdateAttackSpeed(inst, speed)
    local combat = inst.components.combat
    if not combat.base_attack_period then
        combat.base_attack_period = combat.min_attack_period
    end
    -- 将实际周期的计算交给 SetAttackPeriod 的包装器：传入基准周期（unscaled base），
    -- 包装器会根据当前攻速重新计算并调用底层实现，避免重复缩放。
    combat:SetAttackPeriod(combat.base_attack_period)

    inst.replica.combat:SetAttackSpeed(speed)
    -- 推送攻速事件
    inst:PushEvent("attackspeedchanged", { speed = speed })
end

AddComponentPostInit("weapon", function(self)
    self.truedamagemultipliers = SourceModifierList(self.inst, 1, SourceModifierList.multiply)
end)

AddComponentPostInit("combat", function(self)
  self.inst.replica.combat:SetAttackSpeed(1)
  -- 初始化攻击速度修改器
  self.attackspeedmodifiers = SourceModifierList(self.inst, nil, nil, UpdateAttackSpeed)
  -- Wrap SetAttackPeriod to store an unscaled base period and apply current attack speed
  local _SetAttackPeriod = self.SetAttackPeriod
  function self:SetAttackPeriod(period)
    self.base_attack_period = period
    _SetAttackPeriod(self, period / self:GetAttackSpeed())
  end

  function self:SetAttackSpeed(speed)
    self.attackspeedmodifiers:SetModifier("ark_attack_speed", speed)
  end

  function self:GetAttackSpeed()
    return self.attackspeedmodifiers:Get()
  end
  -- 使用 SourceModifierList 的第三个参数为合并函数：
  -- 按顺序合并比例 v，使得结果为 m + (1-m)*v（序列化剩余伤害的转换）
  self.truedamagemultipliers = SourceModifierList(self.inst, 0, function(m, v)
    if v <= 0 then return m end
    if m >= 1 then return 1 end
    return m + (1 - m) * v
  end)

  function self:EnableTrueDamage(value)
    -- 接受数值 0..1，表示按顺序从剩余伤害中抽取的比例
    self.truedamagemultipliers:SetModifier("ark_true_damage", value)
  end

  function self:DisableTrueDamage()
    self.truedamagemultipliers:RemoveModifier("ark_true_damage")
  end

  -- 自定义固定伤害也可显式调用；输入必须是尚未转换的伤害对。
  function self:ConvertToTrueDamage(damage, spdamage)
    local proportion = math.min(self.truedamagemultipliers:Get(), 1)
    if proportion <= 0 then
      return damage, spdamage
    end

    damage = math.max(damage or 0, 0)
    local true_damage = damage * proportion
    local converted = {}
    -- 原版会继续修改特殊伤害表，不能原地改写调用方持有的表。
    for kind, amount in pairs(spdamage or {}) do
      if kind == "true_damage" then
        converted[kind] = amount
      else
        true_damage = true_damage + amount * proportion
        local remaining = amount * (1 - proportion)
        if remaining > 0 then
          converted[kind] = remaining
        end
      end
    end
    if true_damage > 0 then
      converted.true_damage = (converted.true_damage or 0) + true_damage
    end
    return damage * (1 - proportion), next(converted) ~= nil and converted or nil
  end

  -- 在攻击方使用原版计算结果，受击、护甲、事件及击杀仍由原版结算。
  ArkHookFunction(self, "CalcDamage", function(next, self, ...)
    local damage, spdamage = next(self, ...)
    return self:ConvertToTrueDamage(damage, spdamage)
  end)
end)

AddClassPostConstruct("components/combat_replica", function(self)
  self._ark_attack_speed = net_float(self.inst.GUID, "combat._ark_attack_speed")
  function self:SetAttackSpeed(speed)
    if TheWorld.ismastersim then
      self._ark_attack_speed:set(speed)
    end
  end
  function self:GetAttackSpeed()
    local speed = self._ark_attack_speed:value()
    if speed <= 0 then
      return 1
    end
    return speed
  end
end)


AddStategraphPostInit("wilson", function(sg)
    ArkHookFunction(sg.states["attack"], "onenter", function(next, inst, ...)
        next(inst, ...)
        if not inst.components.rider:IsRiding() and inst.sg.currentstate.name == "attack" then
            local attack_speed = inst.components.combat:GetAttackSpeed()
            if attack_speed ~= 1 then
                inst.AnimState:SetDeltaTimeMultiplier(attack_speed)
                RescaleTimeline(inst.sg, attack_speed)
            end
        end
    end)

    ArkHookFunction(sg.states["attack"], "onexit", function(next, inst, ...)
        next(inst, ...)
        inst.AnimState:SetDeltaTimeMultiplier(1)
        RescaleTimeline(inst.sg)
    end)
end)

AddStategraphPostInit("wilson_client", function(sg)
    ArkHookFunction(sg.states["attack"], "onenter", function(next, inst, ...)
        next(inst, ...)
        if not inst.replica.rider:IsRiding() and inst.sg.currentstate.name == "attack" then
            local attack_speed = inst.replica.combat:GetAttackSpeed()
            if attack_speed ~= 1 then
                inst.AnimState:SetDeltaTimeMultiplier(attack_speed)
                RescaleTimeline(inst.sg, attack_speed)
                if inst.sg.timeout then
                    inst.sg:SetTimeout(inst.sg.timeout / attack_speed)
                end
            end
        end
    end)

    ArkHookFunction(sg.states["attack"], "onexit", function(next, inst, ...)
        next(inst, ...)
        inst.AnimState:SetDeltaTimeMultiplier(1)
        RescaleTimeline(inst.sg)
    end)
end)
