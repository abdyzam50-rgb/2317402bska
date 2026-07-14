-- trainer.lua
-- Scans the current chunk for all trainers, teleports to the closest one,
-- fights them, waits for battle end + heal, then repeats.
--
-- One-time trainers are skipped after defeat (persisted in Workspace).
-- "Too strong" trainers (lost without defeating any opponent Loomian) are
-- skipped until player level >= trainer's highest Loomian level + 3.
-- Repeatable trainers (16, 69) are never permanently skipped but still
-- obey the "too strong" cooldown.
-- Stops entirely when player reaches level 20.

local Trainer = {}

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local Workspace       = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local localPlayer     = Players.LocalPlayer

local STOP_LEVEL = 20

-- ─────────────────────────────────────────────────────────────────────────────
-- Known repeatable trainers — never permanently marked as fought
-- ─────────────────────────────────────────────────────────────────────────────
local REPEATABLE = { [16] = true, [69] = true }

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
-- Workspace persistence helpers
-- ─────────────────────────────────────────────────────────────────────────────

local FOUGHT_FOLDER   = "MacroFoughtTrainers"
local TOOSTRONG_FOLDER = "MacroTooStrong"

local function getOrCreateFolder(name)
    local f = Workspace:FindFirstChild(name)
    if not f then
        f = Instance.new("Folder")
        f.Name = name
        f.Parent = Workspace
    end
    return f
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fought-trainer tracking
-- ─────────────────────────────────────────────────────────────────────────────

local foughtTrainers = {}

local function loadFought()
    local folder = Workspace:FindFirstChild(FOUGHT_FOLDER)
    if not folder then return end
    for _, v in ipairs(folder:GetChildren()) do
        local id = tonumber(v.Name)
        if id then foughtTrainers[id] = true end
    end
end

local function markFought(id)
    if REPEATABLE[id] then return end
    foughtTrainers[id] = true
    local folder = getOrCreateFolder(FOUGHT_FOLDER)
    if not folder:FindFirstChild(tostring(id)) then
        local tag = Instance.new("BoolValue")
        tag.Name   = tostring(id)
        tag.Value  = true
        tag.Parent = folder
    end
    print("[Trainer] Trainer " .. id .. " marked as fought (one-time).")
end

local function hasFought(id)
    if REPEATABLE[id] then return false end
    return foughtTrainers[id] == true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- "Too strong" tracking
-- ─────────────────────────────────────────────────────────────────────────────

local tooStrong = {}  -- [id] = highestLevel

local function loadTooStrong()
    local folder = Workspace:FindFirstChild(TOOSTRONG_FOLDER)
    if not folder then return end
    for _, v in ipairs(folder:GetChildren()) do
        local id  = tonumber(v.Name)
        local lvl = tonumber(v.Value)
        if id and lvl then tooStrong[id] = lvl end
    end
end

local function saveTooStrong(id, highestLevel)
    tooStrong[id] = highestLevel
    local folder = getOrCreateFolder(TOOSTRONG_FOLDER)
    local existing = folder:FindFirstChild(tostring(id))
    if existing then
        existing.Value = highestLevel
    else
        local iv = Instance.new("IntValue")
        iv.Name   = tostring(id)
        iv.Value  = highestLevel
        iv.Parent = folder
    end
end

local function isTooStrong(id)
    local highestLevel = tooStrong[id]
    if not highestLevel then return false end
    local ourLevel = _G.StarterLevel or 1
    return ourLevel < highestLevel + 3
end

local function getRequiredLevel(id)
    local highestLevel = tooStrong[id]
    return highestLevel and (highestLevel + 3) or nil
end

-- Deep-scan trainerData table for the highest Loomian level value
local function getTrainerHighestLevel(trainerData)
    local highest = 1
    local visited = {}
    local function scan(t, depth)
        if depth > 10 or type(t) ~= "table" or visited[t] then return end
        visited[t] = true
        for k, v in pairs(t) do
            if (k == "level" or k == "Level" or k == "lv" or k == "Lv") then
                local n = tonumber(v)
                if n and n > highest then highest = n end
            elseif type(v) == "table" then
                scan(v, depth + 1)
            end
        end
    end
    pcall(scan, trainerData, 0)
    return highest
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Core helpers
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

local function getPlayerPosition()
    local char = localPlayer.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

local function ourLevel()
    return _G.StarterLevel or 1
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Opponent KO tracking — monitor BattleGui.opponentMonster health
-- ─────────────────────────────────────────────────────────────────────────────

local opponentFainted      = 0   -- KOs scored this battle
local lastOpponentHealth   = nil

local function resetBattleTracking()
    opponentFainted    = 0
    lastOpponentHealth = nil
end

