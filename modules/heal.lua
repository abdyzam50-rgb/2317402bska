-- heal.lua
-- Auto-healer using the game's internal _G._p API, reverse-engineered from
-- the MrJack LL module bytecode dump.
--
-- Heal flow (from bytecode strings):
--   1. Network:get("PDS","areFullHealth") → skip if already full
--   2. Disable walking, fastClose menus
--   3. Utilities:FadeOut()
--   4. unbindIndoorCam() + loadChunk to health center
--   5. getDoor("HealthCenter") → getRoom() → getHealer()
--   6. healer:heal() → NPCChat:manualAdvance() → healer:Destroy()
--   7. Utilities:FadeIn(), re-enable walking

local Heal = {}

local RunService = game:GetService("RunService")

local DEFAULT_THRESHOLD = 0.5
local CHECK_INTERVAL    = 3

-- ─────────────────────────────────────────────────────────────────────────────
-- Registry scan — shared _G._p pattern
-- ─────────────────────────────────────────────────────────────────────────────

local _p = nil
local _findPFailedAt = nil

local function findP()
    if _findPFailedAt and os.clock() - _findPFailedAt < 5 then return nil end
    for _, fn in pairs(debug.getregistry()) do
        if type(fn) == "function" then
            for _, upvalue in pairs(debug.getupvalues(fn)) do
                local ok, result = pcall(function() return upvalue.NPCChat end)
                if ok and type(result) == "table" then
                    _findPFailedAt = nil
                    return upvalue
                end
            end
        end
    end
    _findPFailedAt = os.clock()
    return nil
end

local function getP()
    if type(_p) ~= "table" then _p = findP() end
    return _p
end

local function safeGet(obj, key)
    if type(obj) ~= "table" then return nil end
    local ok, v = pcall(function() return obj[key] end)
    return ok and v or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HP check via game's own Network:get("PDS","areFullHealth")
-- Falls back to reading party slots directly if Network unavailable.
-- ─────────────────────────────────────────────────────────────────────────────

local function isFullHealth()
    local p = getP()
    if type(p) ~= "table" then return true end -- assume fine if no data

    -- Primary: game's own check (from bytecode: Network:get("PDS","areFullHealth"))
    local network = safeGet(p, "Network")
    if type(network) == "table" and type(network.get) == "function" then
        local ok, result = pcall(function()
            return network:get("PDS", "areFullHealth")
        end)
        if ok and type(result) == "boolean" then
            return result
        end
        -- result may be a table with .data
        if ok and type(result) == "table" then
            local data = safeGet(result, "data")
            if type(data) == "boolean" then return data end
        end
    end

    -- Fallback: scan party slots
    for _, key in ipairs({ "Party", "PartyManager" }) do
        local party = safeGet(p, key)
        local slots = type(party) == "table" and (safeGet(party, "slots") or party) or nil
        if type(slots) == "table" then
            for i = 1, 6 do
                local slot = slots[i]
                if type(slot) == "table" then
                    local hp    = safeGet(slot, "health") or safeGet(slot, "hp") or 0
                    local maxHp = safeGet(slot, "maxHealth") or safeGet(slot, "maxHp") or 1
                    if maxHp > 0 and (hp / maxHp) < DEFAULT_THRESHOLD then
                        return false
                    end
                end
            end
            return true
        end
    end

    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Core heal sequence (reverse-engineered from MrJack bytecode)
-- ─────────────────────────────────────────────────────────────────────────────

