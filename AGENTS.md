# 源枢（DST-Arknights-Nexus）AI 编程指南

## 项目定位

本项目「源枢」（Arknights: Nexus）通常作为其他模组的依赖模组使用，提供可复用的 API、组件扩展和 UI/网络工具，并包含装备与玩法扩展。

- GitHub 仓库：`DST-Arknights/DST-Arknights-Nexus`。
- 项目名：`DST-Arknights-Nexus`。本地位置从记忆中查找；若记忆不明确，先向用户询问，不要在指南中假定机器路径。
- Steam 工坊 ID：`3677284770`。

## 共享开发约定

通用 DST 编码规范、兼容性模式和工作流统一维护在共享项目 `DST-Arknights-AICoding` 中。开始任务前按需要读取对应 skill；共享项目的位置同样从记忆中查找，记忆不明确时先向用户询问。

本文件只保留源枢自身的 API、资源、发布和维护约定。其他项目的通用规则不要复制到这里。

在新增功能或修复逻辑时，优先复用本仓库已经安装的扩展，不要直接覆写底层组件字段，尤其是战斗、生命、防御相关属性。

## 可露希尔特效缓存与重建

- 五个 `ark_closure_s3_*` 编译包保留在 `anim/`；其中缓速使用原作 `common_slow_01` 片段。本批来自 legacy 120PPU 采样烘焙，源 PNG 保留原文件像素。额外整体 `animation_scale=1`，显示大小在使用处 Lua 调整。用户选定贴图本色与光晕，额外 DST Bloom 已移除。
- 用户选择将原 PNG、`source.json` 和 IR 保存在 `temp/closure_fx_scale_test/sources/<bank>/`。专用构建脚本与默认配置在 `temp/closure_fx_scale_test/tooling/`，候选、catalog与编译记录在同任务缓存内。该批由共享 `workflow-headless-dst-animation` 直接生成 BILD/ANIM，并调用官方 `TextureConverter.exe` 生成 TEX。`temp/` 按项目发布规则排除。
- 原四组默认 `playback_speed=2`，源30FPS直接输出60FPS并保留426张源帧，Lua 时间倍率为1。background为120帧/2秒，target的pre/idle/pst为9/171/60帧、0.15/2.85/1秒，hit/cast各33帧/0.55秒；缓速为120帧循环片段。背景、瞄准idle和缓速均为有限采样片段，接缝待实机验收。
- 默认图集上限8192，每组限1页。各组候选通过二进制、源帧顺序、FPS、挂点与绝对图集映射检查后才替换 `anim/`，旧包留在任务缓存供回退。当前未旋转逐帧 PNG 另检查 `ΔU×atlasW=ΔX`、`-ΔV×atlasH=ΔY`，捕获旧第三页UV夹断问题。
- 本轮尺寸/颜色实验模块、控制命令和自动试播入口已移除。

## λ指挥中心

