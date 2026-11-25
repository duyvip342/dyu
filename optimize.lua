local features = {}
local lighting = game:GetService("Lighting")
local players = game:GetService("Players")
local localPlayer = players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local tweenService = game:GetService("TweenService")
local runService = game:GetService("RunService")
local environment = type(getgenv) == "function" and getgenv() or _G
local previous = environment.RobloxHubOptimize
if type(previous) == "table" and type(previous.stop) == "function" then previous.stop() end
local session = type(previous) == "table" and type(previous.session) == "table" and previous.session or {}
session.renderOwners = session.renderOwners or {}
if session.renderDisabled == nil then session.renderDisabled = false end
local controller = {active=true, session=session, renderError=false, refreshEvent=false}
local connections = {}
local queue, pending = {}, setmetatable({}, {__mode="k"})
local first, last = 1, 0
local processing = false
local syncItemPopups

-- Chỉ thay đổi hiển thị cục bộ; không xóa instance hay thay đổi dữ liệu game.
local states = {
    lootBoxes = false,
    objects = false,
    super = false,
}
local originals = setmetatable({}, { __mode = "k" })
local applied = setmetatable({}, { __mode = "k" })
-- Theo dõi khối thay thế của từng vật thể trong zone.
local objectBoxes = {}
local damageConnection
local boxSize = Vector3.new(1.75, 1.75, 1.75)
local bounceInfo = TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
local invisibleParticles = NumberSequence.new(1)

-- Khai báo các nhóm vật thể được thay bằng khối xám.
local objectFolders = {
    Breakables = true,
    AnimatedBreakables = true,
    Chests = true,
    RandomEvents = true,
}

-- Tìm vật thể gốc thuộc nhóm đối tượng trong zone.
local function getZoneObject(instance)
    local current = instance
    while current and current ~= workspace do
        local parent = current.Parent
        local things = parent and parent.Parent
        if things and things.Name == "__THINGS" and things.Parent == workspace then
            if objectFolders[parent.Name] and (current:IsA("Model") or current:IsA("BasePart")) then
                return current
            end
            return nil
        end
        current = parent
    end
    return nil
end

-- Nhận diện nhân vật của người chơi khác.
local function isOtherCharacter(instance)
    local current = instance
    while current and current.Parent ~= workspace do current = current.Parent end
    if not current or not current:IsA("Model") then return false end
    local player = players:GetPlayerFromCharacter(current)
    return player ~= nil and player ~= localPlayer
end

-- Gắn khối xám hiển thị vào part của vật thể.
local function ensureObjectBox(object)
    local record = objectBoxes[object]
    if record and record.box.Parent then return end
    local anchor = object:IsA("BasePart") and object
        or object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
    if not anchor then return end
    local box = Instance.new("BoxHandleAdornment")
    box.Name = "OptimizeObjectBox"
    box.Adornee = anchor
    box.Size = boxSize
    box.Color3 = Color3.fromRGB(128, 128, 128)
    objectBoxes[object] = { box = box, nextBounce = 0 }
    box.Parent = anchor
end

-- Dọn khối xám do script tạo cho vật thể.
local function removeObjectBox(object)
    local record = objectBoxes[object]
    if not record then return end
    objectBoxes[object] = nil
    record.box:Destroy()
end

-- Làm khối xám nảy khi vật thể nhận sát thương.
local function connectObjectDamage()
    if damageConnection then return end
    local client = game:GetService("ReplicatedStorage").Library.Client
    local breakables = require(client.BreakableCmds)
    if not controller.active or not states.objects or states.super or damageConnection then return end
    damageConnection = breakables.DamageDealt:Connect(function(data)
        if not controller.active or not states.objects or states.super or not data.model then return end
        local object = getZoneObject(data.model)
        local record = object and objectBoxes[object]
        local now = os.clock()
        if not record or not record.box.Parent or now < record.nextBounce then return end
        record.nextBounce = now + 0.24
        record.box.CFrame = CFrame.identity
        tweenService:Create(record.box, bounceInfo, { CFrame = CFrame.new(0, 0.55, 0) }):Play()
    end)
end

-- Nhận diện tên các thư mục chứa đồ rơi.
local dropFolderNames = {
    coins = true,
    orbs = true,
    lootbags = true,
    lootboxes = true,
    lootbox = true,
}

-- Chỉ ẩn hình khối trong các nhóm render đã xác nhận dưới Workspace.__THINGS.
local superVisualFolders = {
    pets = true,
    shinyrelics = true,
    hoverboards = true,
}

