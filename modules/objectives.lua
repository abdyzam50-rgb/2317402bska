-- objectives.lua
-- Reactive story-progression driver.
-- Hooks every TextLabel inside BackGui; when the game's objective text
-- changes to match a known entry in ObjectiveConfig, it auto-teleports
-- through the configured waypoint sequence.
-- Level data is sourced from _G.StarterLevel, written by battle.lua's EVT hooks.
--
-- Waypoint types:
--   { type = "workspaceName", name = "PartName" }
--   { type = "idValue",       id = "SomeId", childName = "Main" }
--   { type = "gateMarquee",   text = "DestinationName" }
--   { type = "levelGate",     minLevel = N }   ← blocks until level met,
--       re-anchors player to last position every 15s if they drift (blackout)
--   { type = "starterPick" }  ← clicks through starter selection screen via VIM

local Objectives = {}

local Players             = game:GetService("Players")
local Workspace           = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────────────────────────────────────
-- Objective config
-- ─────────────────────────────────────────────────────────────────────────────

local ObjectiveConfig = {
    {
        match = "at the Dig Site",
        sequence = {
            { type = "workspaceName", name = "TriggerCaveCutscene" },
        },
    },
    {
        match = "at the Laboratory",
        sequence = {
            { type = "idValue",    id = "Laboratory", childName = "Main" },
            { type = "starterPick" },
        },
    },
    {
        -- Teleport to Gale Forest, grind to lv 12 there, then trigger Duskit
        match = "Gale Forest",
        sequence = {
            { type = "workspaceName", name = "Exit" },
            { type = "gateMarquee",   text = "Cheshma Town" },
            { type = "workspaceName", name = "SchoolSceneTrigger" },
            { type = "levelGate",     minLevel = 12 },
            { type = "workspaceName", name = "DuskitCutsceneTrigger" },
        },
    },
    {
        -- Fallback: if script starts mid-story at this point
        match = "behind Duskit",
        minLevel = 12,
        sequence = {
            { type = "workspaceName", name = "DuskitCutsceneTrigger" },
        },
    },
    {
        -- Teleport to Route 3, grind to lv 20 there, then done
        match = "Silvent City Battle",
        sequence = {
            { type = "gateMarquee", text = "Route 3" },
            { type = "levelGate",   minLevel = 20 },
        },
    },
}

local DEFAULT_WAYPOINT_DELAY = 5

local function currentLevel()
    return _G.StarterLevel or 5
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function containsSubstring(haystack, needle)
    if not haystack or not needle then return false end
    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

local function getCFrameFromInstance(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.CFrame
    elseif inst:IsA("Model") then return inst:GetPivot() end
    return nil
end

local function getHRP()
    local char = localPlayer.Character or localPlayer.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Waypoint resolvers
-- ─────────────────────────────────────────────────────────────────────────────

local Resolvers = {}

Resolvers.workspaceName = function(wp)
    local inst = Workspace:FindFirstChild(wp.name, true)
    if not inst then warn("[Objectives] workspaceName: not found:", wp.name) return nil end
    return getCFrameFromInstance(inst)
end

Resolvers.idValue = function(wp)
    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc:IsA("StringValue") and desc.Name == "id" and containsSubstring(desc.Value, wp.id) then
            local target = desc.Parent and desc.Parent:FindFirstChild(wp.childName)
            if target then return getCFrameFromInstance(target) end
            warn("[Objectives] idValue: id found but no child:", wp.childName)
            return nil
        end
    end
    warn("[Objectives] idValue: no StringValue 'id' containing:", wp.id)
    return nil
end

Resolvers.gateMarquee = function(wp)
    for _, marquee in ipairs(Workspace:GetDescendants()) do
        if marquee.Name == "Marquee" then
            local mText = marquee:FindFirstChild("MText")
            if mText and mText:IsA("StringValue") and containsSubstring(mText.Value, wp.text) then
                if not marquee:IsA("BasePart") then
                    warn("[Objectives] gateMarquee: Marquee is not a BasePart:", marquee:GetFullName())
                    return nil
                end
                return CFrame.new(marquee.Position - Vector3.new(0, 10, 0))
            end
        end
    end
    warn("[Objectives] gateMarquee: no Marquee with MText containing:", wp.text)
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Starter picker — waits for 6s of dialogue silence, pauses the dialogue
-- skipper, clicks through the selection screen (1s between each step),
-- then resumes the skipper so battle + post-battle dialogue auto-clear.
-- ─────────────────────────────────────────────────────────────────────────────

local STARTER_ARROW_X,   STARTER_ARROW_Y   = 206, 330  -- 272 + 58
local STARTER_SELECT_X,  STARTER_SELECT_Y  = 672, 503  -- 445 + 58
local STARTER_CONFIRM_X, STARTER_CONFIRM_Y = 824, 252  -- 194 + 58
local STARTER_COLOUR_X,  STARTER_COLOUR_Y  = 778, 156  -- dedicated colour-check spot (+58 offset)
local STARTER_DIALOGUE_GAP  = 60   -- seconds of silence before picking
local STARTER_WAIT_TIMEOUT  = 120  -- give up after 2 minutes
-- Target colour (light blue-gray of the panel at 778,98) and tolerance
local ARROW_R, ARROW_G, ARROW_B = 200, 212, 218
local ARROW_TOLERANCE = 15
local STARTER_MAX_CYCLES = 50

local _dialogueModule = nil

local function vim_click(x, y)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, true,  game, 0)
    task.wait(0.2)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    task.wait(0.3)