- 实体为 `ark_lambda_command_center`，放置预览为 `ark_lambda_command_center_placer`。按用户设定是无health建筑，保留HAMMER拆除和独立攻击组件。workable使用原生SetWorkMultiplierFn只允许player来源扣除拆除工作量，屏蔽巨兽、投射物等非玩家拆毁，玩家仍可按4次基础锤击拆除。配方为1个犀牛角、12块铥矿、6个齿轮、6个电子元件、2颗黄宝石，暗影操控器科技 `TECH.MAGIC_THREE`，按普通原型配方学习后随处制作，在罗德岛科技 `ARK_TECHNOLOGY` 分类显示，按原生配方规则解锁。本体使用 `anim/closure_command_native.zip` 的 Start/Idle/Die，战斗特效集中声明于 `scripts/prefabs/ark_lambda_fx.lua`，均为服务端管理、带 AnimState 的网络实体；瞄准只循环 idle，pre/pst及缓速动画包保留但暂不调用。指挥中心无玩家开关，放置和读档后自动工作，拆除或death事件播放Die后移除。背景和瞄准实体附带淡粉色小光源，半径分别0.8和0.45，强度0.5。命中音效通过PlaySound音量参数按原音量的80%播放。各目标特效以固定尺寸跟随物种命中挂点，缺失时按视觉框半高回退。`scripts/ark_lambda_visuals.lua` 只负责玩家本地的放置与常驻范围圈。
- 参数集中在 `modmain/ark_lambda_command_center.lua`：半径16、伤害10、攻击周期0.25秒、单塔减速上限50%，每次命中一层、每层8秒独立到期；当前攻速下32层、每层约1.5625%，连续命中约8秒叠满，最后一击8秒后完全恢复。本体和放置预览显示倍率1.5，FX倍率3。启动等待0.5秒，新目标首击等待至少0.15秒；同一目标持续循环瞄准idle。
- 服务端组件 `ark_lambda_defense` 负责圆形多目标扫描、友军过滤、普通combat伤害入口和短时速度modifier，读档后自动启用。原生组件OnEntitySleep取消扫描并释放目标/背景/交战记录，保留enabled意图；OnEntityWake仅恢复唯一扫描任务并重新启动预热，睡眠读档不建扫描任务，禁用/移除后不会被苏醒重启。空场跳过玩家处理，只有存在空目标槽时才排序候选，补满即停止遍历。判敌沿用原版眼球塔/投石机的当前战斗关系：协助攻击半径2倍内AllPlayers中存活玩家的当前目标，并拦截正在攻击玩家、玩家随从/宠物/驯养单位及友方防御设施的生物；monster/hostile标签不单独触发开火。真实战斗关系保留3秒短期记忆，塔自身持续射击不刷新记忆；死亡、离开范围、变为友军或不可攻击时释放，禁用时清空，记忆不存档。从单目标开始，每攻击9轮增加1个目标，最多7个；有敌人时显示背景，空场5秒后隐藏并重置预热。每座塔的缓速来源独立，多塔遵循locomotor倍率乘算规则；各次命中按顺序独立到期并恢复速度，缓速不显示特效。`ark_lambda_no_stagger` 只拦截本塔受击事件导致的常见 hit/hit_stunlock 状态，不覆盖自定义硬直状态。玩法范围通过实体的 `SetAttackRange` 同步到客户端范围圈。
- 范围圈为 `anim/ark_lambda_range.zip`，原生外半径150动画单位对应世界半径1，运行时AnimState按实际半径缩放。白色底图的细圆环、四向刻度及8段内短弧，常驻显示；按服务端rangestate染为淡蓝警戒、红色攻击、黄色资源不足，20秒一圈旋转、4秒一轮呼吸，透明度0至0.24。`ark_lambda_defense:SetResourceBlocked(bool)`保留额外资源阻断接口；每轮按当前combat.defaultdamage向上取整消耗龙门币，多目标共用一次扣费。遍历AllPlayers筛选攻击半径2倍内存活且不在limbo的非幽灵玩家，按整币平摊，个人余额不足的缺口由仍有余额的人继续平摊，余数随成功攻击轮数轮换；光环可支付性只统计本轮附近玩家总余额，真正攻击前按最新玩家资格和余额重新分摊，总余额不足或没有可用玩家时整轮不扣不打、显示黄色，背景与瞄准继续。Transform只旋转不缩放、DECOR+NOCLICK、无额外Bloom，自发光为0并遵循环境光照。本地范围环随entitysleep暂停更新并移除、entitywake恢复唯一定时任务，拆除或移除后的Cleanup永久停止。程序化源和离线预览保留在 `temp/lambda_command_center/range/`。
- 目前背景和瞄准idle沿用有限采样段循环，接缝与新建筑整体表现仍待实机验收。

## Steam 工坊介绍

中文和英文介绍分别直接编辑 `docs/workshop_description_zh-steam.txt` 和 `docs/workshop_description_en-steam.txt`，使用 Steam BBCode，并同步更新两种语言。

这两份文件是工坊介绍的唯一来源，不再维护对应 Markdown，也不要通过 Markdown 转换覆盖手工排版。

## 属性修改器总规则

1. 临时加成、装备加成、Buff 加成都应优先使用 modifier，而不是直接改写组件当前字段。
2. 每个 modifier 必须使用稳定且唯一的 key，移除效果时必须用同一个 key 清理。
3. 只有在设置基础值时才直接写原始属性；需要可叠加、可回滚、可与其他模组共存的效果时，一律走 modifier。
4. 本仓库的 combat_extension、health_extension 基于 modifier_installer 和 SourceModifierList 叠加，不要绕过这套管线。

## Combat 修改器

实现位置：modmain/combat_extension.lua

### 默认攻击力

combat.defaultdamage 已接入两套 modifier：

1. combat.defaultdamageaddmodifiers：加法叠加，默认值为 0
2. combat.defaultdamagemultmodifiers：乘法叠加，默认值为 1

计算顺序为：

((base defaultdamage) + 加法总和) * 乘法总和

推荐写法：