local function tickOpponentTracking()
    local p = getP()
    if type(p) ~= "table" then return end
    local battleGui = safeGet(p, "BattleGui")
    if type(battleGui) ~= "table" then return end

    local oppMon = safeGet(battleGui, "opponentMonster")
        or safeGet(battleGui, "enemyMonster")
        or safeGet(battleGui, "opponent")
    if type(oppMon) ~= "table" then return end

    local hp = tonumber(safeGet(oppMon, "health") or safeGet(oppMon, "hp") or safeGet(oppMon, "HP"))
    if not hp then return end

    if lastOpponentHealth and lastOpponentHealth > 0 and hp <= 0 then
        opponentFainted = opponentFainted + 1
        print("[Trainer] Opponent Loomian fainted (total this battle: " .. opponentFainted .. ")")
    end
    lastOpponentHealth = hp
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Wait helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function waitForBattleEnd(timeout)
    local deadline = tick() + (timeout or 300)
    while tick() < deadline do
        if not getCurrentBattle() then return true end
        task.wait(0.1)
    end
    return false
end

local function waitForFullHealth(timeout)
    local deadline = tick() + (timeout or 30)
    while tick() < deadline do
        if isFullHealth() then return true end
        task.wait(0.5)
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NPC position
-- ─────────────────────────────────────────────────────────────────────────────

