-- trainer.lua
-- Scans the current chunk for all trainers, teleports to the closest one,
-- fights them via BattleClient:doTrainerBattle, waits for the battle to end,
-- then waits for heal to complete before repeating.
-- One-time trainers are tracked in a Workspace folder and skipped after defeat.
-- Repeatable trainers (e.g. id 69) are never skipped.

local Trainer = {}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local localPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────────────────────────────────────
-- Trainer 69 is the known repeatable trainer — add others here if discovered
-- ─────────────────────────────────────────────────────────────────────────────
local REPEATABLE = { [69] = true, [16] = true }

-- ─────────────────────────────────────────────────────────────────────────────
-- Fought-trainer tracking — persisted to a Workspace folder this session
-- ─────────────────────────────────────────────────────────────────────────────
local FOLDER_NAME = "MacroFoughtTrainers"

local function getFoughtFolder()
    local folder = Workspace:FindFirstChild(FOLDER_NAME)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = Workspace
    end
    return folder
end

local function loadFoughtFromWorkspace()
    local fought = {}
    local folder = Workspace:FindFirstChild(FOLDER_NAME)
    if folder then
        for _, v in ipairs(folder:GetChildren()) do
            local id = tonumber(v.Name)
            if id then fought[id] = true end
        end
    end
    return fought
end

local foughtTrainers = loadFoughtFromWorkspace()

local function markFought(id)
    if REPEATABLE[id] then return end  -- never mark repeatable trainers
    foughtTrainers[id] = true
    -- Persist to workspace folder
    local folder = getFoughtFolder()
    if not folder:FindFirstChild(tostring(id)) then
        local tag = Instance.new("BoolValue")
        tag.Name  = tostring(id)
        tag.Value = true
        tag.Parent = folder
    end
    print("[Trainer] Marked trainer " .. id .. " as fought (one-time).")
end

local function hasFought(id)
    if REPEATABLE[id] then return false end
    return foughtTrainers[id] == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- _p shared cache
-- ─────────────────────────────────────────────────────────────────────────────

local _p = nil
local _findPFailedAt = nil

local function findP()
    if _findPFailedAt and os.clock() - _findPFailedAt < 5 then return nil end
    if getgc then
        pcall(function()
            for _, v in pairs(getgc(true)) do
                if typeof(v) == "table" and rawget(v, "Utilities") then _p = v end
            end
        end)
    end
    if _p then _findPFailedAt = nil; return _p end
    if debug and debug.getregistry then
        pcall(function()
            for _, fn in pairs(debug.getregistry()) do
                if typeof(fn) == "function" then
                    pcall(function()
                        local upvals = getupvalues and getupvalues(fn) or debug.getupvalues(fn)
                        for _, uv in pairs(upvals) do
                            if typeof(uv) == "table" and rawget(uv, "Utilities") then _p = uv end
                        end
                    end)
                end
            end
        end)
    end
    if _p then _findPFailedAt = nil else _findPFailedAt = os.clock() end
    return _p
end

local function getP()
    if type(_p) == "table" and rawget(_p, "Utilities") then return _p end
    if type(_G.MacroP) == "table" and rawget(_G.MacroP, "Utilities") then
        _p = _G.MacroP; return _p
    end
    _p = findP()
    if _p then _G.MacroP = _p end
    return _p
end

local function safeGet(obj, key)
    if type(obj) ~= "table" then return nil end
    local ok, v = pcall(function() return obj[key] end)
    return ok and v or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function getCurrentBattle()
    local p = getP()
    if type(p) ~= "table" then return nil end
    local b = safeGet(safeGet(p, "Battle"), "currentBattle")
    if type(b) == "table" then return b end
    return safeGet(safeGet(p, "BattleClient"), "currentBattle")
end

local function skipNpcText()
    local p = getP()
    local chat = type(p) == "table" and safeGet(p, "NPCChat") or nil
    if type(chat) ~= "table" then return end
    pcall(function() chat.fastForward = true end)
    pcall(function() chat.skipping    = true end)
    for _, m in ipairs({ "manualAdvance", "advance", "next", "skip", "finish", "continue", "clear" }) do
        local fn = rawget(chat, m)
        if type(fn) == "function" then pcall(fn, chat) end
    end
end

local function isFullHealth()
    local p = getP()
    if type(p) ~= "table" then return true end
    local network = safeGet(p, "Network")
    if type(network) ~= "table" or type(network.get) ~= "function" then return true end
    local ok, result = pcall(function() return network:get("PDS", "areFullHealth") end)
    return ok and result == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Wait helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function waitForBattleEnd(timeout)
    timeout = timeout or 300
    local deadline = tick() + timeout
    while tick() < deadline do
        if not getCurrentBattle() then return true end
        task.wait(0.1)
    end
    return false
