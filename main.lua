-- main.lua
-- Entry point for the Loomian Legacy macro.
-- Paste this entire file into your executor, or loadstring it from the raw GitHub URL:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/abdyzam50-rgb/2317402bska/main/main.lua"))()

local BRANCH = "main"
local REPO   = "https://raw.githubusercontent.com/abdyzam50-rgb/2317402bska/" .. BRANCH

local function loadModule(name)
    local url = REPO .. "/modules/" .. name .. ".lua"
    local src = game:HttpGet(url)
    local chunk, compileErr = loadstring(src)
    if not chunk then
        error("[Main] Compile error in '" .. name .. "': " .. tostring(compileErr))
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        error("[Main] Runtime error in '" .. name .. "': " .. tostring(result))
    end
    print("[Main] Loaded: " .. name)
    return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Load modules
-- ─────────────────────────────────────────────────────────────────────────────

local Movement   = loadModule("movement")
local Dialogue   = loadModule("dialogue")
local Battle     = loadModule("battle")
local Heal       = loadModule("heal")
local Shop       = loadModule("shop")
local Trainer    = loadModule("trainer")
local Objectives = loadModule("objectives")

Movement.setDialogueCheck(function() return Dialogue.isChatting() end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Start background monitors (run for the entire session)
-- ─────────────────────────────────────────────────────────────────────────────

Dialogue.start()    -- auto-skips NPC dialogue
Heal.start()        -- auto-heals when HP is low
Shop.start()        -- auto-buys potions when stock is low
Battle.start()      -- auto-battles with best-move + auto-swap
Objectives.start()  -- reacts to objective text → teleports through story waypoints

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: wait for dialogue to start then fully finish
-- ─────────────────────────────────────────────────────────────────────────────

local function waitForDialogue(startTimeout, endTimeout)
    local started = Dialogue.waitForStart(startTimeout or 10)
    if not started then
        warn("[Main] No dialogue detected within timeout — continuing anyway.")
        return
    end
    Dialogue.waitForEnd(endTimeout or 60)
    task.wait(0.5)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Story sequence
-- ─────────────────────────────────────────────────────────────────────────────

print("\n[Main] ── Starting story sequence ──\n")

-- STEP 1: Cave entrance — nudges until the cutscene trigger fires
print("[Main] Step 1: Cave entrance")
Movement.teleportToCave()
waitForDialogue(8, 90)

-- STEP 2: Lab door — starter is given automatically through the cutscene
print("[Main] Step 2: Lab")
Movement.teleportToLab()
waitForDialogue(8, 90)

-- STEP 3: Post-lab battle
print("[Main] Step 3: Waiting for post-lab battle to finish...")
Battle.waitForEnd(180)

print("[Main] Battle done. Waiting for any post-battle dialogue...")
waitForDialogue(5, 30)

print("\n[Main] ── Initial sequence complete! ──")
print("[Main] Heal, Dialogue, Battle, and Objectives monitors remain active.")
print("[Main] Add further waypoints below as CFrames become available.\n")

-- ─────────────────────────────────────────────────────────────────────────────
-- Add further steps here once CFrames / triggers are confirmed in-game:
--
-- Movement.teleportToRoute1Gate()
-- waitForDialogue(5, 30)
-- Battle.waitForEnd(120)
-- ...
-- ─────────────────────────────────────────────────────────────────────────────
