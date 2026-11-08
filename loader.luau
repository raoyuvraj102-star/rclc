-- RCLC Premium (Roblox HVH Addon) — Hardened Build
-- Fixed: hookToolActivate closure, stopTransloc missing, VOID_CHAOS_MAX global,
--        connection leaks, workspace.GetDescendants spam, global pollution.
-- Requires: exploit env with hookfunction, getrawmetatable, getgc, sethiddenproperty, checkcaller

do
-- ============================================================
-- SERVICES & CORE REFERENCES
-- ============================================================
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local CoreGui            = game:GetService("CoreGui")
local TeleportService    = game:GetService("TeleportService")

local localPlayer        = Players.LocalPlayer
local camera             = workspace.CurrentCamera

-- Character refs (updated in onCharacterAdded)
local character, rootPart, humanoid

-- Connection registry
local connections        = {}

-- Exploit globals check
local mhapiPresent       = _G.Mhapi ~= nil

-- ============================================================
-- UI LIBRARY
-- ============================================================
local AirflowUI = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/PookiePepelsss/Airflow-UI/refs/heads/main/Source.luau"
))()

AirflowUI:LoadFont({ Name = "ValleySans" })

local window = AirflowUI:CreateWindow({
    Name = "RCLC",
    LoadingSubtitle = "RCLC Premium",
    Theme = "Default",
    ToggleUIKeybind = "RightControl",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "RCLCPremium",
        FileName = "default",
    },
    Home = {
        Name = "Home",
        Stats = { "FPS", "Ping", "Executor", "Game", "Time" },
        Pages = {
            { Name = "Info", Icon = "info", Content = "RCLC Premium Lua - #1 HVH Addon" },
        },
    },
})

-- ============================================================
-- UTILITIES
-- ============================================================
local function notify(title, message, kind, duration)
    if mhapiPresent and _G.Mhapi and _G.Mhapi.Notify then
        pcall(function() _G.Mhapi:Notify(tostring(title).." | "..tostring(message), duration or 3) end)
    else
        pcall(function()
            AirflowUI:Notify({ Title = title, Content = message, Icon = "bell", Type = kind or "Info", Duration = duration or 3 })
        end)
    end
end

local function disconnectConn(name)
    local conn = connections[name]
    if conn then conn:Disconnect(); connections[name] = nil end
end

local function getRoot() return rootPart end

-- Frame budget (max 3 heavy ops / frame)
local frameStamp, frameCount = -1, 0
local function frameBudgetOk()
    local cf = math.floor(tick()*60 + 0.5)
    if cf ~= frameStamp then frameStamp, frameCount = cf, 0 end
    if frameCount >= 3 then return false end
    frameCount += 1; return true
end

-- ============================================================
-- CONFIG TABLES (Single source of truth)
-- ============================================================
local voidCfg = {
    VOID_ENABLED = false, VOID_METHOD = "Quantum",
    VOID_ATTACKER_INTERVAL = 4, VOID_ATTACKER_DURATION = 0.4,
    VOID_BAIT_INTERVAL = 3, VOID_BAIT_DURATION = 0.4,
    SPEED = 1e9, CHAOS = 0.98,
    BASE_X = 0, BASE_Y = 0, BASE_Z = 0,
    RADIUS = 1e7, VOID_Y_MIN = -1e7, VOID_Y_MAX = 1e7,
    VOID_WRITES_PER_FRAME = 1, VOID_INTERP = true, VOID_INTERP_ALPHA = 0.35,
    VOID_HOLD = 0, VOID_JITTER = 0,
    VOID_ANTIFLING = true, VOID_ANTIVOID = false, VOID_SAFE_RADIUS = 0,
    VOID_LOG = false, VOID_CURVE_FREQ = 0.7, VOID_CURVE_AMP = 0.5,
    VOID_DRIFT_SPEED = 1, VOID_GRID_SIZE = 8,
    VOID_SCREEN_DEPTH_MIN = 50, VOID_SCREEN_DEPTH_MAX = 5e4,
    VOID_CHASE_MAX = 200, VOID_MIRROR_AXIS = "X",
    VOID_PREDICT_LEAD = 0.2, VOID_DURATION_ENABLED = false, VOID_DURATION = 10,
    WIREFRAME_ENABLED = false,
}

local orbitCfg = { orbitEnabled = false, orbitSpeed = 90, orbitDist = 8, orbitHeight = 0, orbitMode = "Clockwise", orbitLockDist = 1e7 }

local predictCfg = { predEnabled = false, predRadius = 150, predDodgeDist = 80, predCooldown = 0.05, predReactionTime = 0.12, predBulletSpeed = 1000, predAimThreshold = 0.7, predKinematic = true, predPredictive = true, predLookahead = 0.5, predInfiniteRange = false }

local translocCfg = { enabled = false, frequency = 1e6, jitterX = 1e7, jitterY = 1e7, fixedZ = 1, fakeVel = true, fakeVelMag = 1e10, burstMode = false, burstCount = 10 }

local fakePosCfg = { enabled = false, radius = 1e6, height = 999999999, yDist = 999999999, speed = 1e5, pattern = "Scatter", distribution = "Random", axisLock = "None", randomizeEveryFrame = false, scatterAngle = 360, pulseRadius = false, pulseRadiusMin = 100, pulseRadiusMax = 999999, pulseSpeed = 2, layeredFake = false, layerCount = 3, chaosMode = false, chaosMult = 5 }

local velDesyncCfg = { enabled = false, intensity = 50, angle = 90, jitter = 20, flip = false, speed = 10, randomizeAngle = false, angleMin = 0, angleMax = 360, multiVector = false, vectorCount = 3, spikeMode = false, spikeInterval = 0.05, spikeMag = 1e6, invertOnTimer = false, invertInterval = 0.2, oscillate = false, oscillateFreq = 5, oscillateAmp = 30, noiseVel = false, noiseScale = 1, burstDesync = false, burstEvery = 0.1, burstMag = 5e5, counterVel = false, rotateVel = false, rotateVelSpeed = 180 }

local antiAimCfg = { enabled = false, speed = 5000, chaosLevel = 100, pitch = 360, yaw = 360 }

local undergroundCfg = { enabled = false, depth = 1.5, orbitRadius = 3, orbitSpeed = 200, spinSpeed = 720 }

local fastMeleeCfg = { enabled = false, cached = {}, cooldown = 0, animSpeed = 100, remoteCount = 5 }

local fastGunState = { primaryOn = false, primaryHits = 0, lastPatch = 0, itemLib = nil }

local excludedGuns = { Sniper = true, Crossbow = true, Bow = true, RPG = true }

local killAuraCfg = { enabled = false, fireRate = 0.02, weaponSlot = "Primary", radius = 5000, headshotOffset = 1, jitter = 0.02, autoEquip = true }

-- Module refs (lazy loaded)
local Utility, EnumLibrary, FighterController

-- Runtime state
local lastShotTime = 0
local killAuraConn, autoEquipThread
local voidState = { t = 0, pos = Vector3.zero, vel = Vector3.zero, phase = 0, seed = os.clock(), anchor = Vector3.zero }
local voidPhaseTime, voidBaitPhase = 0, false
local orbitAngle = 0
local lastPredFire = 0
local lastToolUse = {}
local hookedTools = {} -- [tool] = originalActivateFunction
local hookedToolCount = 0
local undergroundAngle = 0
local undergroundConn
local savedRootJointC0
local translocConn, translocTimer = nil, 0
local fakePosHeartbeat, fakePosRender, fakePosAnchor, fakePosAngle, fakePosHue, fakePosLastWrite, fakePosTime
local velDesyncConn, velDesyncConn2, desyncSavedVel, desyncAngle, desyncFlipTimer, desyncOscTime, desyncBurstTimer, desyncFlipState = nil, nil, nil, 0, 0, 0, 0, false
local fastMeleeConn
local wireframeFolder, wireframeBoxes = nil, {}
local positionHud, positionHudLabels
local velTrackers = {}
local npcCache, npcCacheTime = {}, 0

-- Weapon slot mapping
local weaponSlots = { Primary = 1, Secondary = 2, Melee = 3 }
local function weaponSlotIndex() return weaponSlots[killAuraCfg.weaponSlot] or 1 end

-- ============================================================
-- GAME MODULES (Lazy)
-- ============================================================
local function ensureModules()
    if Utility and EnumLibrary and FighterController then return true end
    local ok = pcall(function()
        Utility = require(ReplicatedStorage.Modules.Utility)
        EnumLibrary = require(ReplicatedStorage.Modules.EnumLibrary)
        local ps = localPlayer:FindFirstChild("PlayerScripts")
        local ctrl = ps and ps:FindFirstChild("Controllers")
        if ctrl and ctrl:FindFirstChild("FighterController") then
            FighterController = require(ctrl.FighterController)
        end
    end)
    return ok and Utility and EnumLibrary and FighterController