end

local function waitForFullHealth(timeout)
    timeout = timeout or 30
    local deadline = tick() + timeout
    while tick() < deadline do
        if isFullHealth() then return true end
        task.wait(0.5)
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NPC position extraction
-- ─────────────────────────────────────────────────────────────────────────────

local function getNPCPosition(npc)
    if not npc then return nil end
    -- Instance path: Model with PrimaryPart or HumanoidRootPart
    local ok, pos = pcall(function()
        if typeof(npc) == "Instance" then
            local hrp = npc:FindFirstChild("HumanoidRootPart")
                or npc:FindFirstChildWhichIsA("BasePart")
            if hrp then return hrp.Position end
            if npc:IsA("Model") then return npc:GetPivot().Position end
        end
        -- Table path: npc.position / npc.Position / npc.model
        local p = rawget(npc, "position") or rawget(npc, "Position")
        if p then return p end
        local model = rawget(npc, "model") or rawget(npc, "Model")
        if typeof(model) == "Instance" then
            local hrp = model:FindFirstChild("HumanoidRootPart")
                or model:FindFirstChildWhichIsA("BasePart")
            if hrp then return hrp.Position end
        end
    end)
    return ok and pos or nil
end

local function getPlayerPosition()
    local char = localPlayer.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Scan chunk for all trainers → { id, trainerData, npc, position }
-- ─────────────────────────────────────────────────────────────────────────────

local function getAllTrainers()
    local p = getP()
    if type(p) ~= "table" then return {} end
    local dataManager = safeGet(p, "DataManager")
    local chunk = dataManager and safeGet(dataManager, "currentChunk")
    if type(chunk) ~= "table" then return {} end

    local battles = safeGet(chunk, "battles")
    if type(battles) ~= "table" then return {} end

    -- Build id → npc map from chunk NPCs
    local npcByBattleId = {}
    pcall(function()
        local npcs = chunk:GetNPCs()
        if type(npcs) ~= "table" then return end
        for _, npc in pairs(npcs) do
            local battleNum = safeGet(safeGet(npc, "battle"), "num")
            if not battleNum then
                local iv = typeof(npc) == "Instance"
                    and npc:FindFirstChild("#Battle") or nil
                battleNum = iv and iv.Value
            end
            if battleNum then
                npcByBattleId[tonumber(battleNum)] = npc
            end
        end
    end)

    local result = {}
    for id, trainerData in pairs(battles) do
        local numId = tonumber(id)
        if numId and type(trainerData) == "table" and not hasFought(numId) then
            local npc = npcByBattleId[numId]
            local pos = getNPCPosition(npc)
            table.insert(result, {
                id          = numId,
                trainerData = trainerData,
                npc         = npc,
                position    = pos,
            })
        end
    end
    return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Find closest trainer to the player
-- ─────────────────────────────────────────────────────────────────────────────

local function findClosestTrainer()
    local trainers = getAllTrainers()
    if #trainers == 0 then return nil end

    local playerPos = getPlayerPosition()
    local best, bestDist = nil, math.huge

    for _, t in ipairs(trainers) do
        local dist = math.huge
        if playerPos and t.position then
            dist = (t.position - playerPos).Magnitude
        end
        if dist < bestDist then
            bestDist = dist
            best = t
        end
    end

    if best then
        print(string.format("[Trainer] Closest trainer: id=%d  dist=%.1f", best.id, bestDist))
    end
    return best
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Teleport next to a trainer NPC
-- ─────────────────────────────────────────────────────────────────────────────

local function teleportToTrainer(trainer)
    if not trainer.position then return end
    local char = localPlayer.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    -- Land 3 studs above and 2 studs in front of the trainer
    hrp.CFrame = CFrame.new(trainer.position + Vector3.new(0, 3, 2))
    task.wait(0.2)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Switch prompt dismissal
-- ─────────────────────────────────────────────────────────────────────────────

local lastSwitchDismissAt = 0

local function dismissSwitchPrompt()
    if os.clock() - lastSwitchDismissAt < 0.35 then return end
    local p = getP()
    if type(p) ~= "table" then return end
    local battle = getCurrentBattle()
    if type(battle) ~= "table" or safeGet(battle, "kind") ~= "trainer" then return end

    local battleGui = safeGet(p, "BattleGui")
    if type(battleGui) ~= "table" then return end

    local fired = false
    pcall(function()
        local yesNo = safeGet(battleGui, "yesNoSignal")
            or safeGet(battleGui, "switchPromptSignal")
            or safeGet(battleGui, "promptSignal")
        if yesNo and type(yesNo.Fire) == "function" then
            yesNo:Fire(false); fired = true
        end
    end)

    if not fired then
        pcall(function()
            local playerGui = localPlayer:FindFirstChild("PlayerGui")
            if not playerGui then return end
            for _, desc in ipairs(playerGui:GetDescendants()) do
                if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then
                    local t = (desc.Text or ""):lower()
                    if t == "no" or t == "cancel" then
                        if firesignal then firesignal(desc.MouseButton1Click)
                        elseif getconnections then
                            for _, c in ipairs(getconnections(desc.MouseButton1Click)) do pcall(function() c:Fire() end) end
                        else pcall(function() desc:Activate() end) end
                        fired = true; break
                    end
                end
            end
        end)
    end

    if fired then lastSwitchDismissAt = os.clock() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Start the battle
