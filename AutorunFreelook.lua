-- Autorun Freelook
-- Look around freely during autorun and steer only when you want to, in WoW: Forever's built-in
-- gamepad mode. Holding the steer button works like holding the right mouse button on keyboard.
--
-- * Autorun is detected as moving out of combat with an untouched left stick. The game's own
--   autorun button (L3) still starts and stops it: addons cannot start or stop autorun themselves.
-- * During autorun the left stick's movement is switched off through the gamepad config API, so a
--   stray touch does not cancel autorun. Stopping, combat, logout or /reload give it back.
-- * During autorun, holding the steer button (R2 by default) makes the character turn with the
--   camera, so the right stick steers. Releasing it gives back free look.
-- Outside autorun the addon changes nothing.

local ADDON_NAME = ...

local CVAR_TURN = "GamePadTurnWithCamera"
local STEER_VALUE = "2"      -- "Turn Player With Camera: always", only while the steer button is held
local LOCKED_DEADZONE = 0.99 -- Movement stick deadzone while locked: practically no movement
local POLL_SECONDS = 0.03
local ENGAGE_AFTER = 0.15    -- moving this long with an untouched left stick counts as autorun
local IDLE_LENGTH = 0.2      -- left stick deflection treated as untouched
local AXIS_PRESSED = 0.5     -- trigger travel that counts as held
local LEARN_SECONDS = 3
local GLOBAL_CONFIG_ID = {}  -- the gamepad config that applies to every device

-- Mapped gamepad buttons, in the order the game lists them in WTF/GamePadConfig_Default.json.
-- Confirmed in game on a DualSense: 11 = L3, 15 = L2, 16 = R2.
local BUTTON_L2, BUTTON_R2 = 15, 16
local BUTTON_NAMES = {
  "D-pad Up", "D-pad Right", "D-pad Down", "D-pad Left",
  "A / Cross", "B / Circle", "X / Square", "Y / Triangle", "Face 5", "Face 6",
  "L3", "R3", "LB / L1", "RB / R1", "LT / L2", "RT / R2",
}

local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = (getMetadata and getMetadata(ADDON_NAME, "Version")) or ""

local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar
-- A temporary CVar is never saved and is removed cleanly, so the player's own setting stays untouched.
local useTempCVar = C_CVar and C_CVar.SetTempCVar and C_CVar.RemoveTempCVar

local db
local autorun, steering, locked = false, false, false
local idleTime = 0
local learning
local options -- settings panel, built on PLAYER_LOGIN

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff4fc1b0Autorun Freelook|r " .. text)
end

local function note(text)
  if db and db.debug then
    say(text)
  end
end

local function refreshOptions()
  if options and options.refresh then
    options.refresh()
  end
end

local function setCVarChecked(name, value)
  if getCVar(name) ~= value then
    pcall(setCVar, name, value)
  end
  return getCVar(name) == value
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = deepCopy(v)
  end
  return copy
end

local function mappedState()
  if not (C_GamePad and C_GamePad.GetActiveDeviceID and C_GamePad.GetDeviceMappedState) then
    return nil
  end
  local deviceID = C_GamePad.GetActiveDeviceID()
  if not deviceID then
    return nil
  end
  return C_GamePad.GetDeviceMappedState(deviceID)
end

local function leftStick(state)
  local stick = state and state.sticks and state.sticks[1]
  if stick and stick.x and stick.y then
    return stick.x, stick.y
  end
  local axes = state and state.axes
  if axes and axes[1] and axes[2] then
    return axes[1], axes[2]
  end
  return nil
end

local function holdActive(state)
  if not state then
    return false
  end
  if db.holdIndex and state.buttons and state.buttons[db.holdIndex] then
    return true
  end
  if db.holdAxis and state.axes and (state.axes[db.holdAxis] or 0) > AXIS_PRESSED then
    return true
  end
  return false
end

local function holdName()
  if db.holdIndex then
    return BUTTON_NAMES[db.holdIndex] or ("button " .. db.holdIndex)
  elseif db.holdAxis then
    return "axis " .. db.holdAxis
  end
  return "none"
end

local function isMoving()
  if IsPlayerMoving then
    return IsPlayerMoving()
  end
  return (GetUnitSpeed("player") or 0) > 0