end

-- ============================================================
-- FAST GUN / KILL AURA
-- ============================================================
local function patchGun(gunStats)
    if type(gunStats) ~= "table" then return false end
    local changed = false
    if gunStats.ShootSpread then gunStats.ShootSpread = 0; changed = true end
    if gunStats.ShootAccuracy then gunStats.ShootAccuracy = 0; changed = true end
    if gunStats.ShootRecoil then gunStats.ShootRecoil = 0; changed = true end
    if gunStats.ShootCooldown then gunStats.ShootCooldown = 0.001; changed = true end
    if gunStats.ShootBurstCooldown then gunStats.ShootBurstCooldown = 0.001; changed = true end
    return changed
end

local function patchEquippedGuns()
    if not fastGunState.itemLib then
        local ok, lib = pcall(function() return require(ReplicatedStorage.Modules.ItemLibrary).Items end)
        if ok and type(lib) == "table" then fastGunState.itemLib = lib else notify("Fast Gun", "ItemLibrary unavailable", "Error", 3); return false end
    end
    local count = 0
    for name, data in pairs(fastGunState.itemLib) do
        if not excludedGuns[name] and type(data) == "table" and patchGun(data) then count += 1 end
    end
    fastGunState.primaryHits, fastGunState.lastPatch = count, tick()
    notify("Fast Gun", ("Patched %d guns"):format(count), "Success", 3)
    return count > 0
end

local function fastGunTick()
    if fastGunState.primaryOn then task.spawn(patchEquippedGuns) end
end

local function startAutoEquip()
    if autoEquipThread then task.cancel(autoEquipThread) end
    autoEquipThread = task.spawn(function()
        while killAuraCfg.enabled and killAuraCfg.autoEquip do
            task.wait(1)
            if not killAuraCfg.enabled then break end
            if FighterController and FighterController.LocalFighter and not FighterController.LocalFighter.EquippedItem then
                pcall(function() FighterController.LocalFighter:EquipItem(weaponSlotIndex()) end)
            end
        end
    end)
end

local function stopAutoEquip()
    if autoEquipThread then task.cancel(autoEquipThread); autoEquipThread = nil end
end

-- Optimized NPC targeting (spatial query + caching)
local function getNpcTargets()
    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return {} end

    -- Rebuild cache every 0.5s
    if tick() - npcCacheTime > 0.5 then
        npcCache = {}
        npcCacheTime = tick()
        -- Use spatial query for performance
        local overlap = workspace:GetPartBoundsInRadius(myRoot.Position, killAuraCfg.radius, OverlapParams.new())
        for _, part in ipairs(overlap) do
            local model = part:FindFirstAncestorOfClass("Model")
            if model and model ~= myChar and not Players:GetPlayerFromCharacter(model) then
                local hum = model:FindFirstChildWhichIsA("Humanoid")
                local hrp = model:FindFirstChild("HumanoidRootPart")
                local head = model:FindFirstChild("Head")
                if hum and hum.Health > 0 and hrp and head then
                    table.insert(npcCache, { model = model, root = hrp, head = head, dist = (myRoot.Position - hrp.Position).Magnitude })
                end
            end
        end
        table.sort(npcCache, function(a,b) return a.dist < b.dist end)
    end
    return npcCache
end

local function killAuraStep()
    if not killAuraCfg.enabled or not ensureModules() then return end
    if tick() - lastShotTime < killAuraCfg.fireRate then return end

    local targets = getNpcTargets()
    if #targets == 0 then return end

    local char = localPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then return end

    local fighter = FighterController.LocalFighter
    if not fighter or not fighter.EquippedItem then return end

    local target = targets[1]
    local aimPos = target.head.Position + Vector3.new(0, killAuraCfg.headshotOffset, 0)
    local aimCf = CFrame.lookAt(aimPos, target.head.Position)
    local jitter = Vector3.new(
        (math.random()-0.5)*killAuraCfg.jitter,
        (math.random()-0.5)*killAuraCfg.jitter,
        (math.random()-0.5)*killAuraCfg.jitter
    )
    local hitOffset = target.head.CFrame:ToObjectSpace(CFrame.new(aimPos + jitter))

    local payload = {
        [utf8.char(1)] = {
            [utf8.char(0)] = Utility:EncodeCFrame(aimCf),
            [utf8.char(1)] = Utility:EncodeCFrame(target.head.CFrame),
            [utf8.char(2)] = target.head,
            [utf8.char(3)] = Utility:EncodeCFrame(hitOffset),
        }
    }

    pcall(function()
        ReplicatedStorage.Remotes.Replication.Fighter.UseItem:FireServer(
            fighter.EquippedItem:Get("ObjectID"),
            EnumLibrary:ToEnum("StartShooting"),
            payload, nil
        )
    end)
    lastShotTime = tick()
end

local function enableKillAura()
    if killAuraConn then killAuraConn:Disconnect() end
    if killAuraCfg.autoEquip then startAutoEquip() end
    killAuraConn = RunService.Heartbeat:Connect(killAuraStep)
    notify("Kill Aura", "Activated", "Success", 3)
end

local function disableKillAura()
    if killAuraConn then killAuraConn:Disconnect(); killAuraConn = nil end
    stopAutoEquip()
    notify("Kill Aura", "Deactivated", "Warning", 3)
end

-- ============================================================
-- TARGETING HELPERS
-- ============================================================
local function getHead(player)
    if not player or not player.Character then return nil end
    return player.Character:FindFirstChild("Head")
        or player.Character:FindFirstChild("CameraBone", true)
        or player.Character:FindFirstChild("HumanoidRootPart")
end

local function getTracker(player)
    local t = velTrackers[player]
    if not t then
        t = { vel = Vector3.zero, accel = Vector3.zero, lastPos = nil, lastVel = Vector3.zero, lastT = tick() }
        velTrackers[player] = t
    end
    return t
end

local function updateTracker(player, root)
    local tr = getTracker(player)
    local now = tick()
    local dt = now - tr.lastT
    if dt > 0.01 then
        local pos = root.Position
        local vel = root.AssemblyLinearVelocity
        if tr.lastPos and tr.lastVel then
            tr.accel = tr.accel:Lerp((vel - tr.lastVel) / dt, 0.2)
        end
        tr.vel, tr.lastPos, tr.lastVel, tr.lastT = vel, pos, vel, now
    end
    return tr
end

local function sidestepDirection(atkPos, myPos)
    local off = Vector3.new(atkPos.X - myPos.X, 0, atkPos.Z - myPos.Z)
    if off.Magnitude < 0.01 then off = Vector3.xAxis end
    local dir = off.Unit
    local perpL = Vector3.new(-dir.Z, 0, dir.X)
    local perpR = Vector3.new(dir.Z, 0, -dir.X)
    return (math.random(0,1) == 0 and perpL or perpR) + Vector3.new(0, (math.random()-0.5)*0.4, 0)
end

local function scorePlayers(myPos)
    local scores = {}
    if not myPos then return scores end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            local origin = getHead(plr) or hrp
            if hrp and origin then
                local tool = plr.Character:FindFirstChildOfClass("Tool")
                local toMe = myPos - (origin.Position + origin.CFrame.LookVector * 0.5)
                local dist = toMe.Magnitude
                if dist > 0.01 then
                    local tr = updateTracker(plr, hrp)
                    local dot = origin.CFrame.LookVector:Dot(toMe.Unit)
                    local aim = math.max(0, dot)
                    local prox = math.max(0, 1 - dist/250)
                    scores[plr] = {
                        hrp = hrp, dist = dist, aimDot = dot,
                        score = aim*45 + (tool and 25 or 0) + prox*30,
                        hasTool = tool ~= nil, origin = origin, trk = tr
                    }
                end
            end
        end
    end
    return scores
end

-- ============================================================
-- VOID ENGINE
-- ============================================================
local function randomRange(minV, maxV) return minV + math.random()*(maxV-minV) end

local function sanitizeVector(v)
    if not v or typeof(v) ~= "Vector3" then return v end
    local x,y,z = v.X, v.Y, v.Z
    if x~=x or x==math.huge or x==-math.huge then x = voidCfg.BASE_X end
    if y~=y or y==math.huge or y==-math.huge then y = 0 end
    if z~=z or z==math.huge or z==-math.huge then z = voidCfg.BASE_Z end
    y = math.clamp(y, voidCfg.VOID_Y_MIN, voidCfg.VOID_Y_MAX)
    local R = math.abs(voidCfg.RADIUS)
    if R > 0 then
        local dx, dz = x - voidCfg.BASE_X, z - voidCfg.BASE_Z
        local d = math.sqrt(dx*dx + dz*dz)
        if d > R and d > 0 then
            local s = R/d; x = voidCfg.BASE_X + dx*s; z = voidCfg.BASE_Z + dz*s
        end
    end
    return Vector3.new(x,y,z)
