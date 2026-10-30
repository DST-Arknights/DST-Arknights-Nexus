-------------------------------------------------------------------
-- ark_flyer 飞行辅助
--  - 飞行动画 stategraph 钩子
--  - locomotor.RunForward 后维持飞行高度（移动会覆盖垂直马达速度）
-------------------------------------------------------------------

local MODES = require("ark_flyer_modes")

local function IsFlying(inst)
    -- 从 replica 判断：启用预测补偿后客户端读不到服务端组件。
    -- 副本先于组件加载，但普通角色没有该组件，故保留 nil 保护。
    local replica = inst.replica and inst.replica.ark_flyer
    return replica ~= nil and replica:IsFlying()
end

local function IsAirborne(inst)
    local replica = inst.replica and inst.replica.ark_flyer
    return replica ~= nil and replica:IsAirborne()
end

-- 冰面滑倒由 slipperyfeet 累积滑倒值触发，与物理碰撞无关。
-- 飞行时通过原接口清零，避免触发 feetslipped 或把累积值带到落地后。
AddComponentPostInit("slipperyfeet", function(cmp)
    ArkHookFunction(cmp, "SetCurrent", function(next, self, value)
        if IsAirborne(self.inst) then
            value = 0
        end
        return next(self, value)
    end)
end)

-- 有网络变量（replica：net_mode/net_percent）的组件必须在实体创建时就装好，
-- 否则引擎的副本同步会出问题（客户端 replica 依据服务端同步的 tag 建立）。
-- 故所有玩家在 postInit 后即内置 ark_flyer 组件。
AddPlayerPostInit(function(inst)
    if TheWorld.ismastersim and not inst.components.ark_flyer then
        inst:AddComponent("ark_flyer")
    end

    -- 原生 run_start/run 状态的时间线会调用 PlayFootstep。
    -- 飞行时直接拦截默认脚步音，结束飞行后仍恢复原处理逻辑。
    local old_footstepoverridefn = inst.footstepoverridefn
    if old_footstepoverridefn ~= nil then
        inst.footstepoverridefn = function(volume, ispredicted)
            if IsAirborne(inst) then
                return true
            end
            return old_footstepoverridefn(volume, ispredicted)
        end
    end
end)

local function RefreshClientFlyer(inst)
    local replica = inst.replica and inst.replica.ark_flyer
    if replica ~= nil then
        replica:RefreshClientUpdate()
    end
end

-- 移动会重新设置 SetMotorVel，垂直分量被覆盖导致高度掉落。
-- 飞行中的角色在 RunForward 后再次调用 DriveHeight 维持高度（参考伊蕾娜模组）。
AddComponentPostInit("locomotor", function(cmp)
    local RunForward = cmp.RunForward
    cmp.RunForward = function(self, ...)
        RunForward(self, ...)
        local flyer = self.inst.components and self.inst.components.ark_flyer
        if flyer and flyer:IsAirborne() then
            flyer:DriveHeight()
        else
            local replica = self.inst.replica and self.inst.replica.ark_flyer
            if replica and replica:IsAirborne() then
                replica:DriveHeight()
            end
        end
    end

    if not TheWorld.ismastersim then
        -- 预测开启时 locomotor 是动态创建的；此时服务端可能已经在飞行。
        cmp.inst:DoTaskInTime(0, RefreshClientFlyer)
    end
end)

local function IsActiveFlyer(inst)
    return IsFlying(inst)
        and not inst.sg.statemem.riding
        and not inst.sg.statemem.heavy
end

------------------------------------------------------------------------

local function HookState(sg, state_name, onenter_fn, onexit_fn)
    local state = sg.states[state_name]
    if not state then return end

    if onenter_fn then
        ArkHookFunction(state, "onenter", function(next, inst, ...)
            next(inst, ...)
            -- 原状态可能在 onenter 内跳转，不能再覆盖新状态的动画。
            if inst.sg.currentstate == state then
                onenter_fn(inst, ...)
            end
        end)
    end

    if onexit_fn then
        ArkHookFunction(state, "onexit", function(next, inst, ...)
            onexit_fn(inst, ...)
            return next(inst, ...)
        end)
    end
end

------------------------------------------------------------------------

