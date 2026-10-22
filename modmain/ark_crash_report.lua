-- Native Lua-crash reporting only. No timers that deliberately cause errors.
-- Maintainer switch; deliberately kept out of the mod configuration screen.
local CRASH_REPORTS_ENABLED = true

-- Local development copies never install the reporter, even when enabled here.
if not CRASH_REPORTS_ENABLED or type(modname) ~= "string"
  or not modname:match("^workshop%-%d+$") then
  return
end

local REPORT_ENDPOINT = "https://dst.signalspectra.com/api/v1/crashes"
-- The native third argument controls connection and low-speed waits, not retries.
local REPORT_NETWORK_WAIT_SECONDS = 30
local MAX_URL_BYTES = 14000
local MAX_PLAYERS = 128
local SNAPSHOT_SECONDS = 30
local MOD_VERSION = modinfo and modinfo.version or "unknown"
local state = { side = "client", world = "unknown", attempted = false }

local function SafeMethod(object, name, ...)
  if object == nil or type(object[name]) ~= "function" then
    return nil
  end
  local ok, result = pcall(object[name], object, ...)
  if ok then
    return result
  end
  return nil
end

local function Clean(text, limit)
  if type(text) ~= "string" then
    return ""
  end
  return text:gsub("[%z\1-\31\127]", ""):sub(1, limit)
end

local function ShortName(text)
  text = Clean(text, 4096)
  -- The native helper counts Unicode codepoints, rather than UTF-8 bytes.
  if type(string.utf8sub) == "function" then
    local ok, value = pcall(string.utf8sub, text, 1, 8)
    if ok and type(value) == "string" then
      return value
    end
  end
  -- Missing/broken native UTF-8 helper: omit non-ASCII names safely.
  return text:find("[\128-\255]") and "" or text:sub(1, 8)
end

local function Quote(text)
  return '"' .. text:gsub('[%z\1-\31\\"]', function(character)
    return string.format("\\u%04x", string.byte(character))
  end) .. '"'
end