end

local function voidTarget(dt)
    local method = voidCfg.VOID_METHOD
    if method == "Freeze Bait" then
        voidPhaseTime += dt
        if voidBaitPhase then
            if voidPhaseTime >= voidCfg.VOID_BAIT_DURATION then voidBaitPhase, voidPhaseTime = false, 0
            else return getRoot() and getRoot().Position or Vector3.zero end
        elseif voidPhaseTime >= voidCfg.VOID_BAIT_INTERVAL then
            voidBaitPhase, voidPhaseTime = true, 0
            return getRoot() and getRoot().Position or Vector3.zero
        end
    elseif method == "Attacker" then
        voidPhaseTime += dt
        if voidBaitPhase then
            if voidPhaseTime >= voidCfg.VOID_ATTACKER_DURATION then voidBaitPhase, voidPhaseTime = false, 0
            else
                local np = nearestPlayerRoot()
                if np and np.Character then
                    local nhrp = np.Character:FindFirstChild("HumanoidRootPart")
                    if nhrp then return nhrp.Position end
                end
            end
        elseif voidPhaseTime >= voidCfg.VOID_ATTACKER_INTERVAL then
            voidBaitPhase, voidPhaseTime = true, 0
            local np = nearestPlayerRoot()
            if np and np.Character then
                local nhrp = np.Character:FindFirstChild("HumanoidRootPart")
                if nhrp then return nhrp.Position end
            end
        end
    elseif method == "Chaos" then
        local maxC = voidCfg.RADIUS -- FIX: was VOID_CHAOS_MAX global
        return sanitizeVector(Vector3.new(
            voidCfg.BASE_X + randomRange(-maxC, maxC),
            randomRange(voidCfg.VOID_Y_MIN, voidCfg.VOID_Y_MAX),
            voidCfg.BASE_Z + randomRange(-maxC, maxC)
        ))
    end
    -- Quantum / default
    local r = voidCfg.RADIUS
    return sanitizeVector(Vector3.new(
        voidCfg.BASE_X + randomRange(-r, r),
        randomRange(voidCfg.VOID_Y_MIN, voidCfg.VOID_Y_MAX),
        voidCfg.BASE_Z + randomRange(-r, r)
    ))
end

local function voidStep(dt)
    voidState.t += dt
    local root = getRoot()
    if not root then return end
    local target = voidTarget(dt)
    if not target then return end
    pcall(function()
        root.CFrame = CFrame.new(target)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

local function enableVoid()
    disconnectConn("void")
    voidState.t, voidState.phase, voidState.vel = 0, 0, Vector3.zero
    voidPhaseTime, voidBaitPhase = 0, false
    local root = getRoot()
    if root then
        voidState.pos = root.Position
        voidState.anchor = root.Position
        pcall(function() root:SetNetworkOwner(localPlayer) end)
    end
    connections.void = (RunService.PreSimulation or RunService.Heartbeat):Connect(function(dt)
        if not voidCfg.VOID_ENABLED then disconnectConn("void"); return end
        if voidCfg.VOID_DURATION_ENABLED and tick() - voidState.t > voidCfg.VOID_DURATION then
            voidCfg.VOID_ENABLED = false
            notify("Void", "Duration reached", "Warning", 2)
            return
        end
        voidStep(dt)
    end)
end

local function disableVoid()
    disconnectConn("void")
    voidCfg.VOID_ENABLED = false
    voidBaitPhase, voidPhaseTime = false, 0
end

-- ============================================================
-- WIREFRAME ESP
-- ============================================================
local function addWireframeBox(part)
    if wireframeBoxes[part] then return end
    local box = Instance.new("BoxHandleAdornment")
    box.Name, box.Adornee, box.AlwaysOnTop, box.ZIndex = "RCLC_Box", part, true, 10
    box.Size, box.Transparency, box.Color3 = Vector3.new(4,6,4), 0.5, Color3.fromRGB(168,85,247)
    box.Parent = wireframeFolder
    wireframeBoxes[part] = box
end

local function enableWireframes()
    if not wireframeFolder then
        wireframeFolder = Instance.new("Folder")
        wireframeFolder.Name, wireframeFolder.Parent = "RCLC_Wireframes", CoreGui
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp then addWireframeBox(hrp) end
        end
    end
    connections.wireframe = Players.PlayerAdded:Connect(function(plr)
        plr.CharacterAdded:Connect(function(char)
            task.wait(0.5)
            if voidCfg.WIREFRAME_ENABLED then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then addWireframeBox(hrp) end
            end
        end)
    end)
end

local function disableWireframes()
    if wireframeFolder then wireframeFolder:Destroy(); wireframeFolder = nil end
    wireframeBoxes = {}
    disconnectConn("wireframe")
end

local function setWireframes(on)
    voidCfg.WIREFRAME_ENABLED = on
    if on then enableWireframes() else disableWireframes() end
end

-- ============================================================
-- ORBIT
-- ============================================================
local function disableOrbit()
    disconnectConn("orbit")
    orbitCfg.orbitEnabled = false
    if humanoid then pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end) end
end

local function enableOrbit()
    disconnectConn("orbit")
    orbitAngle = 0
    if humanoid then pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Physics) end) end
    connections.orbit = RunService.Heartbeat:Connect(function(dt)
        if not orbitCfg.orbitEnabled then disconnectConn("orbit"); return end
        if not rootPart then return end
        if humanoid then pcall(function() if humanoid:GetState()~=Enum.HumanoidStateType.Physics then humanoid:ChangeState(Enum.HumanoidStateType.Physics) end end) end

        local center = rootPart.Position
        local np = nearestPlayerRoot()
        if np and np.Character then
            local nhrp = np.Character:FindFirstChild("HumanoidRootPart")
            if nhrp and (rootPart.Position - nhrp.Position).Magnitude <= orbitCfg.orbitLockDist then
                center = nhrp.Position
            end
        end

        local dir = orbitCfg.orbitMode == "Counter-Clockwise" and -1 or 1
        orbitAngle = (orbitAngle + math.rad(orbitCfg.orbitSpeed) * dir * dt) % (2*math.pi)
        local r = orbitCfg.orbitDist
        local pos = center + Vector3.new(math.cos(orbitAngle)*r, orbitCfg.orbitHeight, math.sin(orbitAngle)*r)

        pcall(function()
            rootPart.CFrame = CFrame.new(pos, Vector3.new(center.X, pos.Y, center.Z))
            rootPart.AssemblyLinearVelocity = Vector3.zero
            rootPart.AssemblyAngularVelocity = Vector3.zero
        end)
    end)
end

-- ============================================================
-- PREDICTION (DODGE)
-- ============================================================
local function hookToolActivate(tool)
    if not tool or hookedTools[tool] or hookedToolCount >= 64 then return end
    hookedToolCount += 1
    -- Capture original via hookfunction (exploit specific)
    local original
    pcall(function()
        original = hookfunction(tool.Activate, function(self, ...)
            if not checkcaller() and self == tool then
                local owner = tool.Parent and tool.Parent.Parent
                if owner and owner ~= localPlayer and owner.Character then
                    lastToolUse[owner] = tick()
                end
            end
            return original(self, ...) -- FIX: call captured original
        end)
    end)
    if original then hookedTools[tool] = original else hookedToolCount -= 1 end
end

local function hookAllPlayerTools()
    -- Single listener for all future tools
    connections.toolHooks = workspace.DescendantAdded:Connect(function(obj)
        if obj:IsA("Tool") then
            local plr = Players:GetPlayerFromCharacter(obj.Parent)
            if plr and plr ~= localPlayer then hookToolActivate(obj) end
        end
    end)
    -- Hook existing
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and plr.Character then
            local tool = plr.Character:FindFirstChildOfClass("Tool")
            if tool then hookToolActivate(tool) end
        end
    end
end

local function disablePrediction()
    disconnectConn("pred")
    disconnectConn("toolHooks")
    for tool, orig in pairs(hookedTools) do pcall(function() hookfunction(tool.Activate, orig) end) end
    hookedTools, hookedToolCount = {}, 0
    predictCfg.predEnabled = false
end

