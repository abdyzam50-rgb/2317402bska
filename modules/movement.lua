-- movement.lua
-- Handles all teleportation logic for the macro.
-- Each teleport function is self-contained and safe to call sequentially.

local Movement = {}

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local localPlayer  = Players.LocalPlayer

-- Returns the character's HumanoidRootPart, waiting if needed after respawn.
local function getHRP()
    local char = localPlayer.Character or localPlayer.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart", 10)
end

-- Fires touch begin/end on a part if the executor supports firetouchinterest.
local function triggerTouch(hrp, part)
    hrp.CFrame = part.CFrame
    task.wait(0.05)
    if firetouchinterest then
        firetouchinterest(hrp, part, 0)
        task.wait(0.05)
        firetouchinterest(hrp, part, 1)
    end
end

-- Waits until the screen-fade (black overlay in PlayerGui) appears then
-- disappears again, or bails out after `timeout` seconds.
-- Loomian Legacy uses a ColorCorrectionEffect / black Frame during floor transitions.
local function waitForFadeComplete(timeout)
    timeout = timeout or 8
    local playerGui = localPlayer:WaitForChild("PlayerGui", 5)
    if not playerGui then task.wait(timeout) return end

    local deadline = tick() + timeout
    local fadeDetected = false

    -- Poll every frame looking for a fully-opaque black Frame anywhere in PlayerGui.
    while tick() < deadline do
        for _, gui in ipairs(playerGui:GetChildren()) do
            local frame = gui:FindFirstChildWhichIsA("Frame", true)
            if frame and frame.BackgroundColor3 == Color3.new(0, 0, 0)
               and frame.BackgroundTransparency == 0 then
                fadeDetected = true
                break
            end
        end
        if fadeDetected then break end
        RunService.Heartbeat:Wait()
    end

    -- Now wait for the black frame to go away (fade back in).
    if fadeDetected then
        while tick() < deadline do
            local stillFading = false
            for _, gui in ipairs(playerGui:GetChildren()) do
                local frame = gui:FindFirstChildWhichIsA("Frame", true)
                if frame and frame.BackgroundColor3 == Color3.new(0, 0, 0)
                   and frame.BackgroundTransparency == 0 then
                    stillFading = true
                    break
                end
            end
            if not stillFading then break end
            RunService.Heartbeat:Wait()
        end
    else
        -- Fade never detected; fall back to a fixed wait so we don't softlock.
        task.wait(3)
    end

    -- Small buffer after fade clears before acting.
    task.wait(0.3)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TELEPORT 1
-- Teleports to YourHomeFloor2 Exit (or Entrance) and fires the touch event
-- to trigger the game's floor-transition logic.
-- ─────────────────────────────────────────────────────────────────────────────
function Movement.teleportFloor2Exit(targetName)
    targetName = targetName or "Exit"

    local hrp = getHRP()
    if not hrp then
        warn("[Movement] Could not find HumanoidRootPart for Floor2 teleport.")
        return false
    end

    local floor2 = workspace:FindFirstChild("YourHomeFloor2")
    if not floor2 then
        warn("[Movement] YourHomeFloor2 not found in Workspace.")
        return false
    end

    local target = floor2:FindFirstChild(targetName)
    if not (target and target:IsA("BasePart")) then
        warn("[Movement] Target '" .. targetName .. "' not found in YourHomeFloor2.")
        return false
    end

    print("[Movement] Teleporting to YourHomeFloor2." .. targetName)
    triggerTouch(hrp, target)
    print("[Movement] Touch fired. Waiting for transition fade...")

    waitForFadeComplete(8)
    print("[Movement] Fade complete. Ready for next action.")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TELEPORT 2