local function performHeal()
    local p = getP()
    if type(p) ~= "table" then
        warn("[Heal] _p not available — cannot heal.")
        return
    end

    local utilities    = safeGet(p, "Utilities")
    local masterCtrl   = safeGet(p, "MasterControl")
    local dataManager  = safeGet(p, "DataManager")
    local menu         = safeGet(p, "Menu")
    local chat         = safeGet(p, "NPCChat")

    -- Announce heal in NPC chat if available (matches MrJack: NPCChat:Say("[ma][MrJack]Auto healing..."))
    if type(chat) == "table" and type(safeGet(chat, "Say")) == "function" then
        pcall(function() chat:Say("[ma][Macro]Auto healing...") end)
    end

    -- 1. Disable walking
    if type(masterCtrl) == "table" then
        pcall(function() masterCtrl.WalkEnabled = false end)
    end

    -- 2. Fast-close any open menus
    if type(menu) == "table" and type(safeGet(menu, "fastClose")) == "function" then
        pcall(function() menu:fastClose() end)
    end

    -- 3. Fade out
    if type(utilities) == "table" and type(safeGet(utilities, "FadeOut")) == "function" then
        pcall(function() utilities:FadeOut(0.3) end)
        task.wait(0.4)
    end

    -- 4. Unbind indoor camera if present
    if type(utilities) == "table" and type(safeGet(utilities, "unbindIndoorCam")) == "function" then
        pcall(function() utilities:unbindIndoorCam() end)
    end

    -- 5. Navigate to HealthCenter via DataManager chunk API
    local healed = false
    if type(dataManager) == "table" then
        local ok = pcall(function()
            local chunk = dataManager.currentChunk

            -- loadChunk to health center region if needed
            if type(chunk) == "table" and type(chunk.getDoor) == "function" then
                local door = chunk:getDoor("HealthCenter")
                if door and type(door.getRoom) == "function" then
                    local room = door:getRoom()
                    if room and type(room.getHealer) == "function" then
                        local healer = room:getHealer()
                        if healer then
                            task.wait(0.3)
                            if type(healer.heal) == "function" then
                                healer:heal()
                                healed = true
                            end
                            task.wait(0.5)
                            -- Advance the heal dialogue
                            if type(chat) == "table" and type(safeGet(chat, "manualAdvance")) == "function" then
                                pcall(function() chat:manualAdvance() end)
                            end
                            task.wait(0.2)
                            if type(healer.Destroy) == "function" then
                                pcall(function() healer:Destroy() end)
                            end
                        end
                    end
                end
            end
        end)
        if not ok then
            warn("[Heal] Chunk-based heal failed, trying TeleportToSpawnBox fallback.")
        end
    end

    -- 6. Fallback: TeleportToSpawnBox (seen in bytecode alongside heal flow)
    if not healed and type(utilities) == "table" then
        if type(safeGet(utilities, "TeleportToSpawnBox")) == "function" then
            pcall(function() utilities:TeleportToSpawnBox() end)
            task.wait(1)
        end
    end

    -- 7. Fade back in
    if type(utilities) == "table" and type(safeGet(utilities, "FadeIn")) == "function" then
        task.wait(0.2)
        pcall(function() utilities:FadeIn(0.3) end)
    end

    -- 8. Re-enable walking
    if type(masterCtrl) == "table" then
        pcall(function() masterCtrl.WalkEnabled = true end)
    end

    print("[Heal] Heal sequence complete.")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running   = false
local healing   = false
local threshold = DEFAULT_THRESHOLD

function Heal.start(options)
    if running then return end
    options   = options or {}
    threshold = options.threshold or DEFAULT_THRESHOLD
    running   = true
    healing   = false
    getP()

    task.spawn(function()
        print(string.format("[Heal] Monitor started (threshold %.0f%%).", threshold * 100))
        while running do
            if not healing and not isFullHealth() then
                healing = true
                print("[Heal] Triggering heal...")
                pcall(performHeal)
                healing = false
                print("[Heal] Heal complete.")
            end
            task.wait(CHECK_INTERVAL)
        end
        print("[Heal] Monitor stopped.")
    end)
end

function Heal.stop()
    running = false
    print("[Heal] Stopped.")
end

function Heal.isHealing()
    return healing
end

-- Block until not currently healing (useful for story sequence to wait)
function Heal.waitIfHealing()
    while healing do
        RunService.Heartbeat:Wait()
    end
end

-- One-shot: heal right now if not full. Blocks until done.
function Heal.checkAndHeal()
    if not isFullHealth() then
        healing = true
        pcall(performHeal)
        healing = false
    end
end

-- Override the performHeal function (for future MrJack hook-in if needed)
function Heal.setPerformHeal(fn)
    if type(fn) == "function" then
        performHeal = fn
        print("[Heal] performHeal() overridden.")
    end
end

return Heal