-- Liệt kê nhóm map đặc biệt nằm trực tiếp dưới Workspace.
local mapRoots = {
    ["PSX Hall"] = true,
    ["PSX Portal"] = true,
    GREYBOX_WIP = true,
}

-- Liệt kê nhóm map nằm trong Workspace.__THINGS.
local mapThings = {
    Ornaments = true,
    __FAKE_GROUND = true,
    __FAKE_INSTANCE_GROUND = true,
    __FAKE_INSTANCE_BREAK_ZONES = true,
}

-- Nhận diện hình khối map có thể ẩn trong Super Optimize.
local function isMapGeometry(instance)
    if not (instance:IsA("BasePart") or instance:IsA("Decal") or instance:IsA("Texture")) then
        return false
    end
    local current = instance
    while current and current ~= workspace do
        local name = current.Name
        local lowerName = string.lower(name)
        if lowerName:find("chest", 1, true) or lowerName:find("breakable", 1, true) then
            return false
        end
        local parent = current.Parent
        if parent == workspace then
            return mapRoots[name] == true or name:match("^Map%d*$") ~= nil
                or name:match("^Border%d+$") ~= nil or name:match("^ALWAYS_RENDERING_%d+$") ~= nil
                or name:match("^Zone %d+$") ~= nil
        end
        if parent and parent.Parent == workspace and parent.Name == "__THINGS" then
            return mapThings[name] == true
        end
        current = parent
    end
    return false
end

-- Nhận diện thư mục hiển thị theo đúng cây object của game.
local function getVisualFolderName(instance)
    local parent = instance.Parent
    if not parent or parent.Parent ~= workspace then return nil end
    if not (instance:IsA("Folder") or instance:IsA("Model")) then return nil end
    local name = string.lower(instance.Name)
    if parent.Name == "__THINGS" and (dropFolderNames[name] or superVisualFolders[name]) then
        return name
    end
    if parent.Name == "__DEBRIS" and name == "currency" then return name end
    return nil
end

-- Nhận diện thư mục túi quà và hộp quà.
local function isLootBoxFolder(name)
    name = string.lower(name)
    return name == "lootbags" or name == "lootboxes" or name == "lootbox"
end

-- Kiểm tra toggle hiện tại có yêu cầu ẩn nhóm đó không.
local function isFolderDisabled(name)
    if states.super then return true end
    if states.lootBoxes and isLootBoxFolder(name) then return true end
    return states.objects and (name == "coins" or name == "orbs" or name == "currency")
end

-- Chọn thuộc tính hiển thị cần đổi theo loại instance.
local function getHiddenProperties(instance)
    if instance:IsA("BasePart") then
        return states.super and {{"LocalTransparencyModifier",1},{"CastShadow",false}}
            or {{"LocalTransparencyModifier",1}}
    elseif instance:IsA("Decal") or instance:IsA("Texture") then
        return { { "Transparency", 1 } }
    elseif instance:IsA("Sky") then
        return {{"CelestialBodiesShown",false},{"StarCount",0}}
    elseif instance:IsA("Atmosphere") then
        return {
            { "Density", 0 },
            { "Haze", 0 },
            { "Glare", 0 },
        }
    elseif instance:IsA("ParticleEmitter") then
        return { { "Enabled", false }, { "Transparency", invisibleParticles } }
    elseif instance:IsA("Trail")
        or instance:IsA("Beam") or instance:IsA("BillboardGui")
        or instance:IsA("SurfaceGui") or instance:IsA("Highlight")
        or instance:IsA("Smoke") or instance:IsA("Fire")
        or instance:IsA("Sparkles") or instance:IsA("PostEffect")
        or instance:IsA("Clouds") or instance:IsA("PointLight")
        or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
        return { { "Enabled", false } }
    end
    return nil
end

-- Lưu từng thuộc tính theo trạng thái mong muốn để các toggle không khôi phục đè nhau.
local function readProperty(instance, property)
    local ok, value = pcall(function() return instance[property] end)
    if not ok and type(gethiddenproperty) == "function" then ok, value = pcall(gethiddenproperty, instance, property) end
    return ok and value ~= nil, value
end

local function writeProperty(instance, property, value)
    local ok = pcall(function() instance[property] = value end)
    if not ok and type(sethiddenproperty) == "function" then ok = pcall(sethiddenproperty, instance, property, value) end
    return ok
end