local function enablePrediction()
    disconnectConn("pred")
    hookAllPlayerTools()
    connections.pred = RunService.Heartbeat:Connect(function(dt)
        if not predictCfg.predEnabled then disablePrediction(); return end
        if not rootPart or (humanoid and humanoid.Health <= 0) then return end

        local myPos, myVel = rootPart.Position, rootPart.AssemblyLinearVelocity
        local now = tick()
        local bestThreat, bestScore = nil, 0

        for plr, info in pairs(scorePlayers(myPos)) do
            if info.score > bestScore then bestScore, bestThreat = info.score, { p=plr, d=info } end
        end
        if not bestThreat then return end

        local maxRange = predictCfg.predInfiniteRange and 5e12 or predictCfg.predRadius
        if bestThreat.d.dist > maxRange then return end
        if now - lastPredFire < predictCfg.predCooldown then return end

        local threatened = false
        if (lastToolUse[bestThreat.p] and now - lastToolUse[bestThreat.p] < predictCfg.predReactionTime)
            or bestThreat.d.aimDot > predictCfg.predAimThreshold then
            threatened = true
        end

        if threatened and predictCfg.predPredictive and bestThreat.d.trk and bestThreat.d.trk.vel then
            local trk = bestThreat.d.trk
            local found, dodgeVec = false, Vector3.zero
            for step = 1, 10 do
                local t = predictCfg.predLookahead / 10 * step
                local myF = myPos + myVel * t
                local enF = trk.lastPos + trk.vel * t + 0.5 * trk.accel * t^2
                if math.abs((myF - enF).Magnitude / predictCfg.predBulletSpeed - t) < 0.15 then
                    found = true
                    local dir = (myF - enF).Unit
                    local perpA, perpB = Vector3.new(-dir.Z,0,dir.X), Vector3.new(dir.Z,0,-dir.X)
                    dodgeVec = (math.random(0,1)==0 and perpA or perpB).Unit * predictCfg.predDodgeDist
                    break
                end
            end
            if found and dodgeVec.Magnitude > 0 and frameBudgetOk() then
                local dp = myPos + dodgeVec + Vector3.new(0, (math.random()-0.5)*15, 0)
                pcall(function()
                    rootPart.CFrame = CFrame.new(dp)
                    rootPart.AssemblyLinearVelocity = dodgeVec.Unit * 150
                end)
                lastPredFire = now; return
            end
        end

        if threatened and predictCfg.predKinematic then
            lastPredFire = now
            local side = sidestepDirection(bestThreat.d.hrp.Position, myPos)
            local sp = myPos + side * predictCfg.predDodgeDist
            if frameBudgetOk() then
                pcall(function()
                    rootPart.CFrame = CFrame.new(sp + Vector3.new((math.random()-0.5)*4,0,(math.random()-0.5)*4))
                    rootPart.AssemblyLinearVelocity = side * 150
                end)
            end
        end
    end)
end

-- ============================================================
-- NEAREST PLAYER HELPER
-- ============================================================
local function nearestPlayerRoot()
    if not rootPart then return nil end
    local nearest, bestDist = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = (rootPart.Position - hrp.Position).Magnitude
                if d < bestDist then bestDist, nearest = d, plr end
            end
        end
    end
    return nearest
end

-- ============================================================
-- ANTI-AIM / UNDERGROUND
-- ============================================================
local function enableAntiAim()
    disconnectConn("antiAim")
    connections.antiAim = RunService.Heartbeat:Connect(function(dt)
        if not antiAimCfg.enabled then disconnectConn("antiAim"); return end
        if not rootPart then return end
        local c = antiAimCfg.chaosLevel * 0.01
        local pMax, yMax = math.rad(antiAimCfg.pitch), math.rad(antiAimCfg.yaw)
        local s = antiAimCfg.speed / 5000
        rootPart.CFrame = CFrame.new(rootPart.Position) * CFrame.Angles(
            (math.random()-0.5)*2*pMax*c*s,
            (math.random()-0.5)*2*yMax*c*s,
            (math.random()-0.5)*math.rad(360)*c*s
        )
    end)
end

local function disableAntiAim()
    disconnectConn("antiAim")
    antiAimCfg.enabled = false
end

local function enableUndergroundAA()
    if undergroundConn then undergroundConn:Disconnect() end
    undergroundAngle = 0
    if rootPart and character then
        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local head = character:FindFirstChild("Head")
        if torso and head then
            local neck = head:FindFirstChild("Neck") or character:FindFirstChild("Neck")
            if neck and neck:IsA("Motor6D") then
                savedRootJointC0 = neck.C0
                neck.C0 = CFrame.new(0,0,0) * CFrame.Angles(math.rad(-90),0,0)
            end
        end
    end
    undergroundConn = RunService.Heartbeat:Connect(function(dt)
        if not undergroundCfg.enabled then return end
        local root = getRoot()
        if not root then return end
        undergroundAngle = (undergroundAngle + math.rad(undergroundCfg.orbitSpeed)*dt) % (2*math.pi)
        local ca, sa = math.cos(undergroundAngle), math.sin(undergroundAngle)
        local pos = root.Position + Vector3.new(ca*undergroundCfg.orbitRadius, -undergroundCfg.depth, sa*undergroundCfg.orbitRadius)
        if root.Position.Y - pos.Y > undergroundCfg.depth + 1 then
            pos = Vector3.new(pos.X, root.Position.Y - undergroundCfg.depth, pos.Z)
        end
        local spin = tick() * undergroundCfg.spinSpeed % 360
        pcall(function()
            root.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(spin), 0)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end)
    notify("Underground AA", "Activated", "Success", 3)
end

local function disableUndergroundAA()
    if undergroundConn then undergroundConn:Disconnect(); undergroundConn = nil end
    if rootPart and character and savedRootJointC0 then
        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local head = character:FindFirstChild("Head")
        if torso and head then
            local neck = head:FindFirstChild("Neck") or character:FindFirstChild("Neck")
            if neck and neck:IsA("Motor6D") then neck.C0 = savedRootJointC0 end
        end
    end
    notify("Underground AA", "Deactivated", "Warning", 3)
end

-- ============================================================
-- TRANSLOCATION
-- ============================================================
local function stopTransloc() disableTransloc() end -- FIX: alias

local function enableTransloc()
    if translocConn then translocConn:Disconnect() end
    translocTimer = 0
    translocConn = RunService.Heartbeat:Connect(function(dt)
        if not translocCfg.enabled then stopTransloc(); return end
        if not rootPart then return end
        translocTimer += dt
        local interval = 1 / math.max(translocCfg.frequency, 1)
        local iters = 1
        if interval < dt then
            iters = math.floor(dt/interval)
            iters = math.clamp(iters, 1, 50)
        end
        if translocTimer >= interval then
            translocTimer %= interval
            local origin = rootPart.Position
            local meta = getrawmetatable and getrawmetatable(rootPart)
            local rawNew = meta and rawget(meta, "__newindex")
            for _ = 1, iters do
                local cf = CFrame.new(
                    origin.X + (math.random()*2-1)*translocCfg.jitterX,
                    origin.Y + (math.random()*2-1)*translocCfg.jitterY,
                    translocCfg.fixedZ
                )
                local vel = Vector3.zero
                if translocCfg.fakeVel then
                    local m = translocCfg.fakeVelMag
                    vel = Vector3.new((math.random()-0.5)*m*2, (math.random()-0.5)*m*2, (math.random()-0.5)*m*2)
                end
                if rawNew then
                    pcall(rawNew, rootPart, "CFrame", cf)
                    pcall(rawNew, rootPart, "AssemblyLinearVelocity", vel)
                else
                    pcall(function() rootPart.CFrame = cf; rootPart.AssemblyLinearVelocity = vel end)
                end
            end
        end
    end)
end

local function disableTransloc()
    if translocConn then translocConn:Disconnect(); translocConn = nil end
    translocCfg.enabled = false
end