local function Encode(text)
  return (text:gsub("([^A-Za-z0-9%-_%.~])", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

local function Person(id, name)
  id = Clean(id, 100)
  return id ~= "" and { id = id, name = ShortName(name) } or nil
end

local function PersonJSON(person, omit_name)
  return '{"id":' .. Quote(person.id) .. ',"name":'
    .. Quote(omit_name and "" or person.name) .. '}'
end

local function PlayersJSON(players, omit_names)
  local values = {}
  for _, player in ipairs(players) do
    values[#values + 1] = PersonJSON(player, omit_names)
  end
  return "[" .. table.concat(values, ",") .. "]"
end

local function GetSide()
  return SafeMethod(TheNet, "GetIsMasterSimulation") == true
    or SafeMethod(TheNet, "GetIsServer") == true
    or SafeMethod(TheNet, "IsDedicated") == true
end

local function GetRoster()
  if type(GetPlayerClientTable) ~= "function" then
    return nil
  end
  local ok, clients = pcall(GetPlayerClientTable)
  if not ok or type(clients) ~= "table" then
    return nil
  end
  local players, seen = {}, {}
  for _, client in ipairs(clients) do
    local player = type(client) == "table" and Person(client.userid, client.name) or nil
    if player ~= nil and not seen[player.id] then
      seen[player.id] = true
      players[#players + 1] = player
      if #players >= MAX_PLAYERS then
        break
      end
    end
  end
  table.sort(players, function(left, right) return left.id < right.id end)
  return players
end

local function BuildURL()
  local base = REPORT_ENDPOINT .. "?version=" .. Encode(Clean(MOD_VERSION, 80))
    .. "&side=" .. state.side .. "&world=" .. state.world
  if state.side == "client" and state.client_player ~= nil then
    return base .. "&client_player=" .. Encode(PersonJSON(state.client_player))
  end
  if state.side == "server" and state.players ~= nil then
    local players = "&players=" .. Encode(PlayersJSON(state.players))
    if #base + #players > MAX_URL_BYTES then
      -- Large modded servers retain every ID before optional display names.
      players = "&players=" .. Encode(PlayersJSON(state.players, true))
    end
    if #base + #players <= MAX_URL_BYTES then
      return base .. players
    end
  end
  return base
end

local function RefreshSnapshot()
  state.side = GetSide() and "server" or "client"
  local world = TheWorld
  if world ~= nil then
    if SafeMethod(world, "HasTag", "cave") == true or world.prefab == "cave" then
      state.world = "cave"
    elseif SafeMethod(world, "HasTag", "forest") == true or world.prefab == "forest" then
      state.world = "forest"
    else
      state.world = "unknown"
    end
  else
    state.world = "unknown"
  end
  if state.side == "server" then
    state.players = GetRoster() or state.players
    state.client_player = nil
  else
    state.players = nil
    local player = ThePlayer
    local userid = SafeMethod(TheNet, "GetUserID")
    local name = SafeMethod(TheNet, "GetLocalUserName")
    if player ~= nil then
      userid = player.userid or userid
      name = player.name or name
    end
    state.client_player = Person(userid, name)
  end
  state.url = BuildURL()
end

local function SafeRefresh()
  -- A failed snapshot keeps the previous complete URL and cannot break gameplay.
  pcall(RefreshSnapshot)
end

local function IsEnabled()
  return SafeMethod(TheSim, "GetDataCollectionSetting") == true
    -- Launch-time restrictions (including -offline) are separate from the
    -- saved privacy preference checked above. Honor both native gates.
    and SafeMethod(TheSim, "IsDataCollectionDisabled") == false
end

local function OnErrorWidget(_, title)
  -- Hash warnings also use this class; they are not native Lua crashes.
  local mainscreen = STRINGS and STRINGS.UI and STRINGS.UI.MAINSCREEN
  if mainscreen and title == mainscreen.BAD_HASHES_TITLE then
    return
  end
  if state.attempted or not IsEnabled() or state.url == nil
    or TheSim == nil or type(TheSim.SendCrashReportTo) ~= "function" then
    return
  end
  state.attempted = true
  -- The native API itself checks for a LOCAL native crash before reading a log.
  -- A remote server's disconnection dialog cannot turn this client into a crash.
  -- No scheduling, retries, file writes or UI changes in the failure path.
  pcall(function()
    TheSim:SendCrashReportTo(state.url, function(_, success, status)
      -- Never print URLs, player identities, response bodies or raw logs.
      local accepted = success == true and type(status) == "number"
        and status >= 200 and status < 300
      pcall(print, "[NexusCrashReport] " .. (accepted and "accepted" or "not_accepted"))
    end, REPORT_NETWORK_WAIT_SECONDS)
  end)
end

SafeRefresh()
AddClassPostConstruct("widgets/scripterrorwidget", function(...)
  -- The original constructor has already completed. Never hide its error screen.
  pcall(OnErrorWidget, ...)
end)

AddPrefabPostInit("world", function(world)
  SafeRefresh()
  local function OnWorldRemoved()
    if state.timer ~= nil then
      state.timer:Cancel()
      state.timer = nil
    end
    state.players = nil
    state.client_player = nil
    state.world = "unknown"
    state.url = BuildURL()
  end
  world:ListenForEvent("playeractivated", SafeRefresh)
  world:ListenForEvent("playerdeactivated", SafeRefresh)
  if state.side == "server" then
    world:ListenForEvent("ms_clientauthenticationcomplete", SafeRefresh)
    world:ListenForEvent("ms_clientdisconnected", SafeRefresh)
    world:ListenForEvent("ms_playerjoined", SafeRefresh)
    world:ListenForEvent("ms_playerleft", SafeRefresh)
  end
  world:ListenForEvent("onremove", OnWorldRemoved)
  -- Names/client tables may change without spawning a player entity. A low-rate
  -- snapshot is enough; reporting after a crash never waits for this task.
  state.timer = world:DoPeriodicTask(SNAPSHOT_SECONDS, SafeRefresh)
end)