local function applyProperties(instance, desired)
    local saved = originals[instance]
    local written = applied[instance] or {}
    if saved then
        for property, value in pairs(saved) do
            if desired[property] == nil then
                local ok, current = readProperty(instance, property)
                -- Không ghi đè thay đổi mới của game hoặc Optimize Event.
                if ok and current == written[property] then writeProperty(instance, property, value) end
                saved[property] = nil
                written[property] = nil
            end
        end
    end
    for property, value in pairs(desired) do
        local ok, current = readProperty(instance, property)
        if ok then
            saved = saved or {}
            originals[instance] = saved
            if saved[property] == nil then saved[property] = current end
            if current == value or writeProperty(instance, property, value) then written[property] = value end
        end
    end
    if saved and next(saved) then applied[instance] = written
    else originals[instance], applied[instance] = nil, nil end
end

local function setLocalHidden(instance, hidden)
    local desired = {}
    if hidden then
        for _, entry in ipairs(getHiddenProperties(instance) or {}) do desired[entry[1]] = entry[2] end
    end
    if instance:IsA("Terrain") and states.super then
        desired.WaterWaveSize, desired.WaterWaveSpeed = 0, 0
        desired.WaterReflectance, desired.WaterTransparency, desired.Decoration = 0, 1, false
    end
    applyProperties(instance, desired)
end

-- Nhận diện các instance thuộc nhóm hiệu ứng hiển thị.
local function isWorldEffect(instance)
    return instance:IsA("BillboardGui") or instance:IsA("SurfaceGui")
        or instance:IsA("ParticleEmitter") or instance:IsA("Trail")
        or instance:IsA("Beam") or instance:IsA("Highlight")
        or instance:IsA("Smoke") or instance:IsA("Fire")
        or instance:IsA("Sparkles") or instance:IsA("PostEffect")
        or instance:IsA("Clouds") or instance:IsA("PointLight")
        or instance:IsA("SpotLight") or instance:IsA("SurfaceLight")
        or instance:IsA("Atmosphere")
end

-- Kiểm tra instance có nằm trong nhóm đang bị ẩn không.
local function hasDisabledFolderAncestor(instance)
    local current = instance
    while current and current ~= workspace do
        local name = getVisualFolderName(current)
        if name and isFolderDisabled(name) then
            return true
        end
        current = current.Parent
    end
    return false
end

-- Xác định instance có cần ẩn theo cấu hình hiện tại không.
local function shouldHide(instance)
    if states.super then
        -- Giữ ScreenGui và UI có nút tương tác; không sửa dữ liệu/collision/Transparency của part.
        if instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
            return not instance:FindFirstChildWhichIsA("GuiButton", true)
        end
        return instance:IsDescendantOf(workspace) or instance:IsDescendantOf(lighting)
    end
    if states.objects then
        if getZoneObject(instance) then return true end
        if isWorldEffect(instance) then
            local current = instance
            while current and current.Parent ~= workspace do
                local parent = current.Parent
                if parent and parent.Name == "__DEBRIS" and parent.Parent == workspace then
                    if current.Name:match("^ParticleHost_") or current.Name == "RewardBillboard" then return true end
                    break
                end
                current = parent
            end
        end
    end
    if states.super and isMapGeometry(instance) then return true end
    if instance:IsA("BasePart") and instance.CanCollide then return false end
    return hasDisabledFolderAncestor(instance)
        or ((states.lootBoxes or states.super) and isWorldEffect(instance))
end

-- Dùng chung quyền tắt cảnh 3D giữa Super và Stats Event.
local function requestRendering(owner, off)
    if not controller.active then
        local current = environment.RobloxHubOptimize
        if current and current ~= controller then return current.requestRendering(owner, off) end
        return false
    end
    session.renderOwners[owner] = off and true or nil
    local disabled = next(session.renderOwners) ~= nil
    if session.renderDisabled == disabled then return true end
    local ok, problem = pcall(function() runService:Set3dRenderingEnabled(not disabled) end)
    if ok then session.renderDisabled = disabled
    elseif controller.renderError ~= tostring(problem) then
        controller.renderError = tostring(problem)
        warn("[Super Optimize] Tắt cảnh 3D không khả dụng, dùng bộ lọc hiển thị: " .. controller.renderError)
    end
    return ok
end
controller.requestRendering = requestRendering

