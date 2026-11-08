local Position = {}

function Position.GetHitSymbol(target)
    local combat = target.components.combat
    return combat ~= nil and combat.hiteffectsymbol or "marker"
end

function Position.GetWorldPosition(target, symbol)
    local x, y, z = target.Transform:GetWorldPosition()
    local anim = target.AnimState
    if anim ~= nil then
        -- Use the species' native combat attachment, including animation motion.
        local hitx, hity, hitz, success = anim:GetSymbolPosition(symbol or "marker")
        if success and hity > y + 0.05 then
            return hitx, hity, hitz
        end

        -- Visual bounds use animation coordinates. Their span remains usable
        -- when the vertical axis points downward or the pivot is at the feet.
        local _, y1, _, y2 = anim:GetVisualBB()
        if type(y1) == "number" and type(y2) == "number" then
            local height = math.abs(y2 - y1)
            if height > 0 and height < math.huge then
                return x, y + height * 0.5, z
            end
        end
    end
    return x, y + 0.5, z
end

return Position