local function OnModeChanged(inst, data)
    if data == nil or (data.oldmode ~= MODES.FLYING and data.mode ~= MODES.FLYING) then return end
    local sg = inst.sg
    if sg == nil or sg.currentstate == nil or sg:HasStateTag("busy")
        or sg.statemem.riding or sg.statemem.heavy then return end
    if not TheWorld.ismastersim and (sg.statemem.ark_flyer_idle_handoff
        or inst:HasTag("nopredict") or inst:HasTag("pausepredict")) then return end

    local name = sg.currentstate.name
    local flyanim = inst.AnimState:IsCurrentAnimation("ark_fly_loop")
    if name == "run" or name == "run_start" or name == "run_stop" then
        if data.mode == MODES.FLYING or flyanim then sg:GoToState(name) end
    elseif name == "idle" then
        if sg.statemem.ark_flyer_idle_tail_hash ~= nil
            and sg.statemem.ark_flyer_idle_tail_hash == inst.AnimState:GetCurrentAnimationHash()
            and not flyanim then
            -- 仅在切换模式恰逢动作收尾时等一次 animover，保留 pickup_pst 等尾巴。
            local mem = sg.statemem
            if mem.ark_flyer_mode_animover ~= nil then return end
            local onanimover
            onanimover = function()
                inst:RemoveEventCallback("animover", onanimover)
                mem.ark_flyer_mode_animover = nil
                inst:DoTaskInTime(0, function()
                    if inst:IsValid() and inst.sg == sg and sg.statemem == mem
                        and sg.currentstate.name == "idle"
                        and not mem.ark_flyer_idle_handoff
                        and not inst:HasTag("nopredict") and not inst:HasTag("pausepredict") then
                        sg:GoToState("idle")
                    end
                end)
            end
            mem.ark_flyer_mode_animover = onanimover
            inst:ListenForEvent("animover", onanimover)
        else
            sg:GoToState("idle")
        end
    end
end

local function ApplyHooks(sg)
    table.insert(sg.events, EventHandler("ark_flyer_modechanged", OnModeChanged))

    -- run_start：飞行时保持浮空循环
    HookState(sg, "run_start",
        function(inst)
            if not IsActiveFlyer(inst) then return end
            if not inst.AnimState:IsCurrentAnimation("ark_fly_loop") then
                inst.AnimState:PlayAnimation("ark_fly_loop", true)
            end
        end,
        nil
    )

    -- run：飞行时保持浮空循环，刷新 timeout
    HookState(sg, "run",
        function(inst)
            if not IsActiveFlyer(inst) then return end
            if not inst.AnimState:IsCurrentAnimation("ark_fly_loop") then
                inst.AnimState:PlayAnimation("ark_fly_loop", true)
            end
            inst.sg:SetTimeout(inst.AnimState:GetCurrentAnimationLength())
        end,
        nil
    )

    -- run_stop：飞行时保持浮空循环，不落地
    HookState(sg, "run_stop",
        function(inst)
            if not IsActiveFlyer(inst) then return end
            if not inst.AnimState:IsCurrentAnimation("ark_fly_loop") then
                inst.AnimState:PlayAnimation("ark_fly_loop", true)
            end
        end,
        nil
    )

    -- idle：只替换真正的待机动画，保留预测动作交接和动作收尾。
    HookState(sg, "idle",
        function(inst, pushanim)
            -- 客户端 noanim 表示预览已被服务端确认；cancel/nopredict/pausepredict
            -- 表示预测被服务端打断。这些分支必须继续由服务端接管动画。
            inst.sg.statemem.ark_flyer_idle_tail_hash = pushanim == true
                and inst.AnimState:GetCurrentAnimationHash() or nil
            inst.sg.statemem.ark_flyer_idle_handoff = not TheWorld.ismastersim and
                (pushanim == "noanim" or pushanim == "cancel"
                    or inst:HasTag("nopredict") or inst:HasTag("pausepredict"))
            if not IsActiveFlyer(inst) or inst.sg.statemem.ark_flyer_idle_handoff then return end
            if pushanim then
                -- idle(true) 要把循环接在 pickup_pst 等收尾动画之后。
                inst.AnimState:PushAnimation("ark_fly_loop", true)
            elseif not inst.AnimState:IsCurrentAnimation("ark_fly_loop") then
                inst.AnimState:PlayAnimation("ark_fly_loop", true)
            end
        end,
        function(inst)
            local mem = inst.sg.statemem
            if mem.ark_flyer_mode_animover ~= nil then
                inst:RemoveEventCallback("animover", mem.ark_flyer_mode_animover)
                mem.ark_flyer_mode_animover = nil
            end
        end
    )

    -- funnyidle：飞行时跳过
    HookState(sg, "funnyidle",
        function(inst)
            if IsActiveFlyer(inst) then
                inst.sg:GoToState("idle")
            end
        end,
        nil
    )
end

------------------------------------------------------------------------

AddStategraphPostInit("wilson",        ApplyHooks)
AddStategraphPostInit("wilson_client", ApplyHooks)