end

-- Steering ----------------------------------------------------------------------------------

local function startSteering()
  if useTempCVar then
    if pcall(C_CVar.SetTempCVar, CVAR_TURN, STEER_VALUE) then
      steering = true
      note("steering")
    end
    return
  end
  -- Fallback for clients without temporary CVars: remember the player's value and put it back later.
  local current = getCVar(CVAR_TURN)
  if current ~= STEER_VALUE then
    db.free = current
  end
  if setCVarChecked(CVAR_TURN, STEER_VALUE) then
    steering = true
    db.steering = true
    note("steering")
  end
end

local function stopSteering()
  if useTempCVar then
    if steering then
      pcall(C_CVar.RemoveTempCVar, CVAR_TURN)
      steering = false
      note("free look")
    end
    return
  end
  if not (steering or db.steering) then
    return
  end
  setCVarChecked(CVAR_TURN, db.free or "0")
  steering = false
  db.steering = false
  note("free look")
end

-- Left stick lock ---------------------------------------------------------------------------

local function configApiReady()
  return C_GamePad and C_GamePad.GetConfig and C_GamePad.SetConfig and C_GamePad.ApplyConfigs
end

local function lockStick()
  if not configApiReady() then
    note("left stick lock unavailable: no gamepad config API")
    return
  end
  local ok, config = pcall(C_GamePad.GetConfig, GLOBAL_CONFIG_ID)
  if not ok or type(config) ~= "table" then
    note("left stick lock unavailable: could not read the gamepad config")
    return
  end
  local original = deepCopy(config)
  local found = false
  for _, stick in ipairs(config.stickConfigs or {}) do
    if stick.stick == "Movement" then
      stick.deadzone, stick.deadzoneX, stick.deadzoneY = LOCKED_DEADZONE, LOCKED_DEADZONE, LOCKED_DEADZONE
      found = true
    end
  end
  if not found then
    note("left stick lock unavailable: no Movement stick in the gamepad config")
    return
  end
  db.originalConfig = original
  if not (pcall(C_GamePad.SetConfig, config) and pcall(C_GamePad.ApplyConfigs)) then
    pcall(C_GamePad.SetConfig, original)
    pcall(C_GamePad.ApplyConfigs)
    note("left stick lock unavailable: the gamepad config was not applied")
    return
  end
  locked = true
  db.locked = true
  note("left stick locked")
end

local function unlockStick(reason)
  if not (locked or db.locked) then
    return
  end
  if db.originalConfig and configApiReady() then
    pcall(C_GamePad.SetConfig, db.originalConfig)
    pcall(C_GamePad.ApplyConfigs)
  end
  locked = false
  db.locked = false
  note("left stick unlocked (" .. reason .. ")")
end

-- Autorun state -----------------------------------------------------------------------------

local function enterAutorun()
  autorun = true
  note("autorun detected")
  if db.stickLock then
    lockStick()
  end
end

local function leaveAutorun(reason)
  if not autorun then
    return
  end
  autorun = false
  idleTime = 0
  stopSteering()
  unlockStick(reason)
  note("autorun ended (" .. reason .. ")")
end

-- Settings changes --------------------------------------------------------------------------

local function setEnabled(value)
  db.enabled = value
  if not value then
    leaveAutorun("turned off")
    stopSteering()
    unlockStick("turned off")
  end
  say(value and "on" or "off")
  refreshOptions()
end

local function setStickLock(value)
  db.stickLock = value
  if not value then
    unlockStick("lock turned off")
  end
  say("left stick lock during autorun " .. (value and "on" or "off"))
  refreshOptions()
end

local function setHoldButton(index)
  db.holdIndex, db.holdAxis = index, nil
  say("steer button: " .. holdName())
  refreshOptions()
end

-- Learning another steer button -------------------------------------------------------------

local function snapshot(state)
  local buttons, axes = {}, {}
  for i, down in pairs(state.buttons or {}) do
    if down then
      buttons[i] = true
    end
  end
  for i, value in pairs(state.axes or {}) do
    if value > AXIS_PRESSED then
      axes[i] = true
    end
  end
  return buttons, axes
end