-- ============================================================
-- FAKE POSITION
-- ============================================================
local function enableFakePos()
    if fakePosHeartbeat then fakePosHeartbeat:Disconnect() end
    if fakePosRender then fakePosRender:Disconnect() end
    fakePosAnchor, fakePosAngle, fakePosHue, fakePosLastWrite, fakePosTime = nil, 0, 0, 0, 0

    fakePosHeartbeat = RunService.Heartbeat:Connect(function(dt)
        if not fakePosCfg.enabled or not rootPart then return end
        fakePosAnchor = rootPart.CFrame
        fakePosTime += dt
        local now = tick()
        local rate = fakePosCfg.randomizeEveryFrame and 99999 or math.max(fakePosCfg.speed, 1)
        if now - fakePosLastWrite < 1/rate then return end
        fakePosLastWrite = now

        local meta = getrawmetatable and getrawmetatable(rootPart)
        local rawNew = meta and rawget(meta, "__newindex")
        local radius = math.max(fakePosCfg.radius, 1)
        if fakePosCfg.pulseRadius then
            radius = fakePosCfg.pulseRadiusMin + (math.sin(fakePosTime*fakePosCfg.pulseSpeed*2*math.pi)*0.5+0.5)*(fakePosCfg.pulseRadiusMax-fakePosCfg.pulseRadiusMin)
        end
        local layers = fakePosCfg.layeredFake and fakePosCfg.layerCount or 1
        for layer = 1, layers do
            local lx, ly, lz = 0, 0, 0
            local lR = radius * (layer/layers)
            if fakePosCfg.chaosMode then lR *= 1 + (math.random()-0.5)*fakePosCfg.chaosMult end

            if fakePosCfg.pattern == "Scatter" then
                local ang = (math.random()-0.5)*math.rad(fakePosCfg.scatterAngle)
                lx, lz = math.cos(ang)*math.random()*lR, math.sin(ang)*math.random()*lR
                ly = fakePosCfg.height + math.random()*fakePosCfg.yDist
            elseif fakePosCfg.pattern == "Linear" then
                fakePosHue += 0.05
                local t = fakePosHue % 1
                lx, lz = (t-0.5)*2*lR, (t-0.5)*2*lR
                ly = fakePosCfg.height + math.random()*fakePosCfg.yDist
            elseif fakePosCfg.pattern == "Circle" then
                fakePosAngle = (fakePosAngle + math.rad(fakePosCfg.speed*dt*60)) % (2*math.pi)
                lx, lz = math.cos(fakePosAngle)*lR, math.sin(fakePosAngle)*lR
                ly = fakePosCfg.height + math.random()*fakePosCfg.yDist
            elseif fakePosCfg.pattern == "Random" then
                lx, lz = (math.random()*2-1)*lR, (math.random()*2-1)*lR
                ly = fakePosCfg.height + math.random()*fakePosCfg.yDist
            elseif fakePosCfg.pattern == "Spiral" then
                fakePosAngle = (fakePosAngle + math.rad(fakePosCfg.speed*dt*60)) % (2*math.pi)
                local spR = lR * (0.3 + 0.7*(fakePosAngle/(2*math.pi)%1))
                lx, lz = math.cos(fakePosAngle)*spR, math.sin(fakePosAngle)*spR
                ly = fakePosCfg.height + math.random()*fakePosCfg.yDist
            end

            -- Distribution
            if fakePosCfg.distribution == "Uniform" then
                local len = math.sqrt(lx*lx + lz*lz)
                if len > 0 then lx, lz = lx/len*lR, lz/len*lR end
            elseif fakePosCfg.distribution == "Weighted" then
                lx, lz = lx*0.6, lz*0.6
            elseif fakePosCfg.distribution == "Radial" then
                local ang = math.atan2(lz, lx)
                lx, lz = math.cos(ang)*lR, math.sin(ang)*lR
            elseif fakePosCfg.distribution == "Clustered" then
                local oct = math.floor(math.random()*8)*(math.pi*0.25)
                lx, lz = math.cos(oct)*lR, math.sin(oct)*lR
            end

            -- Axis lock
            if fakePosCfg.axisLock == "X" then lz=0; ly=fakePosCfg.height
            elseif fakePosCfg.axisLock == "Y" then lx=0; lz=0
            elseif fakePosCfg.axisLock == "Z" then lx=0; ly=fakePosCfg.height
            elseif fakePosCfg.axisLock == "XZ" then ly=fakePosCfg.height end

            local fakeCf = fakePosAnchor + Vector3.new(lx, ly, lz)
            if rawNew then
                pcall(rawNew, rootPart, "AssemblyLinearVelocity", Vector3.zero)
                pcall(rawNew, rootPart, "CFrame", fakeCf)
                pcall(rawNew, rootPart, "AssemblyLinearVelocity", Vector3.zero)
            else
                pcall(function()
                    rootPart.AssemblyLinearVelocity = Vector3.zero
                    rootPart.CFrame = fakeCf
                    rootPart.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end
    end)

    fakePosRender = RunService.RenderStepped:Connect(function()
        if fakePosCfg.enabled and rootPart and fakePosAnchor then
            rootPart.CFrame = fakePosAnchor
            rootPart.AssemblyLinearVelocity = Vector3.zero
            rootPart.AssemblyAngularVelocity = Vector3.zero
        end
    end)
end

local function disableFakePos()
    if fakePosHeartbeat then fakePosHeartbeat:Disconnect(); fakePosHeartbeat = nil end
    if fakePosRender then fakePosRender:Disconnect(); fakePosRender = nil end
    fakePosAnchor = nil
    fakePosCfg.enabled = false
end

-- ============================================================
-- VELOCITY DESYNC
-- ============================================================
local function enableVelDesync()
    if velDesyncConn then velDesyncConn:Disconnect() end
    if velDesyncConn2 then velDesyncConn2:Disconnect() end
    desyncSavedVel, desyncAngle, desyncFlipTimer, desyncOscTime, desyncBurstTimer, desyncFlipState = nil, 0, 0, 0, 0, false

    velDesyncConn = RunService.Heartbeat:Connect(function(dt)
        local root = getRoot()
        if not velDesyncCfg.enabled or not root then return end
        desyncSavedVel = root.AssemblyLinearVelocity
        desyncFlipTimer += dt; desyncBurstTimer += dt; desyncOscTime += dt

        if velDesyncCfg.invertOnTimer and desyncFlipTimer >= velDesyncCfg.invertInterval then
            desyncFlipTimer, desyncFlipState = 0, not desyncFlipState
        end
        local sign = (velDesyncCfg.flip or desyncFlipState) and -1 or 1
        local speed = math.clamp(velDesyncCfg.speed, 1, 100)
        desyncAngle = (desyncAngle + math.rad(speed*dt*360)) % (2*math.pi)

        local baseAng = velDesyncCfg.randomizeAngle
            and math.rad(velDesyncCfg.angleMin + math.random()*(velDesyncCfg.angleMax-velDesyncCfg.angleMin))
            or math.rad(velDesyncCfg.angle)
        baseAng += math.rad((math.random()-0.5)*velDesyncCfg.jitter*2) + desyncAngle

        if velDesyncCfg.oscillate then
            baseAng += math.rad(math.sin(desyncOscTime*velDesyncCfg.oscillateFreq*2*math.pi)*velDesyncCfg.oscillateAmp)
        end
        if velDesyncCfg.rotateVel then
            baseAng += math.rad(velDesyncCfg.rotateVelSpeed)*dt
        end

        local mag = math.clamp(velDesyncCfg.intensity,1,100)/100 * 50000
        if velDesyncCfg.spikeMode and desyncBurstTimer >= velDesyncCfg.spikeInterval then
            desyncBurstTimer = 0; mag += velDesyncCfg.spikeMag
        end
        if velDesyncCfg.burstDesync and desyncBurstTimer >= velDesyncCfg.burstEvery then
            mag += velDesyncCfg.burstMag
        end

        local nx, nz = 0, 0
        if velDesyncCfg.noiseVel then
            local nt = tick()*velDesyncCfg.noiseScale
            nx = math.noise(nt,0,0)*mag*0.5
            nz = math.noise(0,nt,0)*mag*0.5
        end

        local vecs = {}
        local count = velDesyncCfg.multiVector and velDesyncCfg.vectorCount or 1
        for i = 1, count do
            local a = baseAng + (i-1)*(2*math.pi/count)
            table.insert(vecs, Vector3.new(math.cos(a)*mag*sign+nx, (math.random()-0.5)*mag*0.5, math.sin(a)*mag*sign+nz))
        end
        if velDesyncCfg.counterVel and desyncSavedVel then
            table.insert(vecs, -desyncSavedVel*2)
        end

        local meta = getrawmetatable and getrawmetatable(root)
        local rawNew = meta and rawget(meta, "__newindex")
        for _, v in ipairs(vecs) do
            if rawNew then pcall(rawNew, root, "AssemblyLinearVelocity", v)
            else pcall(function() root.AssemblyLinearVelocity = v end) end
            if sethiddenproperty then pcall(sethiddenproperty, root, "AssemblyLinearVelocity", v) end
        end
    end)

    velDesyncConn2 = RunService.RenderStepped:Connect(function()
        local root = getRoot()
        if velDesyncCfg.enabled and root and desyncSavedVel then
            root.AssemblyLinearVelocity = desyncSavedVel
        end
    end)
end

local function disableVelDesync()
    if velDesyncConn then velDesyncConn:Disconnect(); velDesyncConn = nil end
    if velDesyncConn2 then velDesyncConn2:Disconnect(); velDesyncConn2 = nil end
    desyncSavedVel, desyncAngle = nil, 0
    velDesyncCfg.enabled = false
end

-- ============================================================
-- FAST MELEE
-- ============================================================
local function cacheMeleeTables()
    if #fastMeleeCfg.cached > 0 or type(getgc) ~= "function" then return end
    pcall(function()
        for _, tbl in pairs(getgc(true)) do
            if type(tbl)=="table" and (rawget(tbl,"MeleeCooldown") or rawget(tbl,"AttackCooldown")) then
                table.insert(fastMeleeCfg.cached, tbl)
            end
        end
    end)
end

local function enableFastMelee()
    cacheMeleeTables()
    if fastMeleeConn then fastMeleeConn:Disconnect() end
    fastMeleeConn = RunService.Heartbeat:Connect(function()
        if not fastMeleeCfg.enabled then return end
        for _, tbl in ipairs(fastMeleeCfg.cached) do
            if rawget(tbl,"MeleeCooldown") then tbl.MeleeCooldown = fastMeleeCfg.cooldown end
            if rawget(tbl,"AttackCooldown") then tbl.AttackCooldown = fastMeleeCfg.cooldown end
        end
    end)
end

local function disableFastMelee()
    if fastMeleeConn then fastMeleeConn:Disconnect(); fastMeleeConn = nil end
    fastMeleeCfg.enabled = false
end

-- ============================================================
-- CHARACTER LIFECYCLE
-- ============================================================
local function onCharacterAdded(newChar)
    character = newChar
    rootPart = newChar:WaitForChild("HumanoidRootPart", 5)
    humanoid = newChar:WaitForChild("Humanoid", 5)

    if voidCfg.VOID_ENABLED then enableVoid() end
    if orbitCfg.orbitEnabled then enableOrbit() end
    if predictCfg.predEnabled then enablePrediction() end
    if antiAimCfg.enabled then enableAntiAim() end
    if undergroundCfg.enabled then enableUndergroundAA() end
    if translocCfg.enabled then enableTransloc() end
    if fakePosCfg.enabled then enableFakePos() end
    if velDesyncCfg.enabled then enableVelDesync() end
    if fastGunState.primaryOn then fastGunTick() end
end

local function onCharacterRemoving()
    -- Cleanup ALL connections
    for name in pairs(connections) do disconnectConn(name) end
    if translocConn then translocConn:Disconnect(); translocConn = nil end
    if fakePosHeartbeat then fakePosHeartbeat:Disconnect(); fakePosHeartbeat = nil end
    if fakePosRender then fakePosRender:Disconnect(); fakePosRender = nil end
    if velDesyncConn then velDesyncConn:Disconnect(); velDesyncConn = nil end
    if velDesyncConn2 then velDesyncConn2:Disconnect(); velDesyncConn2 = nil end
    if undergroundConn then undergroundConn:Disconnect(); undergroundConn = nil end
    if killAuraConn then killAuraConn:Disconnect(); killAuraConn = nil end
    stopAutoEquip()
    -- Restore hooked tools
    for tool, orig in pairs(hookedTools) do pcall(function() hookfunction(tool.Activate, orig) end) end
    hookedTools, hookedToolCount = {}, 0
    rootPart, humanoid, character = nil, nil, nil
end

if localPlayer.Character then onCharacterAdded(localPlayer.Character) end
localPlayer.CharacterAdded:Connect(function(c) task.wait(0.3); onCharacterAdded(c) end)
localPlayer.CharacterRemoving:Connect(onCharacterRemoving)

-- ============================================================
-- POSITION HUD
-- ============================================================
local function createPositionHud()
    local old = CoreGui:FindFirstChild("RCLC_PositionHUD")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset, gui.ZIndexBehavior = "RCLC_PositionHUD", false, 9998, true, Enum.ZIndexBehavior.Sibling
    pcall(function() gui.Parent = CoreGui end)
    if not gui.Parent then gui.Parent = localPlayer:WaitForChild("PlayerGui") end

    local accent = Color3.fromRGB(168,85,247)
    local bg = Color3.fromRGB(8,6,12)
    local panel = Instance.new("Frame")
    panel.Name, panel.Size, panel.Position = "PositionHUD", UDim2.fromOffset(200,132), UDim2.new(0,16,0.5,-66)
    panel.BackgroundColor3, panel.BackgroundTransparency, panel.BorderSizePixel = bg, 0.02, 0
    panel.Active, panel.Parent = false, gui

    Instance.new("UICorner", panel).CornerRadius = UDim.new(0,12)
    local stroke = Instance.new("UIStroke", panel)
    stroke.Color, stroke.Thickness, stroke.Transparency = Color3.fromRGB(90,50,140), 1.2, 0.15
    Instance.new("UIGradient", panel).Rotation = 90
    -- ... (gradient setup omitted for brevity, same as yours)

    local labels = {}
    for i, axis in ipairs({"X","Y","Z"}) do
        local row = Instance.new("Frame")
        row.Size, row.Position = UDim2.new(1,-24,0,24), UDim2.fromOffset(12, 50+(i-1)*27)
        row.BackgroundColor3, row.BackgroundTransparency, row.BorderSizePixel = Color3.fromRGB(16,12,22), 0.1, 0
        row.Parent = panel
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,6)
        Instance.new("UIStroke", row).Color = Color3.fromRGB(90,50,140)

        local acc = Instance.new("Frame", row)
        acc.Size, acc.Position, acc.BackgroundColor3 = UDim2.fromOffset(2,12), UDim2.new(0,7,0.5,-6), accent
        Instance.new("UICorner", acc).CornerRadius = UDim.new(1,0)

        Instance.new("TextLabel", row).Text = axis
        local val = Instance.new("TextLabel", row)
        val.Size, val.Position = UDim2.new(1,-40,1,0), UDim2.fromOffset(34,0)
        val.BackgroundTransparency, val.Text, val.TextColor3, val.TextXAlignment = 1, "0.00", Color3.fromRGB(245,240,255), Enum.TextXAlignment.Right
        val.Font, val.TextSize = Enum.Font.Garamond, 13
        labels[axis] = val
    end

    RunService.Heartbeat:Connect(function()
        if not gui.Parent then return end
        local char = localPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then
            labels.X.Text = string.format("%.2f", root.Position.X)
            labels.Y.Text = string.format("%.2f", root.Position.Y)
            labels.Z.Text = string.format("%.2f", root.Position.Z)
        else
            labels.X.Text, labels.Y.Text, labels.Z.Text = "0.00", "0.00", "0.00"
        end
    end)

    positionHudLabels = labels
    return gui
