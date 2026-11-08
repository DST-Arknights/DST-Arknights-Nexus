-- Keep the normal combat event and every other stategraph reaction. Only the
-- common hit states entered by this tower's attacked event are suppressed.
local function Prepare(target)
    local sg = target.sg
    if sg == nil or sg._ark_lambda_no_stagger then
        return
    end
    sg._ark_lambda_no_stagger = true
    local suppress = false

    ArkHookFunction(sg, "GoToState", function(nextfn, self, state, ...)
        if suppress and (state == "hit" or state == "hit_stunlock") then
            return
        end
        return nextfn(self, state, ...)
    end)
    ArkHookFunction(sg, "HandleEvent", function(nextfn, self, event, data, ...)
        local previous = suppress
        local attacker = data ~= nil and data.attacker or nil
        suppress = event == "attacked" and attacker ~= nil
            and attacker.prefab == "ark_lambda_command_center"
        -- Restore the flag even if another stategraph handler fails or recurses.
        local result = { pcall(nextfn, self, event, data, ...) }
        suppress = previous
        if not result[1] then
            error(result[2], 0)
        end
        return unpack(result, 2)
    end)
end

return { Prepare = Prepare }