end

local function vim_click_once(x, y)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    task.wait(0.3)
end

local function pixelMatchesArrow(x, y)
    if readpixel then
        local ok, r, g, b = pcall(readpixel, x, y)
        if ok and r then
            return math.abs(r - ARROW_R) <= ARROW_TOLERANCE
                and math.abs(g - ARROW_G) <= ARROW_TOLERANCE
                and math.abs(b - ARROW_B) <= ARROW_TOLERANCE
        end
    end
    return false  -- no readpixel: never stop early, rely on max cycles
end

local function runStarterPick()
    print("[Objectives] Starter picker: waiting for " .. STARTER_DIALOGUE_GAP .. "s dialogue gap...")

    local deadline = tick() + STARTER_WAIT_TIMEOUT
    while tick() < deadline do
        local gap = _dialogueModule and _dialogueModule.secondsSinceLastChat() or math.huge
        if gap >= STARTER_DIALOGUE_GAP then break end
        task.wait(0.2)
    end

    print("[Objectives] Starter picker: gap detected — pausing dialogue skipper.")
    if _dialogueModule then _dialogueModule.pause() end

    -- Wait for screen to fully render before first pixel read
    task.wait(2)
    for i = 1, STARTER_MAX_CYCLES do
        -- Read the dedicated colour-check spot twice with a short gap
        local match1 = pixelMatchesArrow(STARTER_COLOUR_X, STARTER_COLOUR_Y)
        task.wait(0.1)
        local match2 = pixelMatchesArrow(STARTER_COLOUR_X, STARTER_COLOUR_Y)
        if match1 and match2 then
            print("[Objectives] Starter picker: colour confirmed at cycle " .. i)
            break
        end
        print("[Objectives] Starter picker: cycling arrow (attempt " .. i .. ")")
        vim_click(STARTER_ARROW_X, STARTER_ARROW_Y)
        task.wait(1)
    end

    vim_click_once(STARTER_SELECT_X, STARTER_SELECT_Y)
    print("[Objectives] Starter picker: selected.")
    task.wait(1)
    vim_click_once(STARTER_CONFIRM_X, STARTER_CONFIRM_Y)
    print("[Objectives] Starter picker: confirmed.")
    task.wait(1)

    print("[Objectives] Starter picker: done — resuming dialogue skipper.")
    if _dialogueModule then _dialogueModule.resume() end
end

-- starterPick is handled inline in runSequence (not via resolveWaypoint)
local function resolveWaypoint(wp)
    local resolver = Resolvers[wp.type]
    if not resolver then warn("[Objectives] No resolver for type:", wp.type) return nil end
    return resolver(wp)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Teleport
-- ─────────────────────────────────────────────────────────────────────────────

local function teleportToCFrame(cf, label)
    if not cf then warn("[Objectives] nil CFrame for:", label) return false end
    local hrp = getHRP()
    hrp.CFrame = cf + Vector3.new(0, 3, 0)
    print("[Objectives] Teleported to:", label)
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- levelGate: blocks until _G.StarterLevel >= minLevel.
-- Re-anchors to the last CFrame every 15s if player drifted (e.g. blacked out).
-- ─────────────────────────────────────────────────────────────────────────────

local ANCHOR_DRIFT_THRESHOLD = 80   -- studs
local ANCHOR_CHECK_INTERVAL  = 15   -- seconds