local function startLearning()
  local state = mappedState()
  if not state then
    say("no gamepad found")
    return
  end
  local buttons, axes = snapshot(state)
  learning = { left = LEARN_SECONDS, buttons = {}, axes = {}, baseButtons = buttons, baseAxes = axes }
  say("hold the button you want to steer with for 3 seconds")
end

local function bestKey(counts)
  local best, bestCount = nil, 0
  for i, count in pairs(counts) do
    if count > bestCount then
      best, bestCount = i, count
    end
  end
  return best
end

local function finishLearning()
  local button = bestKey(learning.buttons)
  local axis = bestKey(learning.axes)
  learning = nil
  if button then
    setHoldButton(button)
  elseif axis then
    db.holdIndex, db.holdAxis = nil, axis
    say("steer button: " .. holdName())
    refreshOptions()
  else
    say("no button detected, try again: /afl learn")
  end
end

-- Main loop ---------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local pending = 0

frame:SetScript("OnUpdate", function(_, elapsed)
  pending = pending + elapsed
  if pending < POLL_SECONDS then
    return
  end
  local dt = pending
  pending = 0
  if not db then
    return
  end

  local state = mappedState()

  if learning then
    if state then
      local buttons, axes = snapshot(state)
      for i in pairs(buttons) do
        if not learning.baseButtons[i] then
          learning.buttons[i] = (learning.buttons[i] or 0) + 1
        end
      end
      for i in pairs(axes) do
        if not learning.baseAxes[i] then
          learning.axes[i] = (learning.axes[i] or 0) + 1
        end
      end
    end
    learning.left = learning.left - dt
    if learning.left <= 0 then
      finishLearning()
    end
    return
  end

  if not db.enabled then
    return
  end

  local moving = isMoving()
  -- Flight paths and vehicles move you without the left stick too; they are not autorun.
  local passenger = (UnitOnTaxi and UnitOnTaxi("player")) or (UnitInVehicle and UnitInVehicle("player"))
  if autorun then
    if not moving or passenger then
      leaveAutorun(passenger and "passenger" or "stopped")
    end
  elseif moving and not passenger and not InCombatLockdown() then
    local x, y = leftStick(state)
    if x and math.sqrt(x * x + y * y) < IDLE_LENGTH then
      idleTime = idleTime + dt
      if idleTime >= ENGAGE_AFTER then
        idleTime = 0
        enterAutorun()
      end
    else
      idleTime = 0
    end
  else
    idleTime = 0
  end

  local held = autorun and holdActive(state)
  if held and not steering then
    startSteering()
  elseif not held and steering then
    stopSteering()
  end
end)

-- Options panel (Options > AddOns > Autorun Freelook) ---------------------------------------