local function applyGlobalSettings()
    local values = {}
    if states.super or states.lootBoxes then values.FogStart, values.FogEnd = 0, 1000000 end
    if states.super then
        values.GlobalShadows, values.ShadowSoftness = false, 0
        values.EnvironmentDiffuseScale, values.EnvironmentSpecularScale = 0, 0
    end
    applyProperties(lighting, values)
    local ok, rendering = pcall(function() return settings().Rendering end)
    if ok then
        applyProperties(rendering, states.super and {
            QualityLevel=Enum.QualityLevel.Level01,
            MeshPartDetailLevel=Enum.MeshPartDetailLevel.Level01,
        } or {})
    end
    local got, userSettings = pcall(function() return UserSettings():GetService("UserGameSettings") end)
    if got then
        applyProperties(userSettings, states.super and {SavedQualityLevel=Enum.SavedQualitySetting.QualityLevel1} or {})
    end
end

local function anyVisual()
    return states.super or states.objects or states.lootBoxes
end

local function enqueue(instance, walk)
    local existing = pending[instance]
    if existing then existing.walk = existing.walk or walk; return end
    last += 1
    local item = {instance=instance, walk=walk}
    pending[instance], queue[last] = item, item
end

local function processOne(instance)
    -- Lighting có bộ thuộc tính toàn cục riêng, không phục hồi trong lượt quét cảnh.
    if instance == lighting then return end
    if states.objects and not states.super and instance:IsA("BasePart") then
        local object = getZoneObject(instance)
        if object then ensureObjectBox(object) end
    end
    setLocalHidden(instance, shouldHide(instance))
end

local function refreshEventVisuals()
    local shared = controller.shared
    local feature = shared and shared.EventOptimize
    if feature and type(feature.refresh) == "function" then feature.refresh() end
end

local function startProcessing()
    if processing then return end
    processing = true
    task.defer(function()
        local lastError
        while controller.active and first <= last do
            local deadline = os.clock()+0.002
            for _=1,120 do
                if first>last or os.clock()>=deadline then break end
                local entry=queue[first]
                queue[first]=nil
                first+=1
                pending[entry.instance]=nil
                local object=entry.instance
                local ok, problem=pcall(function()
                    if object.Parent then
                        processOne(object)
                        if entry.walk then
                            for _,child in ipairs(object:GetChildren()) do enqueue(child,true) end
                        end
                    elseif originals[object] then
                        applyProperties(object,{})
                    end
                end)
                if not ok and tostring(problem)~=lastError then
                    lastError=tostring(problem)
                    warn("[Optimize] " .. lastError)
                end
            end
            if first<=last then runService.Heartbeat:Wait() end
        end
        table.clear(queue);table.clear(pending)
        first,last,processing=1,0,false
        if controller.active and controller.refreshEvent and not states.super then
            controller.refreshEvent = false
            refreshEventVisuals()
        end
    end)
end

local function disconnectWatches()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
end

local function watchRoots()
    if #connections>0 or not anyVisual() then return end
    for _, root in ipairs({workspace, lighting, playerGui}) do
        connections[#connections+1]=root.DescendantAdded:Connect(function(instance)
            if not controller.active or not anyVisual() then return end
            enqueue(instance,true)
            startProcessing()
        end)
    end
    connections[#connections+1]=workspace.DescendantRemoving:Connect(function(instance)
        if objectBoxes[instance] then removeObjectBox(instance) end
        if originals[instance] then
            -- Trả thuộc tính ngay khi object rời scope, không giữ object đã bị game dọn.
            applyProperties(instance,{})
        end
    end)
end

-- Chỉ quét khi đổi trạng thái; xử lý theo lô, không quét lại toàn map mỗi frame.
local function refreshVisuals()
    if anyVisual() then
        watchRoots()
        for _,root in ipairs({workspace,lighting,playerGui}) do enqueue(root,true) end
    else
        disconnectWatches()
        for instance in pairs(originals) do enqueue(instance,false) end
    end
    applyGlobalSettings()
    startProcessing()
end

