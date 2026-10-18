local Rescue = require("sympathetic_pendant_rescue")

local SympatheticPendantData = Class(function(self, inst)
  self.inst = inst
  self.resonance_data = {}
  -- Central scheduling prevents every player's proximity task from charging
  -- the same donor independently. Only live players on this shard participate.
  self.rescue_task = inst:DoPeriodicTask(0.5, function() Rescue.Update(AllPlayers) end)
end)

function SympatheticPendantData:OnRemoveFromEntity()
  if self.rescue_task ~= nil then
    self.rescue_task:Cancel()
    self.rescue_task = nil
  end
end

local function NormalizeGuidPair(guidA, guidB)
  if guidA < guidB then
    return guidA, guidB
  else
    return guidB, guidA
  end
end

function SympatheticPendantData:GetPairData(guidA, guidB, useridA, useridB)
  local first, second = NormalizeGuidPair(guidA, guidB)

  if not self.resonance_data[first] then
    self.resonance_data[first] = {}
  end
  if not self.resonance_data[first][second] then
    self.resonance_data[first][second] = { resonance = 0 }
  end
  local data = self.resonance_data[first][second]
  if useridA ~= nil and useridB ~= nil then
    local userfirst, usersecond = NormalizeGuidPair(useridA, useridB)
    -- Keep legacy progress, but stamp future saves with the pair's identities
    -- so a reused GUID cannot grant full resonance to an unrelated player.
    if data.userid_first ~= nil and (data.userid_first ~= userfirst or data.userid_second ~= usersecond) then
      data = { resonance = 0 }
      self.resonance_data[first][second] = data
    end
    data.userid_first, data.userid_second = userfirst, usersecond
  end
  return data
end

function SympatheticPendantData:OnSave()
  if next(self.resonance_data) == nil then
    return nil
  end
  return {
    resonance_data = self.resonance_data
  }
end

function SympatheticPendantData:OnLoad(data)
  if data and data.resonance_data then
    self.resonance_data = data.resonance_data
  end
end

return SympatheticPendantData