local function runLevelGate(minLevel, anchorCFrame)
    if currentLevel() >= minLevel then return end

    print(string.format(
        "[Objectives] Level gate: need lv %d — currently lv %d. Trainer loop will grind here.",
        minLevel, currentLevel()
    ))

    local lastAnchorAt = tick()

    while currentLevel() < minLevel do
        task.wait(2)

        -- Periodically re-anchor if we've drifted (blacked out and teleported away)
        if anchorCFrame and tick() - lastAnchorAt >= ANCHOR_CHECK_INTERVAL then
            local ok, hrp = pcall(getHRP)
            if ok and hrp then
                local dist = (hrp.Position - (anchorCFrame.Position + Vector3.new(0, 3, 0))).Magnitude
                if dist > ANCHOR_DRIFT_THRESHOLD then
                    print(string.format(
                        "[Objectives] Drifted %.0f studs from level gate anchor — returning (need lv %d, have lv %d).",
                        dist, minLevel, currentLevel()
                    ))
                    hrp.CFrame = anchorCFrame + Vector3.new(0, 3, 0)
                end
            end
            lastAnchorAt = tick()
        end
    end

    print("[Objectives] Level gate passed at lv " .. currentLevel() .. ".")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sequence runner
-- ─────────────────────────────────────────────────────────────────────────────

local function runSequence(sequence, matchText)
    print("[Objectives] Running sequence for:", matchText, "(" .. #sequence .. " waypoint(s))")
    local lastCFrame = nil  -- anchor for levelGate drift correction

    for i, wp in ipairs(sequence) do
        if wp.type == "levelGate" then
            runLevelGate(wp.minLevel, lastCFrame)
        elseif wp.type == "starterPick" then
            runStarterPick()
        else
            local label = matchText .. " [" .. i .. "/" .. #sequence .. "]"
            local cf = resolveWaypoint(wp)
            local ok = teleportToCFrame(cf, label)
            if not ok then
                warn("[Objectives] Sequence aborted at waypoint", i)
                return
            end
            lastCFrame = cf
            if i < #sequence and sequence[i + 1] and sequence[i + 1].type ~= "levelGate" then
                task.wait(wp.delay or DEFAULT_WAYPOINT_DELAY)
            end
        end
    end

    print("[Objectives] Sequence complete:", matchText)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BackGui TextLabel watcher
-- ─────────────────────────────────────────────────────────────────────────────

local lastTriggeredMatch = nil
local autoHunting        = false

local function toggleAutoHunt()
    for _, desc in ipairs(playerGui:GetDescendants()) do
        if desc.Name == "Toggle" and (desc:IsA("TextButton") or desc:IsA("ImageButton")) then
            local cur = desc.Parent
            while cur do
                if cur.Name == "Auto Hunt" then
                    if firesignal then
                        pcall(function() firesignal(desc.Activated) end)
                        pcall(function() firesignal(desc.MouseButton1Click) end)
                    elseif getconnections then
                        for _, c in ipairs(getconnections(desc.Activated))         do pcall(function() c:Fire() end) end
                        for _, c in ipairs(getconnections(desc.MouseButton1Click)) do pcall(function() c:Fire() end) end
                    end
                    autoHunting = not autoHunting
                    print("[Objectives] Auto Hunt toggled →", autoHunting)
                    return
                end
                cur = cur.Parent
            end
        end
    end
end

local function checkText(text)
    for _, objective in ipairs(ObjectiveConfig) do
        if containsSubstring(text, objective.match) then
            if objective.minLevel and currentLevel() < objective.minLevel then
                print("[Objectives] Level too low (" .. currentLevel() .. " < " .. objective.minLevel .. ") for:", objective.match)
                if not autoHunting then toggleAutoHunt() end
                return
            end
            if autoHunting then toggleAutoHunt() end
            if lastTriggeredMatch == objective.match then return end
            lastTriggeredMatch = objective.match
            print("[Objectives] Matched:", objective.match)
            task.spawn(runSequence, objective.sequence, objective.match)
            return
        end
    end
end

local function hookLabel(label)
    checkText(label.Text)
    label:GetPropertyChangedSignal("Text"):Connect(function()
        checkText(label.Text)
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running = false

function Objectives.start()
    if running then return end
    running = true

    local backGui = playerGui:WaitForChild("BackGui", 30)
    if not backGui then
        warn("[Objectives] BackGui not found — objective watcher not started.")
        return
    end

    local count = 0
    for _, obj in ipairs(backGui:GetDescendants()) do
        if obj:IsA("TextLabel") then
            hookLabel(obj)
            count += 1
        end
    end
    print("[Objectives] Hooked " .. count .. " TextLabel(s) in BackGui.")

    backGui.DescendantAdded:Connect(function(obj)
        if obj:IsA("TextLabel") then hookLabel(obj) end
    end)
end

function Objectives.setDialogueModule(d)
    _dialogueModule = d
end

function Objectives.stop()
    running = false
    print("[Objectives] Stopped.")
end

function Objectives.addObjective(config)
    table.insert(ObjectiveConfig, config)
    print("[Objectives] Added objective:", config.match)
end

function Objectives.resetMatch()
    lastTriggeredMatch = nil
end

function Objectives.getLevel()
    return currentLevel()
end

return Objectives