-- After the floor transition, teleports directly to YourHomeFloor1.Mom.
-- ─────────────────────────────────────────────────────────────────────────────
function Movement.teleportToMom()
    local hrp = getHRP()
    if not hrp then
        warn("[Movement] Could not find HumanoidRootPart for Mom teleport.")
        return false
    end

    local floor1 = workspace:FindFirstChild("YourHomeFloor1")
    if not floor1 then
        warn("[Movement] YourHomeFloor1 not found in Workspace.")
        return false
    end

    local mom = floor1:FindFirstChild("Mom")
    if not (mom and mom:IsA("BasePart")) then
        warn("[Movement] 'Mom' not found in YourHomeFloor1.")
        return false
    end

    print("[Movement] Teleporting to YourHomeFloor1.Mom")
    hrp.CFrame = mom.CFrame + Vector3.new(0, 3, 0)
    task.wait(0.1)
    print("[Movement] Arrived at Mom.")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TELEPORT 3
-- Teleports to YourHomeFloor1.Exit (the front door) and fires the touch event
-- to trigger the transition outside the house into the overworld.
-- ─────────────────────────────────────────────────────────────────────────────
function Movement.teleportFloor1Exit()
    local hrp = getHRP()
    if not hrp then
        warn("[Movement] Could not find HumanoidRootPart for Floor1 Exit teleport.")
        return false
    end

    local floor1 = workspace:FindFirstChild("YourHomeFloor1")
    if not floor1 then
        warn("[Movement] YourHomeFloor1 not found in Workspace.")
        return false
    end

    local exit = floor1:FindFirstChild("Exit")
    if not (exit and exit:IsA("BasePart")) then
        warn("[Movement] 'Exit' not found in YourHomeFloor1.")
        return false
    end

    print("[Movement] Teleporting to YourHomeFloor1.Exit")
    triggerTouch(hrp, exit)
    print("[Movement] Touch fired. Waiting for transition fade...")

    waitForFadeComplete(8)
    print("[Movement] Fade complete. Ready for next action.")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TELEPORT 4
-- Teleports directly to the Cave (Mine) entrance CFrame.
-- The cutscene / NPC dialogue starts automatically on arrival;
-- the caller is responsible for running Dialogue.start() before this
-- and waiting for the cutscene to finish before proceeding.
-- ─────────────────────────────────────────────────────────────────────────────
local CAVE_CFRAME = CFrame.new(313.82, 69.11, 282.87)

function Movement.teleportToCave()
    local hrp = getHRP()
    if not hrp then
        warn("[Movement] Could not find HumanoidRootPart for Cave teleport.")
        return false
    end

    print("[Movement] Teleporting to Cave entrance.")
    hrp.CFrame = CAVE_CFRAME
    task.wait(0.1)
    print("[Movement] Arrived at Cave. Awaiting cutscene/dialogue.")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TELEPORT 5
-- Teleports to the Lab door. Entering triggers a cutscene; Dialogue.start()
-- handles skipping it. After the cutscene the player must manually choose
-- their starter Loomian — the story sequence pauses here and waits for the
-- caller to signal that the pick is complete before resuming.
-- ─────────────────────────────────────────────────────────────────────────────
local LAB_DOOR_CFRAME = CFrame.new(-204.53, 70.01, 190.36)

function Movement.teleportToLab()
    local hrp = getHRP()
    if not hrp then
        warn("[Movement] Could not find HumanoidRootPart for Lab teleport.")
        return false
    end

    print("[Movement] Teleporting to Lab door.")
    hrp.CFrame = LAB_DOOR_CFRAME
    task.wait(0.1)
    print("[Movement] Arrived at Lab. Awaiting cutscene/dialogue.")
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SEQUENCE: Floor2 Exit → wait for fade → Mom
-- Call this to run both teleports back-to-back.
-- ─────────────────────────────────────────────────────────────────────────────
function Movement.runFloor2ToMomSequence(exitName)
    local ok = Movement.teleportFloor2Exit(exitName or "Exit")
    if not ok then
        warn("[Movement] Sequence aborted: Floor2 teleport failed.")
        return false
    end
    return Movement.teleportToMom()
end

return Movement