local function buildOptions()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
    return
  end
  local panel = CreateFrame("Frame")
  panel.name = "Autorun Freelook"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Autorun Freelook " .. VERSION)

  local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  intro:SetJustifyH("LEFT")
  intro:SetText("During autorun, the right stick looks around freely. Hold the steer button to change "
    .. "direction with it. Start and stop autorun with your usual autorun button (L3).")

  local boxes = {}
  local function addCheckbox(label, tooltip, anchor, get, set)
    local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    local text = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", box, "RIGHT", 4, 1)
    text:SetText(label)
    box:SetScript("OnClick", function(self)
      set(self:GetChecked() and true or false)
    end)
    box:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(label, 1, 1, 1)
      GameTooltip:AddLine(tooltip, nil, nil, nil, true)
      GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    box.get = get
    boxes[#boxes + 1] = box
    return box
  end

  local enabledBox = addCheckbox("Enable Autorun Freelook",
    "Turn the whole addon on or off.",
    intro, function() return db.enabled end, setEnabled)
  local lockBox = addCheckbox("Lock the left stick during autorun",
    "A stray touch on the left stick no longer cancels autorun. Stop with your autorun button. "
      .. "The lock is lifted when you stop, enter combat, log out or reload.",
    enabledBox, function() return db.stickLock end, setStickLock)
  local debugBox = addCheckbox("Show debug messages",
    "Print what the addon is doing in the chat window.",
    lockBox, function() return db.debug end, function(value)
      db.debug = value
    end)

  local buttonLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  buttonLabel:SetPoint("TOPLEFT", debugBox, "BOTTOMLEFT", 4, -18)
  buttonLabel:SetText("Steer button:")
  local current = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  current:SetPoint("LEFT", buttonLabel, "RIGHT", 6, 0)

  local function addButton(text, width, onClick)
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
  end
  local useR2 = addButton("Use R2", 100, function() setHoldButton(BUTTON_R2) end)
  useR2:SetPoint("TOPLEFT", buttonLabel, "BOTTOMLEFT", 0, -8)
  local useL2 = addButton("Use L2", 100, function() setHoldButton(BUTTON_L2) end)
  useL2:SetPoint("LEFT", useR2, "RIGHT", 8, 0)
  local learn = addButton("Learn another button", 180, startLearning)
  learn:SetPoint("LEFT", useL2, "RIGHT", 8, 0)

  local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", useR2, "BOTTOMLEFT", 0, -10)
  hint:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText("R2 or L2 work best. L3 stops autorun when pressed, L1 and R1 turn the right stick into "
    .. "targeting, and D-pad or face buttons use abilities.")

  panel.refresh = function()
    for _, box in ipairs(boxes) do
      box:SetChecked(box.get() and true or false)
    end
    current:SetText(holdName())
  end
  panel:SetScript("OnShow", panel.refresh)

  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
  panel.category = category
  options = panel
end

local function openOptions()
  local category = options and options.category
  if not (category and Settings and Settings.OpenToCategory) then
    say("the options panel is not available on this client, use the /afl commands")
    return
  end
  if not pcall(Settings.OpenToCategory, category:GetID()) then
    pcall(Settings.OpenToCategory, category)
  end
end

-- Events ------------------------------------------------------------------------------------

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    AutorunFreelookDB = AutorunFreelookDB or {}
    db = AutorunFreelookDB
    if db.enabled == nil then
      db.enabled = true
    end
    if db.stickLock == nil then
      db.stickLock = true
    end
    if db.holdIndex == nil and db.holdAxis == nil then
      db.holdIndex = BUTTON_R2
    end
  elseif event == "PLAYER_LOGIN" then
    -- Logged out, reloaded or crashed mid-way: give back free look and the left stick.
    stopSteering()
    unlockStick("login")
    local ok, err = pcall(buildOptions)
    if not ok then
      note("options panel unavailable: " .. tostring(err))
    end
    if not db.welcomed then
      say("during autorun, hold R2 to steer with the right stick and release it to look around. Type /afl for options.")
      db.welcomed = true
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    -- Never keep the left stick locked or steering forced in combat.
    leaveAutorun("combat")
  elseif event == "PLAYER_LOGOUT" then
    stopSteering()
    unlockStick("logout")
  end
end)

-- Slash commands ----------------------------------------------------------------------------

SLASH_AUTORUNFREELOOK1 = "/afl"
SLASH_AUTORUNFREELOOK2 = "/autorunfreelook"
SlashCmdList.AUTORUNFREELOOK = function(input)
  local cmd, arg = strtrim((input or ""):lower()):match("^(%S*)%s*(.-)$")
  if cmd == "on" then
    setEnabled(true)
  elseif cmd == "off" then
    setEnabled(false)
  elseif cmd == "lock" then
    setStickLock(arg ~= "off")
  elseif cmd == "button" then
    if arg == "r2" then
      setHoldButton(BUTTON_R2)
    elseif arg == "l2" then
      setHoldButton(BUTTON_L2)
    else
      say("use /afl button r2, /afl button l2 or /afl learn")
    end
  elseif cmd == "learn" then
    startLearning()
  elseif cmd == "config" or cmd == "options" then
    openOptions()
  elseif cmd == "debug" then
    db.debug = not db.debug
    say("debug messages " .. (db.debug and "on" or "off"))
    refreshOptions()
  else
    say(string.format("%s | steer button: %s | left stick lock: %s | autorun: %s%s | Turn Player With Camera: %s",
      db.enabled and "on" or "off", holdName(), db.stickLock and "on" or "off",
      autorun and "yes" or "no", locked and " (locked)" or "", tostring(getCVar(CVAR_TURN))))
    say("commands: /afl on, off, lock on|off, button r2|l2, learn, config, debug")
  end
end