-- Đồng bộ tùy chọn Item Popups theo Super Optimize.
syncItemPopups = function()
    if session.popupBusy then return end
    if not states.super and session.itemPopupOriginal == nil then return end
    session.popupBusy = true
    task.defer(function()
        local ok, err = pcall(function()
            local library = game:GetService("ReplicatedStorage").Library
            local settings = require(library.Client.SettingsCmds)
            local save = require(library.Client.Save)
            local network = require(library.Client.Network)
            local key = "ItemNotifications"
            local options = require(library.Shared.Variables).SettingsInfo[key].options
            local off = assert(table.find(options, "Off"), "Không tìm thấy tùy chọn Off")
            local current = settings.GetValue(key)
            assert(options[current], "Chưa đọc được Item Popups")

            -- Remote của menu chỉ chuyển sang lựa chọn kế tiếp trong vòng.
            local attempts = 0
            local lastTarget
            while true do
                local owner=environment.RobloxHubOptimize
                local on=owner and owner.active and owner.states.super
                if on and session.itemPopupOriginal == nil then session.itemPopupOriginal = current end
                local target = on and off or session.itemPopupOriginal
                if not target or current == target then
                    if not on then session.itemPopupOriginal = nil end
                    return
                end
                if target ~= lastTarget then
                    lastTarget = target
                    attempts = 0
                end
                assert(attempts < #options, "Không chuyển được Item Popups tới lựa chọn yêu cầu")
                attempts += 1
                local success, reason, newValue = network.Invoke("Toggle Setting", key)
                assert(success and options[newValue], reason or "Game từ chối đổi Item Popups")
                current = newValue
                local data = save.Get()
                if data and data.Settings then data.Settings[key] = current end
                if current ~= target then task.wait(0.2) end
            end
        end)
        session.popupBusy = false
        if not ok then warn("[Super Optimize] Item Popups: " .. tostring(err)) end
    end)
end

-- Áp dụng thay đổi trạng thái của một toggle Optimize.
local function updateState(key, enabled)
    if not controller.active then return end
    enabled = enabled == true
    if states[key] == enabled then return end
    states[key] = enabled
    if key == "objects" or key == "super" then
        if states.objects and not states.super then
            task.defer(connectObjectDamage)
        else
            if damageConnection then damageConnection:Disconnect(); damageConnection = nil end
            for object in pairs(objectBoxes) do removeObjectBox(object) end
        end
    end
    if key == "super" then
        controller.refreshEvent = not enabled
        requestRendering("super", enabled)
        syncItemPopups()
    end
    refreshVisuals()
end

-- Xuất toggle ẩn loot box và hiệu ứng liên quan.
features.OptimizeDisableLootBoxes = {
    duy = function(enabled)
        updateState("lootBoxes", enabled)
    end,
}

-- Xuất toggle thay vật thể trong zone bằng khối xám.
features.OptimizeDisableObjects = {
    duy = function(enabled)
        updateState("objects", enabled)
    end,
}

-- Xuất toggle tối ưu hiển thị tổng hợp.
features.OptimizeSuper = {
    requestRendering = requestRendering,
    duy = function(enabled, shared)
        if shared then controller.shared = shared end
        updateState("super", enabled)
    end,
}

-- Lưu giới hạn FPS của client trước khi bật toggle.
local fpsTarget = 30
local previousFpsCap
local fpsEnabled = false
local setFpsCap = setfpscap or set_fps_cap
local getFpsCap = getfpscap or get_fps_cap

-- Áp dụng giới hạn FPS qua API của executor.
local function applyFpsCap(value)
    if type(setFpsCap) ~= "function" then
        warn("[FPS Limit] Executor không hỗ trợ giới hạn FPS")
        return false
    end
    local ok, err = pcall(setFpsCap, value)
    if not ok then warn("[FPS Limit] " .. tostring(err)) end
    return ok
end

features.OptimizeFpsLimit = {
    setTarget = function(value)
        if not controller.active then return false end
        local fps = tonumber(value)
        if not fps or fps < 1 or fps > 2000 or fps % 1 ~= 0 then
            warn("[FPS Limit] Nhập số nguyên từ 1 đến 2000")
            return false
        end
        fpsTarget = fps
        if fpsEnabled then applyFpsCap(fpsTarget) end
        return true
    end,
    duy = function(enabled)
        if not controller.active or enabled == fpsEnabled then return end
        if enabled then
            local saved = 0
            if type(getFpsCap) == "function" then
                local ok, value = pcall(getFpsCap)
                if ok and type(value) == "number" then saved = value end
            end
            if applyFpsCap(fpsTarget) then
                previousFpsCap = saved
                fpsEnabled = true
            end
        elseif applyFpsCap(previousFpsCap) then
            previousFpsCap = nil
            fpsEnabled = false
        end
    end,
}

controller.states=states
controller.stop=function()
    if not controller.active then return end
    states.super,states.objects,states.lootBoxes=false,false,false
    disconnectWatches()
    if damageConnection then damageConnection:Disconnect();damageConnection=nil end
    for object in pairs(objectBoxes) do removeObjectBox(object) end
    for instance in pairs(originals) do applyProperties(instance,{}) end
    refreshEventVisuals()
    table.clear(queue);table.clear(pending)
    first,last=1,0
    requestRendering("super",false)
    syncItemPopups()
    features.OptimizeFpsLimit.duy(false)
    controller.active=false
end
environment.RobloxHubOptimize=controller

return features
