-- dialogue.lua
-- Skips NPC dialogue by directly calling the game's internal NPCChat module
-- methods and setting fast-forward flags. Falls back to VirtualInputManager
-- click on the ChatBox if NPCChat cannot be found in the registry.

local Dialogue = {}

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- ─────────────────────────────────────────────────────────────────────────────
-- Registry scan: find the game's internal module table (_p) that holds NPCChat.
-- Results are cached; on failure, backs off 5 s before retrying.
-- ─────────────────────────────────────────────────────────────────────────────

local _p = nil
local _findPFailedAt = nil

local function findP()
    if _findPFailedAt and os.clock() - _findPFailedAt < 5 then
        return nil
    end

    for _, fn in pairs(debug.getregistry()) do
        if type(fn) == "function" then
            for _, upvalue in pairs(debug.getupvalues(fn)) do
                local ok, result = pcall(function()
                    return upvalue.NPCChat
                end)
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
    if type(_p) ~= "table" then
        _p = findP()
    end
    return _p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper: call a list of method names on obj if they exist (all pcall-guarded).
-- ─────────────────────────────────────────────────────────────────────────────

local function callIfPresent(obj, methods)
    for _, name in ipairs(methods) do
        local method = type(obj) == "table" and rawget(obj, name) or nil
        if type(method) == "function" then
            pcall(method, obj)
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- isChatting: true when a dialogue box is currently active.
-- Primary check: NPCChat:isChatting() — game's own flag.
-- Fallback: ChatBox frame visibility in FrontGui.
-- ─────────────────────────────────────────────────────────────────────────────

local function isChatting()
    local p = getP()
    if type(p) == "table" and type(p.NPCChat) == "table" then
        local ok, result = pcall(function()
            if type(p.NPCChat.isChatting) == "function" then
                return p.NPCChat:isChatting()
            end
        end)
        if ok and result then
            return true
        end
    end

    -- GUI fallback
    local frontGui = playerGui:FindFirstChild("FrontGui")
    local chatBox  = frontGui and frontGui:FindFirstChild("ChatBox", true)
    if chatBox and chatBox.Visible and chatBox.AbsoluteSize.X > 50 then
        return true
    end

    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- skipCurrent: advances / clears the active dialogue by whatever means work.
-- ─────────────────────────────────────────────────────────────────────────────

local function skipCurrent()
    local p = getP()
    local chat = type(p) == "table" and p.NPCChat or nil

    if type(chat) == "table" then
        -- Set all speed/skip flags the game respects.
        pcall(function()
            chat.fastForward        = true
            chat.skipping           = true
            chat.TextSpeedMultiplier = 100
        end)

        -- Advance if the game is waiting for the player to click.
        pcall(function()
            if type(chat.isAwaitingManualAdvance) == "function"
                and chat:isAwaitingManualAdvance()
                and type(chat.manualAdvance) == "function"
            then
                chat:manualAdvance()
                return
            end
        end)

        -- Broad method sweep covers every known advance/finish variant.
        callIfPresent(chat, {
            "manualAdvance", "ManualAdvance",
            "advance",       "Advance",
            "next",          "Next",
            "skip",          "Skip",
            "close",         "Close",
            "finish",        "Finish",
            "continue",      "Continue",
        })

        -- Force-clear lingering conversations.
        pcall(function()
            if type(chat.isChatting) == "function" and chat:isChatting()
                and type(chat.clear) == "function"
            then
                chat:clear()
            end
        end)

        return
    end

    -- Fallback: VirtualInputManager click on the ChatBox frame.
    local utilities = type(p) == "table" and p.Utilities or nil
    local frontGui  = (utilities and utilities.frontGui)
                   or playerGui:FindFirstChild("FrontGui")

    if frontGui then
        for _, name in ipairs({ "ChatBox", "ChatArrowPointer" }) do
            local item = frontGui:FindFirstChild(name, true)
            if item and item:IsA("GuiObject") and item.Visible then
                -- Try firesignal / Activate before VIM.
                if type(firesignal) == "function" then
                    pcall(function() firesignal(item.Activated) end)
                end
                pcall(function() item:Activate() end)

                pcall(function()
                    local center = item.AbsolutePosition + item.AbsoluteSize / 2
                    VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, true,  game, 0)
                    task.wait(0.025)
                    VirtualInputManager:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
                end)
                return
            end
        end
    end

    -- Last resort: click the bottom-centre of the viewport.
    pcall(function()
        local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
                or Vector2.new(1280, 720)
        VirtualInputManager:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.72, 0, true,  game, 0)
        task.wait(0.025)
        VirtualInputManager:SendMouseButtonEvent(vp.X * 0.5, vp.Y * 0.72, 0, false, game, 0)
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running       = false
local monitorThread = nil

function Dialogue.start()
    if running then return end
    running = true

    -- Warm up the registry scan immediately.
    getP()

    monitorThread = task.spawn(function()
        print("[Dialogue] Monitoring for NPC chat...")

        while running do
            if isChatting() then
                skipCurrent()
                RunService.RenderStepped:Wait()
            else
                task.wait(0.05)
            end
        end

        print("[Dialogue] Monitor stopped.")
    end)
end

function Dialogue.stop()
    running = false
    print("[Dialogue] Stopped.")
end

-- One-shot: skip whatever dialogue is active right now.
function Dialogue.skipOnce()
    if isChatting() then
        skipCurrent()
    end
end

return Dialogue