```lua
local combat = inst.components.combat
combat.defaultdamageaddmodifiers:SetModifier("my_mod_damage_bonus", 12)
combat.defaultdamagemultmodifiers:SetModifier("my_mod_damage_mult", 1.25)

combat.defaultdamageaddmodifiers:RemoveModifier("my_mod_damage_bonus")
combat.defaultdamagemultmodifiers:RemoveModifier("my_mod_damage_mult")
```

禁止做法：

1. 不要把 Buff、天赋、装备效果直接写进 combat.defaultdamage。
2. 不要为了临时增伤反复覆盖基础攻击力，这会和其他模组或本模组自己的加成互相踩写。

现有参考：scripts/components/ark_elite.lua 使用 combat.defaultdamageaddmodifiers 管理精英等级攻击奖励。

### 攻击速度

combat.attackspeedmodifiers 是攻速修改器容器，封装接口为：

1. combat:SetAttackSpeed(speed)
2. combat:GetAttackSpeed()

其中 SetAttackSpeed 会写入 key 为 ark_attack_speed 的 modifier，并同步动画时间轴与 replica。

如果你只是设置单一最终攻速，直接调用 combat:SetAttackSpeed(speed)。
如果你要做多来源叠加，优先扩展 attackspeedmodifiers，而不是直接改写 min_attack_period。

禁止做法：

1. 不要把临时攻速效果直接写进 combat.min_attack_period。
2. 不要在外部重复缩放动画时间轴，combat_extension 已处理攻击动画和客户端同步。

### 真实伤害

`combat.truedamagemultipliers` 管理多来源转换比例，默认值为 0；按剩余非真伤合并，两个 50% 来源合计转换 75%。它不同于 `weapon.truedamagemultipliers`，后者是武器固有真伤的乘法修改器。

combat:EnableTrueDamage(value) 用于启用真实伤害转换，value 取 0 到 1。
combat:DisableTrueDamage() 用于移除该效果。

它把普通伤害与非真伤特殊伤害按比例转换为 `true_damage`，保留已有真伤。转换发生在攻击方原版 `CalcDamage` 返回后，特殊伤害仍走原版结算。

推荐写法：

```lua
inst.components.combat:EnableTrueDamage(0.35)
inst.components.combat:DisableTrueDamage()
```

多技能或 Buff 并存时使用独立来源，效果结束只移除自己的来源：

```lua
local combat = inst.components.combat
combat.truedamagemultipliers:SetModifier("my_skill", 0.5)
combat.truedamagemultipliers:RemoveModifier("my_skill")
```

`DisableTrueDamage()` 仅移除 `EnableTrueDamage()` 写入的默认来源。

绕开 `CalcDamage` 的固定伤害入口需要显式调用公共方法，再把结果交给正常战斗结算：

```lua
local damage, spdamage = inst.components.combat:ConvertToTrueDamage(120)
target.components.combat:GetAttacked(inst, damage, nil, nil, spdamage)
```

不要对 `CalcDamage` 的结果再次调用此方法，部分比例会重复转换。直接调用 `GetAttacked` 不再隐式转换；已有武器真伤和显式 `spdamage.true_damage` 无需调用转换方法。

原版 `DoAttack` 的 `instancemult` 在 `CalcDamage` 后仅缩放普通伤害，提前转换的部分不会再乘它；自定义攻击若需整体倍率，应明确同时缩放普通和特殊伤害。真伤仍受装备类型抗性、生命层减伤、无敌和单击上限等原版规则影响。

## Health 修改器

实现位置：modmain/health_extension.lua

### 最大生命

health.maxhealth 已接入两套 modifier：

1. health.maxhealthaddmodifiers：加法叠加，默认值为 0
2. health.maxhealthmultmodifiers：乘法叠加，默认值为 1

推荐写法：

```lua
local health = inst.components.health
health.maxhealthaddmodifiers:SetModifier("my_mod_health_bonus", 50)
health.maxhealthmultmodifiers:SetModifier("my_mod_health_mult", 1.2)

health.maxhealthaddmodifiers:RemoveModifier("my_mod_health_bonus")
health.maxhealthmultmodifiers:RemoveModifier("my_mod_health_mult")
```

禁止做法：

1. 不要把常驻 Buff、装备词条、成长奖励直接写进 health.maxhealth。
2. 不要手动刷新 HUD；health_extension 已在 maxhealth modifier 变化时调用 ForceUpdateHUD(true)。

现有参考：scripts/components/ark_elite.lua 使用 health.maxhealthaddmodifiers 管理精英等级生命奖励。