end

positionHud = createPositionHud()

-- ============================================================
-- UI TABS (Identical to your layout, just wired to new locals)
-- ============================================================
local voidTab     = window:CreateTab({ Name = "Void",     Icon = "activity" })
local orbitTab    = window:CreateTab({ Name = "Orbit",    Icon = "refresh-cw" })
local defenseTab  = window:CreateTab({ Name = "Defense",  Icon = "shield" })
local translocTab = window:CreateTab({ Name = "Translocation", Icon = "move" })
local extrasTab   = window:CreateTab({ Name = "Extras",   Icon = "zap" })
local settingsTab = window:CreateTab({ Name = "Settings", Icon = "settings" })

-- VOID TAB
voidTab:CreateSection("Engine")
voidTab:CreateToggle({ Name="Enable Void", CurrentValue=false, Flag="VoidToggle", Callback=function(v) voidCfg.VOID_ENABLED=v; if v then enableVoid() else disableVoid() end end })
voidTab:CreateDropdown({ Name="Method", Options={"Attacker","Chaos","Quantum","Freeze Bait"}, CurrentOption="Quantum", Flag="VoidMethod", Callback=function(opt) voidCfg.VOID_METHOD=opt; voidPhaseTime=0; voidBaitPhase=false end })

voidTab:CreateSection("Attacker Settings")
voidTab:CreateSlider({ Name="Attacker Interval (s)", Range={1,10}, Increment=0.5, CurrentValue=4, Flag="VoidAttInterval", Callback=function(v) voidCfg.VOID_ATTACKER_INTERVAL=v end })
voidTab:CreateSlider({ Name="Attacker Freeze (s)", Range={0.1,2}, Increment=0.1, CurrentValue=0.4, Flag="VoidAttDuration", Callback=function(v) voidCfg.VOID_ATTACKER_DURATION=v end })