local function getNPCPosition(npc)
    if not npc then return nil end
    local ok, pos = pcall(function()
        if typeof(npc) == "Instance" then
            local hrp = npc:FindFirstChild("HumanoidRootPart")
                or npc:FindFirstChildWhichIsA("BasePart")
            if hrp then return hrp.Position end
            if npc:IsA("Model") then return npc:GetPivot().Position end
        end
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Scan chunk for available trainers
-- ─────────────────────────────────────────────────────────────────────────────

local function getAllTrainers()
    local p = getP()
    if type(p) ~= "table" then return {} end
    local dataManager = safeGet(p, "DataManager")
    local chunk = dataManager and safeGet(dataManager, "currentChunk")
    if type(chunk) ~= "table" then return {} end

    local battles = safeGet(chunk, "battles")
    if type(battles) ~= "table" then return {} end

    local npcByBattleId = {}
    pcall(function()
        local npcs = chunk:GetNPCs()
        if type(npcs) ~= "table" then return end
        for _, npc in pairs(npcs) do
            local battleNum = safeGet(safeGet(npc, "battle"), "num")
            if not battleNum then
                local iv = typeof(npc) == "Instance" and npc:FindFirstChild("#Battle") or nil
                battleNum = iv and iv.Value
            end
            if battleNum then npcByBattleId[tonumber(battleNum)] = npc end
        end
    end)

    local result = {}
    for id, trainerData in pairs(battles) do
        local numId = tonumber(id)
        if numId and type(trainerData) == "table" then
            -- Skip permanently fought one-time trainers
            if hasFought(numId) then goto continue end
            -- Skip trainers that are currently too strong
            if isTooStrong(numId) then goto continue end

            local npc = npcByBattleId[numId]
            table.insert(result, {
                id          = numId,
                trainerData = trainerData,
                npc         = npc,
                position    = getNPCPosition(npc),
            })
            ::continue::
        end
    end
    return result
end

local function findClosestTrainer()
    local trainers = getAllTrainers()
    if #trainers == 0 then return nil end
    local playerPos = getPlayerPosition()
    local best, bestDist = nil, math.huge
    for _, t in ipairs(trainers) do
        local dist = (playerPos and t.position) and (t.position - playerPos).Magnitude or math.huge
        if dist < bestDist then bestDist = dist; best = t end
    end
    if best then
        print(string.format("[Trainer] Closest available: id=%d  dist=%.1f", best.id, bestDist))
    end
    return best
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Teleport + battle
-- ─────────────────────────────────────────────────────────────────────────────

local function teleportToTrainer(trainer)
    if not trainer.position then return end
    local char = localPlayer.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    hrp.CFrame = CFrame.new(trainer.position + Vector3.new(0, 3, 2))
    task.wait(0.2)
end

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
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running = false

function Trainer.start()
    if running then return end
    running = true
    loadFought()
    loadTooStrong()
    getP()

    -- Fast loop: switch prompt + fast-forward + opponent KO tracking
    task.spawn(function()
        while running do
            skipNpcText()
            local p = getP()
            if getCurrentBattle() then
                dismissSwitchPrompt()
                tickOpponentTracking()
                local battleGui = type(p) == "table" and safeGet(p, "BattleGui") or nil
                if type(battleGui) == "table" then
                    pcall(function() battleGui.fastForward = true end)
                    pcall(function() battleGui:setFastForward(true) end)
                end
            end
            task.wait(0.08)
        end
    end)

    -- Main loop: find → teleport → fight → classify → heal → repeat
    task.spawn(function()
        print("[Trainer] Auto-trainer started. Stop level: " .. STOP_LEVEL)

        while running do
            -- Level 20 cap
            if ourLevel() >= STOP_LEVEL then
                print("[Trainer] Level " .. STOP_LEVEL .. " reached — stopping auto-trainer.")
                running = false
                return
            end

            if getCurrentBattle() then
                task.wait(0.5)
            else
                local trainer = findClosestTrainer()

                if not trainer then
                    -- All trainers in chunk either fought or too strong
                    local nextRequired = nil
                    for id, highLvl in pairs(tooStrong) do
                        local req = highLvl + 3
                        if not nextRequired or req < nextRequired then
                            nextRequired = req
                        end
                    end
                    if nextRequired then
                        print(string.format(
                            "[Trainer] No available trainers. Currently lv %d. Waiting for lv %d to unlock more.",
                            ourLevel(), nextRequired
                        ))
                    else
                        print("[Trainer] No trainers found in current chunk.")
                    end
                    task.wait(5)
                else
                    local preBattlePos = getPlayerPosition()
                    teleportToTrainer(trainer)
                    resetBattleTracking()

                    local ok, err = startBattle(trainer)
                    if not ok then
                        warn("[Trainer] startBattle failed: " .. tostring(err))
                        task.wait(2)
                    else
                        print("[Trainer] Fighting trainer " .. trainer.id .. "...")
                        waitForBattleEnd(300)
                        skipNpcText()
                        task.wait(0.3) -- brief window before heal module acts

                        -- Detect if we lost (significant position change = blacked out)
                        local postBattlePos = getPlayerPosition()
                        local posChange = (preBattlePos and postBattlePos)
                            and (postBattlePos - preBattlePos).Magnitude or 0
                        local weLost = posChange > 50

                        if weLost and opponentFainted == 0 then
                            -- Lost without taking out a single opponent Loomian = too strong
                            local highestLevel = getTrainerHighestLevel(trainer.trainerData)
                            saveTooStrong(trainer.id, highestLevel)
                            print(string.format(
                                "[Trainer] Trainer %d is TOO STRONG (highest lv %d). Need lv %d. Skipping for now.",
                                trainer.id, highestLevel, highestLevel + 3
                            ))
                        elseif not weLost then
                            -- We won — mark one-time trainers as done
                            if tooStrong[trainer.id] then
                                -- Previously too strong but we beat them now — clear the flag
                                tooStrong[trainer.id] = nil
                                local folder = Workspace:FindFirstChild(TOOSTRONG_FOLDER)
                                local tag = folder and folder:FindFirstChild(tostring(trainer.id))
                                if tag then tag:Destroy() end
                                print("[Trainer] Trainer " .. trainer.id .. " cleared from too-strong list.")
                            end
                            markFought(trainer.id)
                        end
                        -- If we lost but did KO at least one opponent — hard battle, just retry

                        print("[Trainer] Waiting for full health...")
                        waitForFullHealth(30)
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

function Trainer.fightNearest()
    local trainer = findClosestTrainer()
    if not trainer then warn("[Trainer] No trainers available.") return end
    teleportToTrainer(trainer)
    resetBattleTracking()
    local ok, err = startBattle(trainer)
    if not ok then warn("[Trainer] fightNearest failed: " .. tostring(err)) end
end

function Trainer.listTrainers()
    local all = {}
    local p = getP()
    local dataManager = type(p) == "table" and safeGet(p, "DataManager") or nil
    local chunk = dataManager and safeGet(dataManager, "currentChunk")
    local battles = chunk and safeGet(chunk, "battles") or {}
    local playerPos = getPlayerPosition()

    for id, trainerData in pairs(type(battles) == "table" and battles or {}) do
        local numId = tonumber(id)
        if numId then
            local status
            if hasFought(numId)   then status = "fought"
            elseif isTooStrong(numId) then
                status = string.format("too strong (need lv %d)", getRequiredLevel(numId))
            elseif REPEATABLE[numId] then status = "repeatable"
            else                      status = "available" end
            table.insert(all, { id = numId, status = status })
        end
    end

    table.sort(all, function(a, b) return a.id < b.id end)
    print("[Trainer] All trainers in chunk:")
    for _, t in ipairs(all) do
        print(string.format("  id=%-4d  %s", t.id, t.status))
    end
end

function Trainer.clearFought()
    foughtTrainers = {}
    local f = Workspace:FindFirstChild(FOUGHT_FOLDER)
    if f then f:Destroy() end
    print("[Trainer] Fought list cleared.")
end

function Trainer.clearTooStrong()
    tooStrong = {}
    local f = Workspace:FindFirstChild(TOOSTRONG_FOLDER)
    if f then f:Destroy() end
    print("[Trainer] Too-strong list cleared.")
end

function Trainer.addRepeatable(id)
    REPEATABLE[tonumber(id)] = true
    print("[Trainer] Trainer " .. tostring(id) .. " marked as repeatable.")
end

return Trainer