### 最小生命

health.minhealth 已接入 health.minhealthmodifiers。

它按最大值规则合并，适合“不低于 X 点生命”的下限保护类效果：

```lua
inst.components.health.minhealthmodifiers:SetModifier("my_mod_min_health", 1)
inst.components.health.minhealthmodifiers:RemoveModifier("my_mod_min_health")
```

## Armor / 防御相关修改器

实现位置：modmain/armor_extension.lua

### 当前 armor_extension 提供的能力

armor_extension 目前扩展的是“免疫受击硬直”能力，不是通用防御数值 modifier 容器。

可用接口：

```lua
local armor = inst.components.armor
armor:SetImmuneStun(true)

if armor:IsImmuneStun() then
  -- 当前护甲可免受击硬直
end
```

该能力会在玩家受击时扫描已装备护甲，只要存在耐久大于 0 且 IsImmuneStun() 为 true 的护甲，就跳过受击硬直。

### 防御比例不要写到 armor 组件里

如果你要做“减伤比例”“防御加成”“伤害吸收”这类数值效果，当前项目内的正确入口仍然是 health.externalabsorbmodifiers，而不是 armor_extension。

推荐写法：

```lua
local health = inst.components.health
health.externalabsorbmodifiers:SetModifier(inst, 0.2, "my_mod_defense")
health.externalabsorbmodifiers:RemoveModifier(inst, "my_mod_defense")
```

现有参考：scripts/components/ark_elite.lua 使用 health.externalabsorbmodifiers:SetModifier(self.inst, bonus, "ark_elite_defense") 处理防御奖励。

禁止做法：

1. 不要假设 armor_extension 已经提供 armor.defensemodifiers 一类接口。
2. 不要为了减伤效果新增对 armor 当前字段的直接覆写，除非你先确认调用链和兼容性要求。

## 写法约定

1. modifier key 使用稳定字符串，例如 my_system_damage_bonus，不要用临时随机值。
2. 同一来源的 SetModifier 与 RemoveModifier 必须使用同一个 key。
3. source 型 modifier（例如 externalabsorbmodifiers）应保持 source 和 key 都稳定，便于覆盖与清理。
4. 需要新增属性修改器时，优先参考 modmain/modifier_installer.lua 的现有模式，不要另起一套叠加逻辑。
5. hook 类函数改动统一使用 ArkHookFunction / ArkUnhookFunction，不要直接覆写目标函数；需要插入逻辑时优先走 modmain/ark_function_hook.lua 提供的中间件链接口。

## Upvalue 搜索与替换

实现位置：modmain/ark_upvalue.lua

### 接口定位

当前公开接口：

1. `ArkFindUpvalue(fn, name, opts)`：返回 slot，对已定位的 upvalue 做多次读取、设置、替换时使用。
2. `ArkGetUpvalue(fn, name, opts)`：返回 `found, value, slot`，适合只读一次当前值。
3. `ArkSetUpvalue(fn, name, value, opts)`：返回 `found, oldValue, newValue, slot`。
4. `ArkReplaceUpvalue(fn, name, replacer, opts)`：返回 `found, oldValue, newValue, slot`，适合基于旧值生成新值。
5. `ArkUpdateUpvalue(...)`：`ArkReplaceUpvalue(...)` 的别名。

推荐理解：

1. `Find` 是定位接口。
2. `Get` 是便捷读取接口，本质上是 `Find` 的语法糖。
3. 真正的核心能力是 `Find`、`Set`、`Replace`；`Get` 只是为了让“一次性读值”更顺手。

### Find 与 Get 的区别

`ArkFindUpvalue` 返回的是 slot，表示“这个 upvalue 在哪里”。
slot 上自带：

1. `slot:Get()`
2. `slot:Set(newValue)`
3. `slot:Replace(replacer)`
4. `slot.owner`
5. `slot.index`
6. `slot.name`
7. `slot.value`
8. `slot.source`
9. `slot.depth`

`ArkGetUpvalue` 返回的是值，表示“我只想拿当前值，不关心槽位信息”。

如果后续还要继续操作同一个 upvalue，优先用 `Find`，避免每次都从根函数重新递归搜索。

### 用法示例

#### 只读取一次 upvalue

```lua
local found, value, slot = ArkGetUpvalue(targetfn, "some_upvalue")
if found then
  print("当前值", value)
  print("来源", slot.source)
end
```

#### 先定位，再多次读取或设置