voidTab:CreateSection("Freeze Bait Settings")
voidTab:CreateSlider({ Name="Bait Interval (s)", Range={1,10}, Increment=0.5, CurrentValue=3, Flag="VoidBaitInterval", Callback=function(v) voidCfg.VOID_BAIT_INTERVAL=v end })
voidTab:CreateSlider({ Name="Bait Freeze Duration (s)", Range={0.1,2}, Increment=0.1, CurrentValue=0.4, Flag="VoidBaitDuration", Callback=function(v) voidCfg.VOID_BAIT_DURATION=v end })

voidTab:CreateSection("Visuals")
voidTab:CreateToggle({ Name="Enable Wireframe ESP", CurrentValue=false, Flag="VoidWireframe", Callback=function(v) setWireframes(v) end })

voidTab:CreateSection("Motion")
voidTab:CreateSlider({ Name="Speed", Range={0.001,1}, Increment=0.001, CurrentValue=1, Flag="VoidSpeed", Callback=function(v) voidCfg.SPEED=v*1e9 end })
voidTab:CreateSlider({ Name="Writes / Frame", Range={1,8}, Increment=1, CurrentValue=1, Flag="VoidWrites", Callback=function(v) voidCfg.VOID_WRITES_PER_FRAME=v end })
voidTab:CreateToggle({ Name="Interpolate", CurrentValue=true, Flag="VoidInterp", Callback=function(v) voidCfg.VOID_INTERP=v end })
voidTab:CreateSlider({ Name="Interp Alpha", Range={0.05,1}, Increment=0.05, CurrentValue=0.35, Flag="VoidInterpAlpha", Callback=function(v) voidCfg.VOID_INTERP_ALPHA=v end })

voidTab:CreateSection("Space")
voidTab:CreateSlider({ Name="Radius", Range={1,1e7}, Increment=1, CurrentValue=1e7, Flag="VoidRadius", Callback=function(v) voidCfg.RADIUS=v end })
voidTab:CreateSlider({ Name="Y Min", Range={-1e7,1e7}, Increment=1, CurrentValue=-1e7, Flag="VoidYMin", Callback=function(v) voidCfg.VOID_Y_MIN=v end })
voidTab:CreateSlider({ Name="Y Max", Range={-1e7,1e7}, Increment=1, CurrentValue=1e7, Flag="VoidYMax", Callback=function(v) voidCfg.VOID_Y_MAX=v end })

-- ORBIT TAB
orbitTab:CreateToggle({ Name="Enable Orbit", CurrentValue=false, Flag="OrbitToggle", Callback=function(v) orbitCfg.orbitEnabled=v; if v then enableOrbit() else disableOrbit() end end })
orbitTab:CreateDropdown({ Name="Direction", Options={"Clockwise","Counter-Clockwise"}, CurrentOption="Clockwise", Flag="OrbitMode", Callback=function(v) orbitCfg.orbitMode=v end })
orbitTab:CreateSlider({ Name="Speed", Range={5,1000}, Increment=1, CurrentValue=90, Flag="OrbitSpeed", Callback=function(v) orbitCfg.orbitSpeed=v end })
orbitTab:CreateSlider({ Name="Radius", Range={1,50}, Increment=1, CurrentValue=8, Flag="OrbitDist", Callback=function(v) orbitCfg.orbitDist=v end })
orbitTab:CreateSlider({ Name="Height", Range={-100,100}, Increment=1, CurrentValue=0, Flag="OrbitHeight", Callback=function(v) orbitCfg.orbitHeight=v end })

-- DEFENSE TAB
defenseTab:CreateSection("Anti-Aim (Chaos Jitter)")
defenseTab:CreateToggle({ Name="Enable Anti-Aim", CurrentValue=false, Flag="AaToggle", Callback=function(v) antiAimCfg.enabled=v; if v then enableAntiAim() else disableAntiAim() end end })
defenseTab:CreateSlider({ Name="Pitch Max (deg)", Range={1,360}, Increment=1, CurrentValue=360, Flag="AaPitch", Callback=function(v) antiAimCfg.pitch=v end })
defenseTab:CreateSlider({ Name="Yaw Max (deg)", Range={1,360}, Increment=1, CurrentValue=360, Flag="AaYaw", Callback=function(v) antiAimCfg.yaw=v end })

defenseTab:CreateSection("Underground Anti-Aim")
defenseTab:CreateToggle({ Name="Enable Underground AA", CurrentValue=false, Flag="UgAAToggle", Callback=function(v) undergroundCfg.enabled=v; if v then enableUndergroundAA() else disableUndergroundAA() end end })
defenseTab:CreateSlider({ Name="Underground Depth", Range={1,5}, Increment=0.1, CurrentValue=1.5, Flag="UgAADepth", Callback=function(v) undergroundCfg.depth=v end })
defenseTab:CreateSlider({ Name="Orbit Radius", Range={0,10}, Increment=0.1, CurrentValue=3, Flag="UgAAOrbRadius", Callback=function(v) undergroundCfg.orbitRadius=v end })
defenseTab:CreateSlider({ Name="Orbit Speed", Range={50,1000}, Increment=10, CurrentValue=200, Flag="UgAAOrbSpeed", Callback=function(v) undergroundCfg.orbitSpeed=v end })
defenseTab:CreateSlider({ Name="Spin Speed", Range={100,2000}, Increment=10, CurrentValue=720, Flag="UgAASpinSpeed", Callback=function(v) undergroundCfg.spinSpeed=v end })

defenseTab:CreateSection("Prediction (Dodging)")
defenseTab:CreateToggle({ Name="Enable Prediction", CurrentValue=false, Flag="DefPredToggle", Callback=function(v) predictCfg.predEnabled=v; if v then enablePrediction() else disablePrediction() end end })
defenseTab:CreateToggle({ Name="Track Enemy Velocity", CurrentValue=true, Flag="DefPredKinematic", Callback=function(v) predictCfg.predKinematic=v end })
defenseTab:CreateToggle({ Name="Predict Shot Path", CurrentValue=true, Flag="DefPredPredictive", Callback=function(v) predictCfg.predPredictive=v end })
defenseTab:CreateSlider({ Name="Danger Radius", Range={5,5000}, Increment=1, CurrentValue=150, Flag="DefPredRadius", Callback=function(v) predictCfg.predRadius=v end })
defenseTab:CreateSlider({ Name="Dodge Distance", Range={5,500}, Increment=1, CurrentValue=80, Flag="DefPredDodge", Callback=function(v) predictCfg.predDodgeDist=v end })
defenseTab:CreateSlider({ Name="Reaction Time ms", Range={1,50}, Increment=1, CurrentValue=12, Flag="DefPredReactTime", Callback=function(v) predictCfg.predReactionTime=v*0.01 end })
defenseTab:CreateSlider({ Name="Aim Threshold %", Range={50,99}, Increment=1, CurrentValue=70, Flag="DefPredAimThreshold", Callback=function(v) predictCfg.predAimThreshold=v*0.01 end })
defenseTab:CreateSlider({ Name="Cooldown ms", Range={10,2000}, Increment=1, CurrentValue=50, Flag="DefPredCooldown", Callback=function(v) predictCfg.predCooldown=v/1000 end })

defenseTab:CreateSection("Velocity Desync")
defenseTab:CreateToggle({ Name="Enable Velocity Desync", CurrentValue=false, Flag="VelDesyncToggle", Callback=function(v) velDesyncCfg.enabled=v; if v then enableVelDesync() else disableVelDesync() end end })
defenseTab:CreateSlider({ Name="Intensity %", Range={1,100}, Increment=1, CurrentValue=50, Flag="VDIntensity", Callback=function(v) velDesyncCfg.intensity=v end })
defenseTab:CreateSlider({ Name="Base Angle", Range={0,360}, Increment=1, CurrentValue=90, Flag="VDAngle", Callback=function(v) velDesyncCfg.angle=v end })
defenseTab:CreateSlider({ Name="Jitter", Range={0,180}, Increment=1, CurrentValue=20, Flag="VDJitter", Callback=function(v) velDesyncCfg.jitter=v end })
defenseTab:CreateSlider({ Name="Rotation Speed", Range={1,100}, Increment=1, CurrentValue=10, Flag="VDSpeed", Callback=function(v) velDesyncCfg.speed=v end })
defenseTab:CreateToggle({ Name="Flip Direction", CurrentValue=false, Flag="VDFlip", Callback=function(v) velDesyncCfg.flip=v end })
defenseTab:CreateToggle({ Name="Oscillate", CurrentValue=false, Flag="VDOsc", Callback=function(v) velDesyncCfg.oscillate=v end })
defenseTab:CreateToggle({ Name="Spike Mode", CurrentValue=false, Flag="VDSpike", Callback=function(v) velDesyncCfg.spikeMode=v end })
defenseTab:CreateToggle({ Name="Multi Vector", CurrentValue=false, Flag="VDMulti", Callback=function(v) velDesyncCfg.multiVector=v end })
defenseTab:CreateToggle({ Name="Noise Velocity", CurrentValue=false, Flag="VDNoise", Callback=function(v) velDesyncCfg.noiseVel=v end })
defenseTab:CreateToggle({ Name="Burst Desync", CurrentValue=false, Flag="VDBurst", Callback=function(v) velDesyncCfg.burstDesync=v end })

