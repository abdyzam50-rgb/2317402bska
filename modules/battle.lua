-- battle.lua
-- Auto-battle using the game's own BattleGui internal API.
-- Move selection: effectiveness * basePower scoring (battle_move_macro.lua v6.2.3)
-- Auto-swap: hooks EVT remote for party state; switches when lead faints.
-- Switch sequence: Loomians panel → PartyMain.SlotN → FrontGui.SwitchButton

local Battle = {}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────────────────────────────────────
-- _p scan — getgc first, registry fallback
-- ─────────────────────────────────────────────────────────────────────────────

local _p = nil
local _findPFailedAt = nil

local function findP()
    if _findPFailedAt and os.clock() - _findPFailedAt < 5 then return nil end

    if getgc then
        pcall(function()
            for _, v in pairs(getgc(true)) do
                if typeof(v) == "table" and rawget(v, "Utilities") and not (_p and _p.Battle) then
                    _p = v
                end
            end
        end)
    end

    if _p then _findPFailedAt = nil; return _p end

    if debug and debug.getregistry then
        pcall(function()
            for _, fn in pairs(debug.getregistry()) do
                if typeof(fn) == "function" and not (_p and _p.Battle) then
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
    if type(_p) ~= "table" or not rawget(_p, "Utilities") then _p = findP() end
    return _p
end

local function safeGet(obj, key)
    if type(obj) ~= "table" then return nil end
    local ok, v = pcall(function() return obj[key] end)
    return ok and v or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NPCChat fast-forward
-- ─────────────────────────────────────────────────────────────────────────────

local function skipBattleText()
    local p = getP()
    local chat = type(p) == "table" and safeGet(p, "NPCChat") or nil
    if type(chat) ~= "table" then return end
    pcall(function()
        chat.fastForward         = true
        chat.skipping            = true
        chat.TextSpeedMultiplier = 100
    end)
    for _, name in ipairs({ "manualAdvance", "advance", "next", "skip", "finish", "continue" }) do
        local m = rawget(chat, name)
        if type(m) == "function" then pcall(m, chat) end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- getCurrentBattle
-- ─────────────────────────────────────────────────────────────────────────────

local function getCurrentBattle()
    local p = getP()
    if type(p) ~= "table" then return nil end
    local b = safeGet(safeGet(p, "Battle"), "currentBattle")
    if type(b) == "table" then return b end
    return safeGet(safeGet(p, "BattleClient"), "currentBattle")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Party state — hooked from EVT RemoteEvent packets
-- Tracks slots 1-7: active, fainted, healthFrac
-- ─────────────────────────────────────────────────────────────────────────────

local SWITCH_SLOT_MIN   = 2
local SWITCH_SLOT_MAX   = 5

local partyState  = {}   -- [slot] = { name, active, fainted, healthFrac }
local activeSlot  = nil
local evtHooked   = {}

local function normalizeSlotIndex(mon, fallback)
    return tonumber(safeGet(mon, "index")) or tonumber(safeGet(mon, "slot")) or fallback
end

local function applyPartyPacket(packet)
    if type(packet) ~= "table" then return end

    local side = safeGet(packet, "side")
    local party = type(side) == "table" and (safeGet(side, "party") or safeGet(side, "Party")) or nil
    if type(party) ~= "table" then return end

    local activeMon = nil
    local active = safeGet(packet, "active")
    if type(active) == "table" then
        activeMon = active[1] or active["1"]
    end

    local newParty = {}
    for key, mon in pairs(party) do
        if type(mon) == "table" then
            local idx = normalizeSlotIndex(mon, tonumber(key))
            if idx and idx >= 1 and idx <= 7 then
                local hp    = safeGet(mon, "health") or safeGet(mon, "hp") or safeGet(mon, "HP")
                local maxHp = safeGet(mon, "maxHealth") or safeGet(mon, "maxhp") or safeGet(mon, "maxHP")
                local frac  = nil
                if type(hp) == "number" and type(maxHp) == "number" and maxHp > 0 then
                    frac = hp / maxHp
                elseif type(hp) == "number" and hp <= 1 then
                    frac = hp
                end
                newParty[idx] = {
                    name       = safeGet(mon, "name") or safeGet(mon, "species") or ("Slot" .. idx),
                    active     = safeGet(mon, "active") == true,
                    fainted    = safeGet(mon, "fainted") == true or (frac and frac <= 0),
                    healthFrac = frac,
                }
            end
        end
    end

    -- Overlay active-monster stats onto the active party entry
    if type(activeMon) == "table" then
        local aName    = safeGet(activeMon, "name")
        local aHp      = safeGet(activeMon, "health")
        local aMaxHp   = safeGet(activeMon, "maxHealth")
        local aFainted = safeGet(activeMon, "fainted") == true or (type(aHp) == "number" and aHp <= 0)

        -- Find which slot the active monster maps to
        local foundSlot = nil
        for slot, entry in pairs(newParty) do
            if entry.active or (aName and entry.name == aName) then
                foundSlot = slot
                break
            end
        end
        if foundSlot then
            local entry = newParty[foundSlot]
            entry.active  = true
            entry.fainted = aFainted
            if type(aHp) == "number" and type(aMaxHp) == "number" and aMaxHp > 0 then
                entry.healthFrac = aHp / aMaxHp
            end
            activeSlot = foundSlot
        end
    end

    partyState = newParty
end

local function onEvtEvent(...)
    for _, arg in ipairs({...}) do
        if type(arg) == "table" then
            if safeGet(arg, "requestType") == "move" and safeGet(arg, "active") then
                applyPartyPacket(arg)
            elseif safeGet(arg, "side") then
                applyPartyPacket(arg)
            end
        end
    end
end

local function hookEvtRemotes()
    local function hookOne(obj)
        if not obj:IsA("RemoteEvent") or obj.Name ~= "EVT" or evtHooked[obj] then return end
        evtHooked[obj] = true
        obj.OnClientEvent:Connect(onEvtEvent)
    end
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do hookOne(obj) end
    ReplicatedStorage.DescendantAdded:Connect(hookOne)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Best-move selection
-- ─────────────────────────────────────────────────────────────────────────────

local function getMoveEffectiveness(mv)
    if type(mv) == "table" and type(mv.effective) == "table" then
        return tonumber(mv.effective[1]) or 1
    end
    return 1
end

local function selectBestMoveSlot(moves, currentEnergy)
    local bestSlot, bestScore, bestCost = nil, -1, math.huge
    for i = 1, 4 do
        local mv = type(moves) == "table" and moves[i] or nil
        if type(mv) == "table" and not safeGet(mv, "disabled") then
            local cost = safeGet(mv, "energy") or 0
            if currentEnergy >= cost then
                local score = getMoveEffectiveness(mv) * (safeGet(mv, "basePower") or 0)
                if score > bestScore or (score == bestScore and cost < bestCost) then
                    bestScore = score
                    bestCost  = cost
                    bestSlot  = i
                end
            end
        end
    end
    return bestSlot, bestScore
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Auto-swap: slot selection
-- Pick the healthiest alive bench slot (2-5) that isn't the current lead.
-- ─────────────────────────────────────────────────────────────────────────────

local function selectBestSwapSlot()
    local bestSlot, bestFrac = nil, -1
    for slot = SWITCH_SLOT_MIN, SWITCH_SLOT_MAX do
        local entry = partyState[slot]
        if entry and not entry.fainted and not entry.active then
            local frac = entry.healthFrac or 1
            if frac > bestFrac then
                bestFrac = frac
                bestSlot = slot
            end
        end
    end
    return bestSlot
end

-- ─────────────────────────────────────────────────────────────────────────────
-- GUI button helpers for the 3-step switch sequence
-- ─────────────────────────────────────────────────────────────────────────────

local function fireButton(btn)
    if not btn then return false end
    local fired = false
    pcall(function()
        if typeof(firesignal) == "function" then
            firesignal(btn.MouseButton1Down)
            firesignal(btn.MouseButton1Click)
            firesignal(btn.MouseButton1Up)
            fired = true
        end
    end)
    if not fired then
        pcall(function()
            if typeof(getconnections) == "function" then
                for _, c in ipairs(getconnections(btn.MouseButton1Click)) do c:Fire() end
                fired = true
            end
        end)
    end
    if not fired then
        pcall(function() btn:Activate(); fired = true end)
    end
    return fired
end

local function resolveButton(node)
    if not node then return nil end
    if node:IsA("GuiButton") then return node end
    local b = node:FindFirstChildWhichIsA("GuiButton", true)
    return b or (node:IsA("GuiObject") and node or nil)
end

-- Step 1: find the Loomians side-panel button inside BattleGui
local function findLoomiansButton()
    local mainGui = playerGui:FindFirstChild("MainGui")
    if not mainGui then return nil end
    local bGui = mainGui:FindFirstChild("BattleGui", true)
    if not bGui then return nil end

    -- Walk all GuiButtons; match by name or child label containing "loomian"
    for _, desc in ipairs(bGui:GetDescendants()) do
        if desc:IsA("GuiButton") and desc.Visible then
            local n = desc.Name:lower()
            if n:find("loomian") or n:find("switch") then return desc end
            for _, child in ipairs(desc:GetDescendants()) do
                if (child:IsA("TextLabel") or child:IsA("TextButton")) then
                    local t = (child.Text or ""):lower()
                    if t:find("loomian") or t:find("switch") then return desc end
                end
            end
        end
    end
    return nil
end

-- Step 2: find a party slot button in WatchContainer.PartyMenu.PartyMain
local function findPartySlotButton(slot)
    local mainGui = playerGui:FindFirstChild("MainGui")
    if not mainGui then return nil end
    local wc = mainGui:FindFirstChild("WatchContainer")
    if not wc then return nil end
    local pm = wc:FindFirstChild("PartyMenu")
    if not pm then return nil end
    local pmain = pm:FindFirstChild("PartyMain")
    if not pmain then return nil end
    local slotFrame = pmain:FindFirstChild("Slot" .. slot)
    if not slotFrame then return nil end
    return resolveButton(slotFrame)
end

-- Check that PartyMenu is open (PartyMain visible)
local function isPartyMenuOpen()
    local mainGui = playerGui:FindFirstChild("MainGui")
    if not mainGui then return false end
    local wc = mainGui:FindFirstChild("WatchContainer")
    if not wc then return false end
    local pm = wc:FindFirstChild("PartyMenu")
    if not pm then return false end
    local pmain = pm:FindFirstChild("PartyMain")
    return pmain and pmain.Visible
end

-- Step 3: find the switch confirm button in FrontGui
local function findSwitchConfirmButton()
    local frontGui = playerGui:FindFirstChild("FrontGui")
    if not frontGui then return nil end
    local sw = frontGui:FindFirstChild("SwitchButton")
    if not sw then return nil end
    return resolveButton(sw)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- executeAutoSwitch — 3-step sequence with retries
-- ─────────────────────────────────────────────────────────────────────────────

local STEP_WAIT    = 0.55
local MENU_TIMEOUT = 4

local switching = false

local function executeAutoSwitch(slot)
    if switching then return false end
    switching = true
    local ok = false

    pcall(function()
        print("[Battle] Auto-swap: targeting slot " .. slot)

        for attempt = 1, 5 do
            -- Step 1: open party menu via Loomians button
            if not isPartyMenuOpen() then
                local loomBtn = findLoomiansButton()
                if loomBtn then
                    fireButton(loomBtn)
                    -- wait for menu to open
                    local deadline = tick() + MENU_TIMEOUT
                    while tick() < deadline and not isPartyMenuOpen() do
                        task.wait(0.1)
                    end
                else
                    task.wait(STEP_WAIT)
                end
            end

            -- Step 2: click the target slot
            if isPartyMenuOpen() then
                local slotBtn = findPartySlotButton(slot)
                if slotBtn then
                    fireButton(slotBtn)
                    task.wait(STEP_WAIT)
                else
                    task.wait(STEP_WAIT)
                end
            end

            -- Step 3: click confirm
            local switchBtn = findSwitchConfirmButton()
            if switchBtn then
                fireButton(switchBtn)
                task.wait(STEP_WAIT)
                print("[Battle] Auto-swap: sent confirm for slot " .. slot)
                ok = true
                break
            end

            task.wait(STEP_WAIT)
        end
    end)

    switching = false
    return ok
end

-- ─────────────────────────────────────────────────────────────────────────────
-- fireMove — MrJack u37 logic + dynamic best-move selection
-- ─────────────────────────────────────────────────────────────────────────────

local function fireMove()
    local p = getP()
    if type(p) ~= "table" then return end

    local battle    = getCurrentBattle()
    local battleGui = safeGet(p, "BattleGui")
    if type(battle) ~= "table" or type(battleGui) ~= "table" then return end
    if safeGet(battle, "state") ~= "input" or switching then return end

    -- Open fight menu if not already showing moves
    if not safeGet(battleGui, "onMoveClicked") then
        pcall(function() battleGui:mainButtonClicked(1) end)
    end

    local moves         = safeGet(battleGui, "moves")
    local activeMonster = safeGet(battleGui, "activeMonster")
    local energy        = activeMonster and safeGet(activeMonster, "energy") or 0
    local bypassEnergy  = activeMonster and safeGet(activeMonster, "bypassEnergy") or false

    local effectiveEnergy = bypassEnergy and math.huge or energy

    local slot = selectBestMoveSlot(moves, effectiveEnergy)

    if slot then
        pcall(function() battleGui:onMoveClicked(slot) end)
    else
        -- No usable move — rest
        pcall(function()
            local fsg = safeGet(battleGui, "fightSelectionGroup")
            if fsg then fsg:LoseFocus() end
            local ev = safeGet(battleGui, "inputEvent")
            if ev then ev:fire("rest 0") end
            battleGui:exitButtonsMoveChosen()
        end)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Check if the active lead has fainted (from party state or BattleGui)
-- ─────────────────────────────────────────────────────────────────────────────

local function leadHasFainted()
    -- Try BattleGui activeMonster first (most current)
    local p = getP()
    if type(p) == "table" then
        local battleGui = safeGet(p, "BattleGui")
        if type(battleGui) == "table" then
            local am = safeGet(battleGui, "activeMonster")
            if type(am) == "table" then
                if safeGet(am, "fainted") == true then return true end
                local hp = safeGet(am, "health")
                if type(hp) == "number" and hp <= 0 then return true end
            end
        end
    end
    -- Fallback: party state
    if activeSlot and partyState[activeSlot] then
        return partyState[activeSlot].fainted == true
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running       = false
local TICK_RATE     = 0.08
local FIRE_COOLDOWN = 0.35

function Battle.start()
    if running then return end
    running = true
    getP()
    hookEvtRemotes()

    task.spawn(function()
        print("[Battle] Auto-battle started (best-move + auto-swap).")
        local lastFireAt  = 0
        local lastSwapAt  = 0
        local SWAP_COOLDOWN = 3

        while running do
            local battle = getCurrentBattle()
            if type(battle) == "table" then
                skipBattleText()

                -- Auto-swap if lead fainted and we haven't just swapped
                if not switching and os.clock() - lastSwapAt > SWAP_COOLDOWN then
                    if leadHasFainted() then
                        local swapSlot = selectBestSwapSlot()
                        if swapSlot then
                            print("[Battle] Lead fainted — auto-swapping to slot " .. swapSlot)
                            lastSwapAt = os.clock()
                            task.spawn(function()
                                executeAutoSwitch(swapSlot)
                            end)
                        else
                            print("[Battle] Lead fainted but no available swap slots.")
                        end
                    end
                end

                -- Fire best move on our turn
                if not switching and os.clock() - lastFireAt > FIRE_COOLDOWN then
                    fireMove()
                    lastFireAt = os.clock()
                end
            end
            task.wait(TICK_RATE)
        end

        print("[Battle] Auto-battle stopped.")
    end)
end

function Battle.stop()
    running = false
    print("[Battle] Stopped.")
end

function Battle.waitForEnd(timeout)
    timeout = timeout or 120
    local deadline = tick() + timeout
    while tick() < deadline do
        if not getCurrentBattle() then return true end
        RunService.Heartbeat:Wait()
    end
    warn("[Battle] waitForEnd timed out after " .. timeout .. "s.")
    return false
end

function Battle.runAndWait(timeout)
    Battle.start()
    local ok = Battle.waitForEnd(timeout or 120)
    Battle.stop()
    return ok
end

-- Manually trigger a swap to a specific slot (1-indexed party slot, 2-5 only)
function Battle.swap(slot)
    task.spawn(function() executeAutoSwitch(slot) end)
end

-- Read current party state (for debugging)
function Battle.getPartyState()
    return partyState, activeSlot
end

return Battle