```lua
local slot = ArkFindUpvalue(targetfn, "some_upvalue")
if slot then
  local oldValue = slot:Get()
  slot:Set("new value")
  print("旧值", oldValue)
  print("当前值", slot:Get())
end
```

这种写法适合一个 upvalue 需要被多次访问的场景。

#### 直接设置一次

```lua
local found, oldValue, newValue = ArkSetUpvalue(targetfn, "some_upvalue", 123)
if found then
  print("旧值", oldValue)
  print("新值", newValue)
end
```

如果只是一次性改值，用 `ArkSetUpvalue` 比先 `Find` 再 `Set` 更短。

#### 用 Replace 包裹函数型 upvalue

```lua
local found, oldFn, newFn = ArkReplaceUpvalue(targetfn, "DoSomething", function(previous, slot)
  if type(previous) ~= "function" then
    return previous
  end

  return function(...)
    print("before")
    local result = previous(...)
    print("after")
    return result
  end
end)

if found then
  print("替换成功")
end
```

`Replace` 适合做“基于旧值构造新值”的改写，尤其适合包装旧函数。

#### 连续多次替换同一个函数型 upvalue

```lua
ArkReplaceUpvalue(targetfn, "DoSomething", function(previous)
  return function(...)
    print("wrap 1")
    return previous(...)
  end
end)

ArkReplaceUpvalue(targetfn, "DoSomething", function(previous)
  return function(...)
    print("wrap 2")
    return previous(...)
  end
end)
```

当前实现会保留函数替换链。函数型 upvalue 被替换后，后续搜索仍然可以沿着替换链继续深入，不会出现“替换一次后就再也搜不到原路径里更深的 upvalue”的问题。

#### 按文件来源过滤

```lua
local slot = ArkFindUpvalue(targetfn, "some_upvalue", {
  file = "scripts/components"
})

if slot then
  print("命中来源", slot.source)
end
```

当同名 upvalue 可能出现在多个闭包层级或多个文件来源里时，优先加 `file` 过滤，避免误命中。

## 技能系统 State 管理

实现位置：scripts/components/ark_skill.lua

### 背景

DST 有存档读档机制，技能运行时数据（如闭包变量、局部状态）在读档后会丢失。
技能系统提供了 `state` 持久化存储，随 `data` 一起序列化，读档自动恢复。

### 接口

```lua
local skill = inst.components.ark_skill:GetSkill("my_skill_id")

skill:SetState("key", value)      -- 设置状态值
skill:GetState("key")             -- 获取状态值
skill:HasState("key")             -- 检查状态是否存在
skill:RemoveState("key")          -- 移除单个状态
skill:ClearState()                -- 清空所有状态
skill:GetAllState()               -- 获取状态副本（浅拷贝）
```

### 生命周期

| 时机 | state 行为 |
|------|-----------|
| 技能创建 | 初始化为空表 `{}` |
| 读档恢复 | 自动恢复（随 `data` 序列化） |
| `Lock()` | 清空（技能完全重置） |
| 技能移除 | 清空 |
| 其他 | **完全由开发者控制** |

### 推荐写法

**激活模式**：在 `OnActivate` 中手动清空，确保每次激活都是干净状态。

```lua
skill:SetOnActivate(function(skill, payload)
  skill:ClearState()
  skill:SetState("target", payload.target)
  skill:SetState("customData", someValue)
end)

skill:SetOnActivateEffect(function(skill, payload)
  local target = skill:GetState("target")  -- 正常激活或读档都能拿到
end)
```

**持续/引导模式**：在 Update 中累积状态，不清空。

```lua
skill:SetOnActivate(function(skill, payload)
  skill:ClearState()
  skill:SetState("elapsed", 0)
  skill:SetState("tickCount", 0)
end)

skill:SetOnUpdate(function(skill, dt)
  local elapsed = skill:GetState("elapsed") or 0
  skill:SetState("elapsed", elapsed + dt)
end)
```

**被动模式**：没有 Activate/Deactivate 边界，state 一直保留。

```lua
skill:SetOnEvent("onattack", function(skill, payload)
  local count = skill:GetState("attackCount") or 0
  skill:SetState("attackCount", count + 1)
end)
```

### 禁止做法

1. 不要用闭包变量或局部表保存技能运行状态，读档后会丢失。
2. 不要在 `OnActivate` 中忘记 `ClearState()`，可能导致上次激活的残留数据影响本次逻辑。
3. 不要直接读写 `skill.data.state`，始终使用 `SetState/GetState` 等封装接口。