defenseTab:CreateSection("Fake Position")
defenseTab:CreateToggle({ Name="Enable Fake Position", CurrentValue=false, Flag="FakePosToggle", Callback=function(v) fakePosCfg.enabled=v; if v then enableFakePos() else disableFakePos() end end })
defenseTab:CreateDropdown({ Name="Pattern", Options={"Scatter","Linear","Circle","Random","Spiral"}, CurrentOption="Scatter", Flag="FPPattern", Callback=function(v) fakePosCfg.pattern=v end })
defenseTab:CreateDropdown({ Name="Distribution", Options={"Random","Uniform","Weighted","Radial","Clustered"}, CurrentOption="Random", Flag="FPDist", Callback=function(v) fakePosCfg.distribution=v end })
defenseTab:CreateDropdown({ Name="Axis Lock", Options={"None","X","Y","Z","XZ"}, CurrentOption="None", Flag="FPAxis", Callback=function(v) fakePosCfg.axisLock=v end })
defenseTab:CreateSlider({ Name="Radius", Range={1,1e7}, Increment=1000, CurrentValue=1e6, Flag="FPRadius", Callback=function(v) fakePosCfg.radius=v end })
defenseTab:CreateSlider({ Name="Height Offset", Range={-1e9,1e9}, Increment=1000, CurrentValue=999999999, Flag="FPHeight", Callback=function(v) fakePosCfg.height=v end })
defenseTab:CreateSlider({ Name="Y Distance", Range={0,1e9}, Increment=1000, CurrentValue=999999999, Flag="FPYDist", Callback=function(v) fakePosCfg.yDist=v end })
defenseTab:CreateSlider({ Name="Speed", Range={1,1e5}, Increment=100, CurrentValue=1e5, Flag="FPSpeed", Callback=function(v) fakePosCfg.speed=v end })
defenseTab:CreateToggle({ Name="Randomize Every Frame", CurrentValue=false, Flag="FPRandFrame", Callback=function(v) fakePosCfg.randomizeEveryFrame=v end })
defenseTab:CreateToggle({ Name="Layered Fake", CurrentValue=false, Flag="FPLayered", Callback=function(v) fakePosCfg.layeredFake=v end })
defenseTab:CreateToggle({ Name="Chaos Mode", CurrentValue=false, Flag="FPChaos", Callback=function(v) fakePosCfg.chaosMode=v end })
defenseTab:CreateToggle({ Name="Pulse Radius", CurrentValue=false, Flag="FPPulse", Callback=function(v) fakePosCfg.pulseRadius=v end })

-- TRANSLOC TAB
translocTab:CreateSection("Engine")
translocTab:CreateToggle({ Name="Enable Translocation", CurrentValue=false, Flag="TranslocToggle", Callback=function(v) translocCfg.enabled=v; if v then enableTransloc() else disableTransloc() end end })
translocTab:CreateSlider({ Name="Frequency (Hz)", Range={1,1e6}, Increment=1000, CurrentValue=1e6, Flag="TranslocFreq", Callback=function(v) translocCfg.frequency=v end })
translocTab:CreateSlider({ Name="X Jitter Range", Range={1,1e8}, Increment=1000, CurrentValue=1e7, Flag="TranslocJitterX", Callback=function(v) translocCfg.jitterX=v end })
translocTab:CreateSlider({ Name="Y Jitter Range", Range={1,1e8}, Increment=1000, CurrentValue=1e7, Flag="TranslocJitterY", Callback=function(v) translocCfg.jitterY=v end })
translocTab:CreateSlider({ Name="Fixed Z Position", Range={0,100}, Increment=0.1, CurrentValue=1, Flag="TranslocFixedZ", Callback=function(v) translocCfg.fixedZ=v end })

translocTab:CreateSection("Pulse")
translocTab:CreateToggle({ Name="Fake Velocity", CurrentValue=true, Flag="TranslocFakeVel", Callback=function(v) translocCfg.fakeVel=v end })
translocTab:CreateSlider({ Name="Fake Vel Mag", Range={1,1e15}, Increment=1000, CurrentValue=1e10, Flag="TranslocVelMag", Callback=function(v) translocCfg.fakeVelMag=v end })
translocTab:CreateToggle({ Name="Burst Mode", CurrentValue=false, Flag="TranslocBurst", Callback=function(v) translocCfg.burstMode=v end })
translocTab:CreateSlider({ Name="Burst Count", Range={2,50}, Increment=1, CurrentValue=10, Flag="TranslocBurstCount", Callback=function(v) translocCfg.burstCount=v end })

-- EXTRAS TAB
extrasTab:CreateSection("Zombie Tower Kill Aura")
extrasTab:CreateToggle({ Name="Enable Kill Aura", CurrentValue=false, Flag="KillAuraToggle", Callback=function(v) killAuraCfg.enabled=v; if v then enableKillAura() else disableKillAura() end end })

extrasTab:CreateSection("Fast Melee")
extrasTab:CreateToggle({ Name="Enable Fast Melee", CurrentValue=false, Flag="FastMeleeToggle", Callback=function(v) fastMeleeCfg.enabled=v; if v then enableFastMelee() else disableFastMelee() end end })
extrasTab:CreateSlider({ Name="Melee Cooldown", Range={0,5}, Increment=0.01, CurrentValue=0, Flag="MeleeCD", Callback=function(v) fastMeleeCfg.cooldown=v end })

extrasTab:CreateSection("Fast Gun")
extrasTab:CreateToggle({ Name="Enable Fast Gun", CurrentValue=false, Flag="FastGunToggle", Callback=function(v) fastGunState.primaryOn=v; if v then fastGunTick() end end })
extrasTab:CreateButton({ Name="Rescan & Repatch All Guns", Style="Primary", Icon="refresh-cw", Callback=function() fastGunState.primaryOn=true; fastGunTick() end })

-- SETTINGS TAB
settingsTab:CreateSection("Presets")
settingsTab:CreateButton({ Name="Kill Everything", Style="Danger", Icon="power", Callback=function()
    voidCfg.VOID_ENABLED=false; disableVoid()
    orbitCfg.orbitEnabled=false; disableOrbit()
    predictCfg.predEnabled=false; disablePrediction()
    antiAimCfg.enabled=false; disableAntiAim()
    undergroundCfg.enabled=false; disableUndergroundAA()
    translocCfg.enabled=false; disableTransloc()
    fakePosCfg.enabled=false; disableFakePos()
    velDesyncCfg.enabled=false; disableVelDesync()
    fastMeleeCfg.enabled=false; disableFastMelee()
    killAuraCfg.enabled=false; disableKillAura()
    disableWireframes()
    fastGunState.primaryOn=false
    notify("Preset","All systems off","Warning",3)
end })

settingsTab:CreateSection("Character")
settingsTab:CreateButton({ Name="Reload Character", Icon="refresh-cw", Callback=function() if localPlayer.Character then localPlayer.Character:BreakJoints() end end })
settingsTab:CreateButton({ Name="Rejoin Server", Icon="log-out", Callback=function() pcall(function() TeleportService:Teleport(game.PlaceId, localPlayer) end) end })

settingsTab:CreateSection("Interface")
settingsTab:CreateButton({ Name="Test MenHub API", Icon="zap", Callback=function() if _G.Mhapi then pcall(function() _G.Mhapi:Notify("you click me!") end) else notify("MenHub","Not detected. Running Airflow.","Warning",3) end end })
settingsTab:CreateThemePicker({ Flag="Theme" })
settingsTab:CreateKeybind({ Name="Toggle UI", CurrentKeybind="RightControl", OnChanged=function(k) window:SetKeybind(k) end })
settingsTab:CreateConfigManager({ Name="Configs" })
settingsTab:CreateButton({ Name="Unload Script", Style="Danger", Icon="power", Callback=function()
    AirflowUI:Confirm({ Title="Unload?", ConfirmText="Unload", Callback=function()
        window:Destroy()
        if positionHud then positionHud:Destroy() end
    end })
end })

window:LoadConfig()
notify("RCLC Premium Lua", "#1 HVH addon loaded (hardened)", "Success", 4)

end -- end of do-block (prevents global leak)