-- ─────────────────────────────────────────────────────────────────────────────

local function startBattle(trainer)
    if getCurrentBattle() then return false, "Battle already active." end

    local p = getP()
    if type(p) ~= "table" then return false, "no _p" end
    local battleClient = safeGet(p, "BattleClient") or safeGet(p, "Battle")
    if type(battleClient) ~= "table" then return false, "no BattleClient" end
    if not trainer.npc then return false, "no NPC for trainer " .. trainer.id end

    skipNpcText()
    pcall(function()
        battleClient:doTrainerBattle({
            trainer         = trainer.trainerData,
            opponentBaseNPC = trainer.npc,
            skipStartAnim   = true,
        })
    end)
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running = false

function Trainer.start()
    if running then return end
    running = true
    getP()

    -- Fast loop: mid-battle switch prompt + fast-forward
    task.spawn(function()
        while running do
            skipNpcText()
            local p = getP()
            if getCurrentBattle() then
                dismissSwitchPrompt()
                local battleGui = type(p) == "table" and safeGet(p, "BattleGui") or nil
                if type(battleGui) == "table" then
                    pcall(function() battleGui.fastForward = true end)
                    pcall(function() battleGui:setFastForward(true) end)
                end
            end
            task.wait(0.08)
        end
    end)

    -- Main loop: find closest → teleport → fight → wait → heal → repeat
    task.spawn(function()
        print("[Trainer] Auto-trainer started — scanning for nearest trainer.")
        while running do
            if getCurrentBattle() then
                task.wait(0.5)
            else
                local trainer = findClosestTrainer()
                if not trainer then
                    warn("[Trainer] No trainers found in current chunk.")
                    task.wait(3)
                else
                    teleportToTrainer(trainer)
                    local ok, err = startBattle(trainer)
                    if not ok then
                        warn("[Trainer] startBattle failed: " .. tostring(err))
                        task.wait(2)
                    else
                        print("[Trainer] Battle started vs trainer " .. trainer.id .. " — waiting for end...")
                        waitForBattleEnd(300)
                        skipNpcText()
                        markFought(trainer.id)
                        -- Let heal module do its job, then confirm full health before next fight
                        print("[Trainer] Battle done — waiting for full health...")
                        waitForFullHealth(30)
                        print("[Trainer] Ready — finding next trainer...")
                        task.wait(0.5)
                    end
                end
            end
        end
        print("[Trainer] Auto-trainer stopped.")
    end)
end

function Trainer.stop()
    running = false
    print("[Trainer] Stopped.")
end

-- One-shot: fight the closest trainer right now
function Trainer.fightNearest()
    local trainer = findClosestTrainer()
    if not trainer then warn("[Trainer] No trainers found.") return end
    teleportToTrainer(trainer)
    local ok, err = startBattle(trainer)
    if not ok then warn("[Trainer] fightNearest failed: " .. tostring(err)) end
end

-- List all trainers in the current chunk (for debugging)
function Trainer.listTrainers()
    local trainers = getAllTrainers()
    local playerPos = getPlayerPosition()
    print("[Trainer] Found " .. #trainers .. " available trainer(s) in chunk:")
    for _, t in ipairs(trainers) do
        local dist = (playerPos and t.position) and
            string.format("%.1f studs", (t.position - playerPos).Magnitude) or "unknown dist"
        local tag = REPEATABLE[t.id] and " [REPEATABLE]" or ""
        print(string.format("  id=%-4d  %s%s  hasNPC=%s", t.id, dist, tag, tostring(t.npc ~= nil)))
    end
end

-- Clear the fought list (resets all one-time trainers for a fresh run)
function Trainer.clearFought()
    foughtTrainers = {}
    local folder = Workspace:FindFirstChild(FOLDER_NAME)
    if folder then folder:Destroy() end
    print("[Trainer] Fought trainer list cleared.")
end

-- Mark a trainer ID as repeatable at runtime
function Trainer.addRepeatable(id)
    REPEATABLE[tonumber(id)] = true
    print("[Trainer] Trainer " .. tostring(id) .. " marked as repeatable.")
end

return Trainer
