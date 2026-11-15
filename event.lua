-- Khai báo các tính năng Event theo flag của UI.
local features = {}
local startedAt = ...
local scriptStartedAt = type(startedAt) == "number" and startedAt or os.clock()

local player = game:GetService("Players").LocalPlayer
local library = game:GetService("ReplicatedStorage").Library
local client = library.Client
local instancing = require(client.InstancingCmds)
local tycoon = require(client.PumpkinTycoonCmds)
local tycoonTypes = require(library.Types.PumpkinTycoon)
local buttons = require(library.Util.PumpkinTycoonButtons)
local customEggs = require(client.CustomEggsCmds)
local eggs = require(client.EggCmds)
local currency = require(client.CurrencyCmds)
local eggPrice = require(library.Balancing.CalcEggPricePlayer)
local network = require(client.Network)
local playerPet = require(client.PlayerPet)
local breakables = require(client.BreakableFrontend)
local petCmds = require(client.PetCmds)

-- Cấu hình mở map Pumpkin Tycoon.
local instanceId = "PumpkinTycoon"
local entryRetryDelay = 10
local scanInterval = 0.5
local pressTimeout = 2
local retryDelay = 5
local yellowRetryDelay = 15
local lastZone = tycoonTypes.PART1_ZONES
local hatchGoal = 15
local hatchInterval = 1
local hatchCounts = {}
local enabled = false
local pumpkinEnabled = false
local fastFarmEnabled = false
local workerRunning = false
local generation = 0

-- Vào map sự kiện.

-- Kiểm tra trạng thái instance của người chơi.
local function isInEvent()
    return instancing.GetInstanceID() == instanceId
end

-- Dùng luồng dịch chuyển của game để vào Pumpkin Tycoon.
local function enterEvent()
    if not instancing.DoesMeetRequirement(instanceId) then return end
    local ok, err = pcall(instancing.Enter, instanceId)
    if not ok then warn("[Auto Open Map Event] Vào map: " .. tostring(err)) end
end

-- Nhận diện pad mở được.

-- Chỉ chọn mặt Press màu vàng, xanh lá hoặc xanh dương.
local function getPress(pad)
    if string.find(string.lower(pad.Name), "completionreward", 1, true) then return end
    local press = pad:FindFirstChild("Press")
    if not press or not press:IsA("BasePart") or press.Transparency >= 1 then return end
    local touch = press:FindFirstChild("Touch")
    if not touch or not touch:IsA("BasePart") or not touch.CanTouch then return end

    local color = press.Color
    local hue, saturation, brightness = color:ToHSV()
    -- Nhận cả xanh dương đã bị game pha tối khi render pad đặc biệt.
    if hue >= 0.49 and hue <= 0.75 and color.B > color.R * 1.2 and color.B >= color.G then
        return press, touch, false
    end
    if hue >= 0.11 and hue <= 0.73 and saturation >= 0.35 and brightness >= 0.25 then
        return press, touch, hue < 0.25
    end
end

-- Chọn pad hợp lệ gần nhân vật nhất.
local function findPad(folder, origin, retryAt)
    local now = os.clock()
    local bestPad, bestDistance
    local starter = folder:FindFirstChild(tycoonTypes.ZONES[1].Section .. "_Zone")
    if starter and now >= (retryAt[starter] or 0) and getPress(starter) then return starter end
    for _, pad in ipairs(folder:GetChildren()) do
        if now < (retryAt[pad] or 0) then continue end
        local press = getPress(pad)
        if press then
            local distance = (press.Position - origin).Magnitude
            if not bestDistance or distance < bestDistance then
                bestPad, bestDistance = pad, distance
            end
        end
    end
    return bestPad
end

-- Kích hoạt pad bằng cách tiếp đất.

-- Đặt bàn chân cao hơn mặt pad 1,5 stud để tiếp đất tự nhiên.
local function pressPad(folder, pad, character, humanoid, root, runGeneration)
    if pad.Parent ~= folder then return end
    local press, touch, isYellow = getPress(pad)
    if not press then return end

    local original = character:GetPivot()
    local rootOffset = original:ToObjectSpace(root.CFrame)
    local surface = math.abs(press.CFrame.RightVector.Y) * press.Size.X / 2
        + math.abs(press.CFrame.UpVector.Y) * press.Size.Y / 2
        + math.abs(press.CFrame.LookVector.Y) * press.Size.Z / 2
    local leg = character:FindFirstChild("Left Leg")
    local footOffset = root.Size.Y / 2 + humanoid.HipHeight
    if humanoid.RigType == Enum.HumanoidRigType.R6 and leg then
        footOffset += leg.Size.Y
    end
    local position = Vector3.new(touch.Position.X, press.Position.Y + surface + footOffset + 1.5, touch.Position.Z)

    -- Chờ pad biến mất để xác nhận lần mở.
    local ok, err = pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        character:PivotTo(CFrame.new(position) * root.CFrame.Rotation * rootOffset:Inverse())
        local deadline = os.clock() + pressTimeout
        repeat
            task.wait(0.05)
        until pad.Parent ~= folder or press.Parent ~= pad or os.clock() >= deadline
            or generation ~= runGeneration or player.Character ~= character or humanoid.Health <= 0
            or not isInEvent()
    end)

    -- Trả nhân vật hiện tại về vị trí đã lưu.
    if isInEvent() and player.Character == character and humanoid.Health > 0 and root.Parent == character then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        character:PivotTo(original)
    end
    if not ok then warn("[Auto Open Map Event] " .. tostring(err)) end
    return isYellow and yellowRetryDelay or retryDelay, ok and pad.Parent ~= folder
end

-- Xác định zone cao nhất trên đảo của người chơi.
local function getFarmZone()
    local owned = tycoon.Feature("Buttons").State()
    local plot = tycoon.Feature("Island").Plot()
    local model = plot and plot:GetModel()
    if not owned or not model then return end
    local zone = buttons.FarmZone(owned, lastZone)
    local slab = zone and buttons.ZoneSlab(model, zone)
    return zone, slab, plot.ModelId, owned
end

-- Đưa nhân vật vào phần sát trứng nhất vẫn nằm trong zone farm.
local function standInZone(character, humanoid, root, slab, eggPosition)
    local point = slab.CFrame:PointToObjectSpace(eggPosition or slab.Position)
    local x = math.max(0, slab.Size.X / 2 - 1)
    local z = math.max(0, slab.Size.Z / 2 - 1)
    local floor = slab.CFrame:PointToWorldSpace(Vector3.new(
        math.clamp(point.X, -x, x), slab.Size.Y / 2, math.clamp(point.Z, -z, z)))
    local current = slab.CFrame:PointToObjectSpace(root.Position)
    if math.abs(current.X) <= x + 0.25 and math.abs(current.Z) <= z + 0.25 and math.abs(current.Y) < 12
        and (not eggPosition or (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(floor.X, 0, floor.Z)).Magnitude < 3) then
        return
    end
    local height = root.Size.Y / 2 + humanoid.HipHeight + 0.5
    local leg = humanoid.RigType == Enum.HumanoidRigType.R6 and character:FindFirstChild("Left Leg")
    if leg then height += leg.Size.Y end
    local offset = root.CFrame:ToObjectSpace(character:GetPivot())
    root.AssemblyLinearVelocity = Vector3.zero
    character:PivotTo(CFrame.new(floor + Vector3.new(0, height, 0)) * root.CFrame.Rotation * offset)
    return true
end

-- Gửi pet đánh breaker thuộc đúng zone và đảo hiện tại.
local function clearFarmTargets(state)
    if not next(state.assigned) then return end
    for _, pet in pairs(playerPet.GetByPlayer(player) or {}) do
        local target = pet.euid and state.assigned[pet.euid]
        if target and pet:GetTargetType() == "Breakable" and pet:GetTargetValue() == target then
            pet:ClearTarget()
        end
    end
    table.clear(state.assigned)
    state.nextSend = 0
end

-- Chia pet theo lô cho breaker trong zone hiện tại.
local function farmZone(state, zone, plotId)
    local now = os.clock()
    if now < state.nextFarm then return end
    state.nextFarm = now + (fastFarmEnabled and 0.2 or 1)
    if now >= state.nextEquip then
        petCmds.EquipBest()
        state.nextEquip = now + 15
    end

    local things = workspace:FindFirstChild("__THINGS")
    local folder = things and things:FindFirstChild("Breakables")
    if not folder then return end
    local area = tycoonTypes.ZONES[zone].Section .. "_Zone_" .. tostring(plotId)
    local targets = {}
    for _, model in ipairs(folder:GetChildren()) do
        if model:GetAttribute("ParentID") == instanceId and model:GetAttribute("AreaID") == area then
            local uid = model:GetAttribute("BreakableUID")
            local data = uid and breakables.Get(uid)
            local owner = data and data.modifier and data.modifier.Owner
            if data and data.health > 0 and not data.disableDamage and (not owner or owner == player.Name) then
                table.insert(targets, data)
            end
        end
    end
    if #targets == 0 then
        clearFarmTargets(state)
        return
    end
    -- Ưu tiên chest và giữ pet trên breaker còn sống.
    table.sort(targets, function(a, b)
        if (a.class == "Chest") ~= (b.class == "Chest") then return a.class == "Chest" end
        if a.health ~= b.health then return a.health < b.health end
        return tostring(a.uid) < tostring(b.uid)
    end)
    local assigned, eligible, counts, idle = {}, {}, {}, {}
    for _, target in ipairs(targets) do eligible[target.uid] = true end
    for _, pet in pairs(playerPet.GetByPlayer(player) or {}) do
        local id = pet.euid
        if id then
            local uid = state.assigned[id]
            if uid and eligible[uid] then
                assigned[id] = uid
                counts[uid] = (counts[uid] or 0) + 1
            else
                table.insert(idle, id)
            end
        end
    end
    for _, id in ipairs(idle) do
        local best = targets[1].uid
        for _, target in ipairs(targets) do
            if (counts[target.uid] or 0) < (counts[best] or 0) then best = target.uid end
            if not counts[best] then break end
        end
        assigned[id] = best
        counts[best] = (counts[best] or 0) + 1
    end
    if next(assigned) and (#idle > 0 or now >= state.nextSend) then
        network.Fire("Breakables_JoinPetBulk", assigned)
        state.nextSend = now + 1
    end
    state.assigned = assigned
    network.UnreliableFire("Breakables_PlayerDealDamage", targets[1].uid)
end

-- Tìm trứng theo zone và tên cấu hình của game.
local function findZoneEgg(zone, nearPosition)
    local things = workspace:FindFirstChild("__THINGS")
    local folder = things and things:FindFirstChild("CustomEggs")
    if not folder then return end
    local eggName = tycoonTypes.ZONES[zone].Egg
    local closest, closestDistance
    for _, model in ipairs(folder:GetChildren()) do
        if model:GetAttribute("ZoneNumber") == zone then
            local egg = customEggs.Get(model.Name)
            if egg and egg._id == eggName and egg:IsHatchable() then
                if not nearPosition then return egg end
                local distance = (egg:GetPosition() - nearPosition).Magnitude
                if not closestDistance or distance < closestDistance then
                    closest, closestDistance = egg, distance
                end
            end
        end
    end
    return closest
end

-- Mở đúng một quả khi đủ xu và đếm lượt server xác nhận.
local function hatchOne(state, zone, egg)
    local now = os.clock()
    if now < state.nextHatch then return end
    state.nextHatch = now + hatchInterval
    local directory = egg:Directory()
    local price = eggPrice(directory, nil, not egg._allowChargedAndGolden)
    if not currency.CanAfford(directory.currency, price) then return end
    local success = network.Invoke("CustomEggs_Hatch", egg._uid, 1)
    if success == true then hatchCounts[zone] = (hatchCounts[zone] or 0) + 1 end
end

-- Mở trứng zone cuối theo giới hạn hiện tại của game.
local function hatchFinalEgg(state, egg)
    local now = os.clock()
    if now < state.nextHatch then return end
    state.nextHatch = now + hatchInterval

    local directory = egg:Directory()
    local count = egg:GetMaxEggCount() or eggs.GetMaxHatch(directory)
    if type(count) ~= "number" or count < 1 then return end
    local price = eggPrice(directory, nil, not egg._allowChargedAndGolden)
    if currency.CanAfford(directory.currency, price * count) then
        network.Invoke("CustomEggs_Hatch", egg._uid, count)
    end
end

-- Tạm dừng mở pad trong lúc chuẩn bị đủ 15 trứng của zone.
local function updateEvent(state, character, humanoid, root)
    local zone, slab, plotId, owned = getFarmZone()
    if not enabled then
        if zone and slab then
            standInZone(character, humanoid, root, slab)
            farmZone(state, zone, plotId)
        end
        return
    end
    local finalEgg = zone == lastZone and slab and findZoneEgg(zone, slab.Position)
    if finalEgg then
        if standInZone(character, humanoid, root, slab, finalEgg:GetPosition()) then
            state.nextHatch = os.clock() + scanInterval
            return
        end
        farmZone(state, zone, plotId)
        hatchFinalEgg(state, finalEgg)
        if not enabled or player.Character ~= character or not isInEvent() then return end
    elseif zone and slab then
        local egg
        local waitingForEgg = false
        if zone < lastZone and (hatchCounts[zone] or 0) < hatchGoal then
            egg = findZoneEgg(zone)
            waitingForEgg = egg ~= nil or buttons.Owned(owned, tycoonTypes.ZONES[zone].Section .. "_Egg")
        end
        standInZone(character, humanoid, root, slab, egg and egg:GetPosition())
        farmZone(state, zone, plotId)
        if waitingForEgg then
            if egg then hatchOne(state, zone, egg) end
            return
        end
    elseif zone and zone < lastZone and (hatchCounts[zone] or 0) < hatchGoal
        and buttons.Owned(owned, tycoonTypes.ZONES[zone].Section .. "_Egg") then
        return
    end

    local folder = workspace:FindFirstChild("PumpkinTycoonPads")
    local pad = folder and findPad(folder, root.Position, state.retryAt)
    if pad then
        local delay, opened = pressPad(folder, pad, character, humanoid, root, generation)
        if delay and pad.Parent == folder then state.retryAt[pad] = os.clock() + delay end
        if opened then task.wait(0.5) end
    end
end

-- Auto Pumpkin / Chỉ chọn bí ngô còn sống trên đảo của mình.
local function findPumpkin(position)
    local plot = tycoon.Feature("Island").Plot()
    local target, distance
    for _, breaker in pairs(plot and plot.Breakables or {}) do
        if breaker.parentID ~= instanceId or not string.match(breaker.areaID or "", "^Pedestal_%d+$")
            or breaker.health <= 0 or breaker.disableDamage
            or not breaker.model or not breaker.model.Parent then continue end
        local nextDistance = (breaker.position - position).Magnitude
        if not distance or nextDistance < distance then
            target, distance = breaker, nextDistance
        end
    end
    return target
end

-- Kiểm tra bảng My Pumpkin và nút Auto đã hiện.
local function isMyPumpkinOpen(merchant)
    if not merchant.IsOpen() or merchant.CurrentTab() ~= "Pumpkins" then return false end
    local gui = merchant.Gui()
    local frame = gui and gui:FindFirstChild("Frame")
    local page = frame and frame:FindFirstChild("PumpkinsFrame")
    return page and page.Visible
end

-- Mở đúng tab My Pumpkin bằng luồng mở merchant của game.
local function openMyPumpkin(merchant)
    if not merchant.Enabled() or not merchant.Unlocked() then return end
    if not merchant.IsOpen() then merchant.OpenRemote() end
    if pumpkinEnabled and isInEvent() and merchant.IsOpen() and not isMyPumpkinOpen(merchant) then
        merchant.ShowTab("Pumpkins")
    end
end

-- Lưu vị trí trước khi đứng cạnh bí ngô.
local function attackPumpkin(target, character, humanoid, root)
    local original = character:GetPivot()
    local assigned = {}
    local merchant = tycoon.Feature("Merchant")
    local nextOpenAt = 0
    local ok, err = pcall(function()
        petCmds.EquipBest()
        while pumpkinEnabled and isInEvent() and player.Character == character
            and humanoid.Health > 0 and root.Parent == character do
            local breaker = breakables.Get(target.uid)
            if not breaker or breaker.health <= 0 or not breaker.model or not breaker.model.Parent then break end
            if (root.Position - breaker.position).Magnitude > 8 then
                local direction = root.Position - breaker.position
                local flat = Vector3.new(direction.X, 0, direction.Z)
                local offset = flat.Magnitude > 0.01 and flat.Unit * 4 or Vector3.new(4, 0, 0)
                local height = root.Size.Y / 2 + humanoid.HipHeight + 0.5
                local leg = humanoid.RigType == Enum.HumanoidRigType.R6 and character:FindFirstChild("Left Leg")
                if leg then height += leg.Size.Y end
                local rootOffset = root.CFrame:ToObjectSpace(character:GetPivot())
                root.AssemblyLinearVelocity = Vector3.zero
                character:PivotTo(CFrame.new(breaker.position + offset + Vector3.new(0, height, 0))
                    * root.CFrame.Rotation * rootOffset)
            end
            if os.clock() >= nextOpenAt then
                nextOpenAt = os.clock() + 2
                local opened, openError = pcall(openMyPumpkin, merchant)
                if not opened then warn("[Auto Pumpkin] My Pumpkin: " .. tostring(openError)) end
                if not pumpkinEnabled or not isInEvent() or player.Character ~= character then break end
            end
            local batch = {}
            for _, pet in pairs(playerPet.GetByPlayer(player) or {}) do
                if pet.euid then
                    batch[pet.euid] = target.uid
                    assigned[pet.euid] = true
                end
            end
            if next(batch) then network.Fire("Breakables_JoinPetBulk", batch) end
            network.UnreliableFire("Breakables_PlayerDealDamage", target.uid)
            task.wait(0.25)
        end
    end)

    -- Quay lại trước khi cho phép các vòng farm chạy tiếp.
    local restored, restoreError = pcall(function()
        if isInEvent() and player.Character == character and humanoid.Health > 0 and root.Parent == character then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            character:PivotTo(original)
        end
        for _, pet in pairs(playerPet.GetByPlayer(player) or {}) do
            if pet.euid and assigned[pet.euid] and pet:GetTargetType() == "Breakable"
                and pet:GetTargetValue() == target.uid then
                pet:ClearTarget()
            end
        end
    end)
    if not ok or not restored then warn("[Auto Pumpkin] " .. tostring(err or restoreError)) end
end

-- Điều phối chung để bí ngô và mở map không tranh vị trí.
local function startWorker()
    if workerRunning then return end
    workerRunning = true

    task.defer(function()
        local state = {
            retryAt = setmetatable({}, { __mode = "k" }),
            assigned = {},
            nextFarm = 0,
            nextSend = 0,
            nextEquip = 0,
            nextHatch = 0,
        }
        local nextEntryAt = 0
        while enabled or pumpkinEnabled or fastFarmEnabled do
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = humanoid and humanoid.RootPart
            if not isInEvent() or not (enabled or fastFarmEnabled) then clearFarmTargets(state) end
            if root and humanoid.Health > 0 then
                if isInEvent() then
                    local pumpkin = pumpkinEnabled and findPumpkin(root.Position)
                    if pumpkin then
                        clearFarmTargets(state)
                        attackPumpkin(pumpkin, character, humanoid, root)
                    elseif enabled or fastFarmEnabled then
                        local ok, err = pcall(updateEvent, state, character, humanoid, root)
                        if not ok then
                            warn("[Auto Open Map Event] " .. tostring(err))
                            task.wait(retryDelay)
                        end
                    end
                elseif enabled and os.clock() >= nextEntryAt then
                    enterEvent()
                    nextEntryAt = os.clock() + entryRetryDelay
                end
            end
            task.wait(fastFarmEnabled and 0.05 or scanInterval)
        end
        clearFarmTargets(state)
        workerRunning = false
    end)
end

-- Quét riêng PumpkinTycoonPads để bỏ qua các nút thưởng trong PumpkinTycoonIslands.
features.EventAutoOpenMap = {
    duy = function(on)
        if enabled == on then return end
        enabled = on
        generation += 1
        if on then startWorker() end
    end,
}

-- Auto Pumpkin / Đồng bộ Lock và chế độ My Pumpkin trên đảo của mình.
local pumpkinSettingsJob

-- Dùng trạng thái đã lưu của game để chỉ gửi lệnh khi cần sửa.
local function syncPumpkinSettings(state)
    local island = tycoon.Feature("Island")
    local plot = island.Plot()
    if not plot then return end
    if state.plot ~= plot then
        state.plot = plot
        table.clear(state.retryAt)
    end

    local stock = tycoon.Feature("Stock")
    if island.Get(nil, stock.AUTO_PLACE_VAR) == false and os.clock() >= (state.retryAt.auto or 0)
        and isMyPumpkinOpen(tycoon.Feature("Merchant")) then
        state.retryAt.auto = os.clock() + 2
        plot:Invoke(stock.VERB_AUTO_PLACE, true)
    end

    if not pumpkinEnabled or island.Plot() ~= plot then return end
    local lock = tycoon.Feature("Lock")
    for index = 1, tycoonTypes.MAX_PEDESTALS do
        if not pumpkinEnabled or island.Plot() ~= plot then return end
        if lock.Locked(index) then
            if os.clock() >= (state.retryAt[index] or 0) then
                state.retryAt[index] = os.clock() + 2
                plot:Invoke(lock.VERB_LOCK, index, false)
            end
        else
            state.retryAt[index] = nil
        end
    end
    if island.Get(nil, stock.AUTO_PLACE_VAR) ~= false then state.retryAt.auto = nil end
end

-- Theo dõi cài đặt ngay cả khi vòng đánh bí ngô đang chạy.
local function startPumpkinSettings()
    if pumpkinSettingsJob then return end
    pumpkinSettingsJob = task.defer(function()
        local state = { retryAt = {} }
        while pumpkinEnabled do
            local ok, err = pcall(syncPumpkinSettings, state)
            if not ok then warn("[Auto Pumpkin] " .. tostring(err)) end
            task.wait(ok and 0.25 or 2)
        end
        pumpkinSettingsJob = nil
    end)
end

-- Bật đánh bí ngô và giữ cài đặt tự động.
features.EventAutoPumpkin = {
    duy = function(on)
        pumpkinEnabled = on
        if on then
            startPumpkinSettings()
            startWorker()
        end
    end,
}

-- Bật Fast Farm cho zone cao nhất đã mở trên đảo.
features.EventFastFarm = {
    duy = function(on)
        fastFarmEnabled = on
        if on then startWorker() end
    end,
}

-- Auto Buy Pumpkin / Mua bí ngô từ merchant trong Pumpkin Tycoon.
do
    local merchantData = require(library.Types.PumpkinTycoon.Merchant)
    local buying = false
    local buyJob

    -- Chọn cấp cao nhất còn hàng mà số xu hiện tại mua được.
    local function chooseBand(items, coins)
        local config = merchantData.Config()
        for index = #merchantData.BANDS, 1, -1 do
            local band = merchantData.BANDS[index]
            local offer = config[band]
            if offer and (items[band] or 0) > 0 and coins >= offer.Price then
                return band
            end
        end
        return nil
    end

    -- Đọc lại quầy và sức chứa trước mỗi lần mua.
    local function buyPumpkin()
        if not isInEvent() then return 2 end
        local merchant = tycoon.Feature("Merchant")
        if not merchant.Enabled() or not merchant.Unlocked() then return 2 end
        local island = tycoon.Feature("Island")
        local plot = island.Plot()
        if not plot then return 2 end

        local stock = merchantData.CleanStock(island.Get(nil, tycoonTypes.VAR.Stock))
        if #stock >= merchant.Slots() then return 2 end
        local offers = merchantData.Clean(island.Get(nil, tycoonTypes.VAR.Merchant))
        local coins = currency.Get(tycoonTypes.COIN)
        if not offers or type(coins) ~= "number" then return 2 end
        local band = chooseBand(offers.Items, coins)
        if not band then return 2 end

        local success = plot:Invoke(merchantData.VERB_BUY, band)
        return success == true and 1 or 3
    end

    -- Giữ một vòng mua để tránh gửi trùng khi bật tắt nhanh.
    features.EventAutoBuyPumpkin = {
        duy = function(on)
            buying = on
            if not on or buyJob then return end
            buyJob = task.defer(function()
                while buying do
                    local ok, delay = pcall(buyPumpkin)
                    task.wait(ok and delay or 3)
                end
                buyJob = nil
            end)
        end,
    }
end

-- Auto Pumpkin Upgrade / Nâng cấp các mục đã chọn trong máy.
do
    local definitions = require(library.Types.PumpkinTycoon.Upgrades)
    -- Sửa danh sách dropdown tại đây bằng tên hiển thị và ID nâng cấp.
    local catalog = {
        { name = "Spawn Luck", track = "SpawnLuck" },
        { name = "Patch Coin Payout", track = "PumpkinCoins" },
        { name = "Pumpkin Damage", track = "PumpkinDamage" },
        { name = "Faster Spawns", track = "RespawnSpeed" },
        { name = "Merchant Stock", track = "StockSlots" },
        { name = "Pumpkin Chase Odds", track = "ChaseOdds" },
        { name = "Island Luck", track = "EggLuck" },
        { name = "Merchant Luck", track = "MerchantLuck" },
        { name = "Auto Break", track = "AutoBreakRules" },
    }
    local options, tracksByName = {}, {}
    local selected = {}
    local retryAt = {}
    local upgrading = false
    local upgradeJob

    -- Dùng cùng tên cho dropdown và cấu hình launcher.
    for _, entry in ipairs(catalog) do
        table.insert(options, entry.name)
        tracksByName[entry.name] = entry.track
    end

    -- Tìm một cấp đã chọn mà ví Pumpkin Tokens trả được.
    local function upgradeOne()
        if not isInEvent() or not next(selected) then return end
        local upgrades = tycoon.Feature("Upgrades")
        if not upgrades.Enabled() or not upgrades.Unlocked() then return end
        local plot = tycoon.Feature("Island").Plot()
        if not plot then return end

        local tokens = upgrades.Tokens()
        local now = os.clock()
        for _, entry in ipairs(catalog) do
            local track = entry.track
            if not selected[track] or now < (retryAt[track] or 0) then continue end
            local definition = definitions.ROWS[track]
            if not definition then continue end
            local tier = upgrades.Tier(track)
            if tier >= #definition.Powers or upgrades.Capped(track, tier) then continue end
            local cost = upgrades.Cost(track, tier + 1)
            if cost and tokens >= cost then
                local success = plot:Invoke(upgrades.VERB_BUY, track)
                if success ~= true then retryAt[track] = os.clock() + 5 end
                return
            end
        end
    end

    -- Chỉ lưu các mục hợp lệ từ dropdown hoặc launcher.
    local function setSelection(values)
        table.clear(selected)
        for _, name in ipairs(type(values) == "table" and values or {}) do
            local track = tracksByName[name]
            if track then selected[track] = true end
        end
    end

    -- Giữ một vòng nâng cấp và đọc lại giá sau mỗi lượt.
    features.EventAutoPumpkinUpgrade = {
        getOptions = function() return table.clone(options) end,
        setSelection = setSelection,
        duy = function(on)
            upgrading = on
            if not on or upgradeJob then return end
            upgradeJob = task.defer(function()
                while upgrading do
                    local ok, err = pcall(upgradeOne)
                    if not ok then warn("[Auto Pumpkin Upgrade] " .. tostring(err)) end
                    task.wait(ok and 1 or 3)
                end
                upgradeJob = nil
            end)
        end,
    }
end

-- Auto Flannel Gift / Mở từng hộp Flannel Gift bằng API của game.
do
    local giftId = "Flannel Gift"
    local inventory = require(client.InventoryCmds)
    local lootboxItem = require(library.Items.LootboxItem)
    local lootboxCmds = require(client.LootboxCmds)
    local opening = false
    local job

    -- Chỉ lấy stack Lootbox mang đúng ID Flannel Gift.
    local function openOne()
        if not inventory.Container() then return 1 end
        local matches = lootboxItem(giftId):FindAny()
        local item = matches and matches[1]
        if not item or item:GetId() ~= giftId or item:GetAmount() < 1 then return 1 end
        local success = lootboxCmds.Open(item, 1)
        return success and 1 or 3
    end

    -- Chạy một vòng mở để mỗi lần chỉ gửi một yêu cầu.
    features.EventAutoFlannelGift = {
        duy = function(on)
            opening = on
            if not on or job then return end
            job = task.defer(function()
                while opening do
                    local ok, delay = pcall(openOne)
                    task.wait(ok and delay or 3)
                end
                job = nil
            end)
        end,
    }
end

-- Auto Equip Boost / Dùng boost đã chọn khi hiệu ứng cũ hết.
do
    local boostUtil = require(library.Util.PumpkinTycoonBoosts)
    local save = require(client.Save)
    local directory = require(library.Directory).Consumables
    local catalog = {
        { name = "Patch Coin Boost II", id = "Patch Coin Boost", family = "Coins", tier = 2 },
        { name = "Patch Coin Boost I", id = "Patch Coin Boost", family = "Coins", tier = 1 },
        { name = "Pumpkin Damage Boost II", id = "Pumpkin Damage Boost", family = "Damage", tier = 2 },
        { name = "Pumpkin Damage Boost I", id = "Pumpkin Damage Boost", family = "Damage", tier = 1 },
        { name = "Island Luck Boost II", id = "Island Luck Boost", family = "IslandLuck", tier = 2 },
        { name = "Island Luck Boost I", id = "Island Luck Boost", family = "IslandLuck", tier = 1 },
    }
    local options, selected, retryAt = {}, {}, {}
    local refreshAt = {}
    local enabled = false
    local job

    for _, entry in ipairs(catalog) do table.insert(options, entry.name) end

    -- Tìm stack có đúng ID và cấp được chọn.
    local function findBoost(inventory, entry)
        for uid, item in pairs(inventory) do
            if item.id == entry.id and (item.tn or 1) == entry.tier
                and not item._lk and (item._am or 1) > 0 then
                return uid
            end
        end
        return nil
    end

    -- Dùng một boost mỗi lượt sau khi kiểm tra điều kiện và hiệu ứng đang chạy.
    local function equipBoost()
        if not isInEvent() or not boostUtil.Enabled(player) then return end
        local data = save.Get()
        local inventory = data and data.Inventory and data.Inventory.Consumable
        if not inventory then return end

        for _, entry in ipairs(catalog) do
            local name = entry.name
            local now = os.clock()
            if not selected[name] or now < (retryAt[name] or 0) or now < (refreshAt[entry.family] or 0)
                or boostUtil.Power(player, entry.family) > 0 then continue end
            local definition = directory[entry.id]
            if not definition or (definition.Requirement and not definition.Requirement(player)) then continue end
            local uid = findBoost(inventory, entry)
            if uid then
                retryAt[name] = now + 10
                if network.Invoke("Consumables_Consume", uid, 1) == true then
                    refreshAt[entry.family] = os.clock() + 10
                end
                return
            end
        end
    end

    -- Đọc tên cũ không có hậu tố như lựa chọn cả hai cấp.
    local function resolveSelection(values)
        local names = {}
        if type(values) ~= "table" then return names end
        for _, entry in ipairs(catalog) do
            if table.find(values, entry.name) or table.find(values, entry.id) then
                table.insert(names, entry.name)
            end
        end
        return names
    end

    -- Đồng bộ lựa chọn từ dropdown hoặc launcher.
    features.EventAutoEquipBoost = {
        getOptions = function() return table.clone(options) end,
        resolveSelection = resolveSelection,
        setSelection = function(values)
            table.clear(selected)
            for _, name in ipairs(resolveSelection(values)) do
                selected[name] = true
            end
        end,
        duy = function(on)
            enabled = on
            if not on or job then return end
            job = task.defer(function()
                while enabled do
                    local ok, err = pcall(equipBoost)
                    if not ok then warn("[Auto Equip Boost] " .. tostring(err)) end
                    task.wait(ok and 1 or 3)
                end
                job = nil
            end)
        end,
    }
end

-- Optimize Event / Chỉ thay đổi hiển thị của Pumpkin Tycoon.
do
    local job
    local owners = {}
    local original = setmetatable({}, { __mode = "k" })
    local invisible = NumberSequence.new(1)
    local touchClient = game:GetService("UserInputService").TouchEnabled
    local watched = {}
    local queue, first, last = {}, 1, 0
    local hatchEnvironment, originalHatchAnimation, skipHatchAnimation
    local hatching = require(client.HatchingCmds)
    local signal = require(library.Signal)
    local protectedGeometry = {
        breaks_zones = true,
        break_zones = true,
        safety_net = true,
        interactable = true,
        spawnposition = true,
    }

    -- Bỏ animation trước khi game dựng trứng và màn hình Click to open.
    local function suppressHatchAnimation()
        if skipHatchAnimation or type(getsenv) ~= "function" then return end
        local playerScripts = player:FindFirstChild("PlayerScripts")
        local scripts = playerScripts and playerScripts:FindFirstChild("Scripts")
        local gameScripts = scripts and scripts:FindFirstChild("Game")
        local frontend = gameScripts and gameScripts:FindFirstChild("Egg Opening Frontend")
        if not frontend then return end
        local ok, environment = pcall(getsenv, frontend)
        if not ok or type(environment) ~= "table" then return end
        local play = environment.PlayNormalEggAnimation
        if type(play) ~= "function" then return end

        local function skip(eggName, ...)
            local instance = instancing.Get()
            if not next(owners) or not instance or instance.instanceID ~= instanceId then
                return play(eggName, ...)
            end

            -- Tiếp tục Auto Hatch của game sau khi callback nhận pet chạy xong.
            local egg = hatching.GetEggDirectory()
            if hatching.IsHatching() and egg and (egg._id == eggName or egg._id == "Infinity Egg") then
                task.defer(function()
                    local current = instancing.Get()
                    if current ~= instance or not hatching.IsHatching() or hatching.GetEggDirectory() ~= egg then return end
                    signal.Fire("Hatching", eggName)
                    hatching.AttemptHatch()
                end)
            end
            return nil
        end

        ok = pcall(function() environment.PlayNormalEggAnimation = skip end)
        if ok then
            hatchEnvironment, originalHatchAnimation, skipHatchAnimation = environment, play, skip
        end
    end

    -- Trả lại hàm animation khi tắt Optimize Event hoặc rời event.
    local function restoreHatchAnimation()
        if hatchEnvironment and hatchEnvironment.PlayNormalEggAnimation == skipHatchAnimation then
            hatchEnvironment.PlayNormalEggAnimation = originalHatchAnimation
        end
        hatchEnvironment, originalHatchAnimation, skipHatchAnimation = nil, nil, nil
    end

    -- Lưu thuộc tính gốc trước khi đổi hiển thị.
    local function hideProperty(object, property, value)
        local previous = object[property]
        if previous == value then return end
        local record = original[object] or {}
        if not record[property] then
            record[property] = { previous = previous, hidden = value }
            original[object] = record
        end
        object[property] = value
    end

    -- Khôi phục hiển thị khi tắt toggle hoặc rời sự kiện.
    local function restore()
        for object, record in pairs(original) do
            if object.Parent then
                for property, saved in pairs(record) do
                    if object[property] == saved.hidden then object[property] = saved.previous end
                end
            end
        end
        table.clear(original)
    end

    -- Giữ viền farm, nút thưởng và các part mở khóa.
    local function hideVisual(object, scope, mode, debrisPosition)
        local isPart = object:IsA("BasePart")
        local isSurface = object:IsA("Decal") or object:IsA("Texture")
        local isParticle = object:IsA("ParticleEmitter")
        local isExplosion = object:IsA("Explosion")
        local isAtmosphere = object:IsA("Atmosphere")
        local isLightingEffect = object:IsA("PostEffect") or object:IsA("Clouds")
        local isEffect = isParticle or object:IsA("Beam") or object:IsA("Trail")
            or object:IsA("Light") or object:IsA("Smoke") or object:IsA("Fire")
            or object:IsA("Sparkles") or object:IsA("Highlight")
        if not (isPart or isSurface or isEffect or isExplosion or isAtmosphere or isLightingEffect) then return end

        local keepGeometry = mode ~= "scenery"
        local debrisPart
        local parent = object
        while parent and parent ~= scope do
            local name = string.lower(parent.Name)
            if name == "buttons" or name == "press" or name == "touch"
                or name:find("completionreward", 1, true) or name:find("breakzoneline", 1, true)
                or name:find("pumpkinbreakline", 1, true) or name:find("pumpkinsign", 1, true)
                or name:find("pumpkintimer", 1, true) then
                return
            end
            if protectedGeometry[name] then keepGeometry = true end
            if mode == "breakers" and parent.Parent == scope
                and parent:GetAttribute("ParentID") ~= instanceId then return end
            if mode == "debris" and not debrisPart and parent:IsA("BasePart") then debrisPart = parent end
            parent = parent.Parent
        end

        if mode == "lighting" then
            if isAtmosphere then
                hideProperty(object, "Density", 0)
                hideProperty(object, "Haze", 0)
                hideProperty(object, "Glare", 0)
            elseif isLightingEffect then
                hideProperty(object, "Enabled", false)
            end
            return
        elseif mode == "debris" then
            local position = isExplosion and object.Position or (debrisPart and debrisPart.Position)
            if not (isEffect or isExplosion) or not position or not debrisPosition
                or (position - debrisPosition).Magnitude > 220 then return end
        elseif not keepGeometry and isPart then
            -- Ẩn cả part đang fade để nó không hiện lại khi tải xong.
            hideProperty(object, "LocalTransparencyModifier", 1)
            if touchClient then hideProperty(object, "Transparency", 1) end
        elseif not keepGeometry and isSurface then
            hideProperty(object, "Transparency", 1)
        end

        if isEffect then hideProperty(object, "Enabled", false) end
        if isParticle then hideProperty(object, "Transparency", invisible) end
        if isExplosion then hideProperty(object, "Visible", false) end
    end

    -- Xếp object vào hàng đợi để xử lý theo ngân sách mỗi frame.
    local function enqueue(object, scope, binding, walk)
        local pending = binding.pending[object]
        if pending then
            pending.walk = pending.walk or walk
            return
        end
        last += 1
        local entry = {object = object, scope = scope, binding = binding, walk = walk}
        queue[last] = entry
        binding.pending[object] = entry
    end

    -- Gỡ listener và dọn hàng đợi khi rời sự kiện hoặc tắt tối ưu.
    local function clearWatches()
        for _, binding in pairs(watched) do binding.connection:Disconnect() end
        table.clear(watched)
        table.clear(queue)
        first, last = 1, 0
    end

    -- Gắn listener cho từng cây map khi cây đó xuất hiện.
    local function updateWatches()
        local instance = instancing.Get()
        if not instance or instance.instanceID ~= instanceId then
            if skipHatchAnimation then restoreHatchAnimation() end
            if next(watched) then clearWatches() end
            if next(original) then restore() end
            return
        end
        suppressHatchAnimation()
        local roots = {}
        local function add(root, mode)
            if root then roots[root] = mode end
        end
        add(instance.model, "scenery")
        add(workspace:FindFirstChild("PumpkinTycoonIslands"), "scenery")
        local plot = tycoon.Feature("Island").Plot()
        add(plot and plot:GetModel(), "scenery")
        add(workspace:FindFirstChild("PumpkinTycoonPumpkins"), "effects")
        local things = workspace:FindFirstChild("__THINGS")
        add(things and things:FindFirstChild("Breakables"), "breakers")
        add(things and things:FindFirstChild("AnimatedBreakables"), "breakers")
        add(things and things:FindFirstChild("__FAKE_INSTANCE_GROUND"), "scenery")
        add(things and things:FindFirstChild("VFX"), "debris")
        add(things and things:FindFirstChild("VictoryScene"), "debris")
        add(workspace:FindFirstChild("__DEBRIS"), "debris")
        add(game:GetService("Lighting"), "lighting")
        add(workspace:FindFirstChildOfClass("Terrain"), "lighting")

        for root, binding in pairs(watched) do
            if not roots[root] then
                binding.connection:Disconnect()
                table.clear(binding.pending)
                watched[root] = nil
            end
        end
        for root, mode in pairs(roots) do
            if not watched[root] then
                local binding = {mode = mode, pending = {}}
                watched[root] = binding
                binding.connection = root.DescendantAdded:Connect(function(object)
                    if watched[root] == binding then enqueue(object, root, binding, false) end
                end)
                enqueue(root, root, binding, true)
            end
        end
    end

    -- Dàn lượt quét đầu ra nhiều frame rồi chỉ xử lý object mới.
    local function processQueue()
        local deadline = os.clock() + (touchClient and 0.001 or 0.002)
        local rootPart = player.Character and player.Character.PrimaryPart
        local position = rootPart and rootPart.Position
        for _ = 1, 100 do
            if first > last or os.clock() >= deadline then break end
            local entry = queue[first]
            queue[first] = nil
            first += 1
            local object, scope = entry.object, entry.scope
            entry.binding.pending[object] = nil
            if watched[scope] == entry.binding and (object == scope or object:IsDescendantOf(scope)) then
                if object ~= scope then hideVisual(object, scope, entry.binding.mode, position) end
                if entry.walk and (entry.binding.mode ~= "breakers" or object.Parent ~= scope
                    or object:GetAttribute("ParentID") == instanceId) then
                    for _, child in ipairs(object:GetChildren()) do
                        enqueue(child, scope, entry.binding, true)
                    end
                end
            end
        end
    end

    -- Thu gọn bộ nhớ hàng đợi theo lô nhẹ mỗi ba giây.
    local function trimQueue()
        local remaining = last - first + 1
        if remaining > 128 then return end
        if first == 1 and remaining > 0 then return end
        local compact = {}
        for index = 1, remaining do compact[index] = queue[first + index - 1] end
        queue, first, last = compact, 1, remaining
    end

    -- Chia sẻ Optimize Event giữa toggle riêng và Stats Event.
    local function request(owner, on)
        owners[owner] = on and true or nil
        if next(owners) then
            if job then return end
            job = task.defer(function()
                local nextWatchAt = 0
                local nextTrimAt = os.clock() + 3
                while true do
                    local now = os.clock()
                    if now >= nextWatchAt then
                        updateWatches()
                        nextWatchAt = now + 0.5
                    end
                    if first <= last then processQueue() end
                    if now >= nextTrimAt then
                        trimQueue()
                        nextTrimAt = now + 3
                    end
                    if first <= last then task.wait() else task.wait(0.1) end
                end
            end)
        elseif job then
            task.cancel(job)
            job = nil
            restoreHatchAnimation()
            clearWatches()
            restore()
        end
    end

    features.EventOptimize = {
        duy = function(on) request("toggle", on) end,
        request = request,
    }
end

-- Stats Event / Số dư, zone, kho bí ngô và pet trên nền đen.
do
    local save = require(client.Save)
    local boostUtil = require(library.Util.PumpkinTycoonBoosts)
    local items = require(library.Items)
    local merchant = require(library.Types.PumpkinTycoon.Merchant)
    local runService = game:GetService("RunService")
    local activeGui
    local onQuickClose
    local accent = Color3.fromRGB(255, 191, 105)

    -- Hiện phần trăm hiệu lực của ba boost Pumpkin Tycoon.
    local function eventBoostText()
        local available = isInEvent() and boostUtil.Enabled(player)
        local function status(family)
            local power = available and boostUtil.Power(player, family)
            if type(power) ~= "number" or power <= 0 then return "Tắt" end
            return ("+%g%%"):format(power)
        end
        return table.concat({
            "BOOST EVENT",
            "Patch Coin Boost · " .. status("Coins"),
            "Pumpkin Damage Boost · " .. status("Damage"),
            "Island Luck Boost · " .. status("IslandLuck"),
        }, "\n")
    end

    -- Đọc các zone đã mua và tên trong cấu hình sự kiện.
    local function zoneText(data)
        local lines = { "ZONE ĐÃ MỞ" }
        local owned = isInEvent() and tycoon.Feature("Buttons").State()
        local event = data.InstanceVars and data.InstanceVars[instanceId]
        local paid = event and event.ZonePaid
        for index, zone in ipairs(tycoonTypes.ZONES) do
            if (owned and buttons.Owned(owned, zone.Section .. "_Zone"))
                or (paid and (paid[tostring(index)] or paid[index])) then
                table.insert(lines, ("%d · %s"):format(index, zone.DisplayName))
            end
        end
        if #lines == 1 then table.insert(lines, "—") end
        return table.concat(lines, "\n")
    end

    -- Đọc số bí ngô chờ mọc theo cấp trong My Pumpkin.
    local function stockText()
        if not isInEvent() then return "MY PUMPKIN\n—" end
        local stock = tycoon.Feature("Stock")
        local held = stock.Stock()
        local offers = merchant.Config()
        local lines = { ("MY PUMPKIN · %d/%d"):format(#held, stock.Slots()) }
        for _, row in ipairs(stock.Grouped(held)) do
            local offer = offers[row.band]
            table.insert(lines, ("%s ×%d"):format(offer and offer.Display or row.band, row.count))
        end
        return table.concat(lines, "\n")
    end

    -- Gộp các pet cùng ảnh và tên rồi thêm một pet thường mạnh nhất.
    local function petRows(inventory)
        local byName, rows = {}, {}
        local best, bestPower
        for _, entry in pairs(inventory or {}) do
            local pet = items.From("Pet", table.clone(entry))
            local kind = pet:IsGargantuan() and "Gargantuan" or pet:IsTitanic() and "Titanic" or pet:IsHuge() and "Huge"
            if kind then
                local name, icon = pet:GetName(), pet:GetIcon()
                local key = kind .. name .. tostring(icon)
                if not byName[key] then
                    byName[key] = { kind = kind, name = name, icon = icon, amount = 0 }
                    table.insert(rows, byName[key])
                end
                byName[key].amount += entry._am or 1
            elseif pet:GetExclusiveLevel() == 0 then
                local power = pet:CalculatePower()
                if not bestPower or power > bestPower then best, bestPower = pet, power end
            end
        end
        table.sort(rows, function(a, b)
            if a.kind ~= b.kind then return a.kind < b.kind end
            if a.name ~= b.name then return a.name < b.name end
            return tostring(a.icon) < tostring(b.icon)
        end)
        if best then
            table.insert(rows, 1, { kind = "Pet thường mạnh nhất", name = best:GetName(), icon = best:GetIcon(), amount = 1 })
        end
        return rows
    end

    -- Tạo nhãn chữ cho từng vùng của bảng thống kê.
    local function label(parent, position, size, alignment, textSize)
        local object = Instance.new("TextLabel")
        object.Position, object.Size = position, size
        object.BackgroundTransparency = 1
        object.Font = Enum.Font.GothamBold
        object.TextColor3 = Color3.fromRGB(245, 245, 245)
        object.TextSize = textSize
        object.TextWrapped = true
        object.TextXAlignment = alignment
        object.Text = ""
        object.Parent = parent
        return object
    end

    -- Định dạng số dư đầy đủ theo nhóm ba chữ số.
    local function formatBalance(value)
        if type(value) ~= "number" then return "—" end
        local reversed = string.reverse(("%.0f"):format(value))
        return string.reverse((reversed:gsub("(%d%d%d)", "%1."):gsub("%.$", "")))
    end

    -- Tách tên tiền và số dư để mỗi dòng tự co chữ trên mobile.
    local function balanceRow(parent, name, y)
        local heading = label(parent, UDim2.fromScale(0.08, y), UDim2.fromScale(0.84, 0.045), Enum.TextXAlignment.Center, 16)
        heading.Text = name
        local value = label(parent, UDim2.fromScale(0.08, y + 0.045), UDim2.fromScale(0.84, 0.08), Enum.TextXAlignment.Center, 24)
        value.Text = "—"
        for _, object in ipairs({ heading, value }) do
            object.TextWrapped = false
            object.TextScaled = true
            local constraint = Instance.new("UITextSizeConstraint")
            constraint.MinTextSize = 1
            constraint.MaxTextSize = object.TextSize
            constraint.Parent = object
        end
        return value
    end

    -- Hiện thời gian chạy script theo giờ, phút và giây.
    local function uptimeText()
        local seconds = math.floor(os.clock() - scriptStartedAt)
        return ("Thời gian hoạt động · %02d:%02d:%02d"):format(
            math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
    end

    -- Xóa overlay để chạy phần phục hồi hiển thị.
    local function stop()
        if activeGui then activeGui:Destroy() end
    end

    -- Dựng overlay và cập nhật dữ liệu theo thời gian.
    local function start()
        if activeGui then return end
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
        if not playerGui then return end
        local gui = Instance.new("ScreenGui")
        gui.Name = "PumpkinTycoonStats"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 1000
        gui.ClipToDeviceSafeArea = false
        gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
        local cover = Instance.new("Frame")
        cover.BackgroundColor3 = Color3.new(0, 0, 0)
        cover.BorderSizePixel = 0
        cover.Position = UDim2.fromOffset(-256, -256)
        cover.Size = UDim2.new(1, 512, 1, 512)
        cover.Parent = gui
        local content = Instance.new("Frame")
        content.Size = UDim2.fromScale(1, 1)
        content.BackgroundTransparency = 1
        content.Parent = gui

        local close = Instance.new("TextButton")
        close.Position = UDim2.fromOffset(12, 12)
        close.Size = UDim2.fromOffset(70, 40)
        close.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
        close.TextColor3 = Color3.new(1, 1, 1)
        close.Font = Enum.Font.GothamBold
        close.TextSize = 14
        close.Text = "Tắt Stats"
        close.Parent = content
        close.Activated:Connect(function()
            stop()
            if onQuickClose then onQuickClose() end
        end)

        local zones = label(content, UDim2.fromScale(0.03, 0.48), UDim2.fromScale(0.43, 0.49), Enum.TextXAlignment.Left, 14)
        zones.TextYAlignment = Enum.TextYAlignment.Bottom
        zones.TextScaled = true
        local zoneTextSize = Instance.new("UITextSizeConstraint")
        zoneTextSize.MinTextSize = 1
        zoneTextSize.MaxTextSize = 14
        zoneTextSize.Parent = zones
        local diamonds = balanceRow(content, "Diamonds", 0.30)
        local coins = balanceRow(content, "Pumpkin Coins", 0.44)
        local uptime = label(content, UDim2.new(0.03, 0, 0, 58), UDim2.new(0.43, 0, 0, 40), Enum.TextXAlignment.Left, 14)
        uptime.Text = uptimeText()
        local stock = label(content, UDim2.fromScale(0.49, 0.03), UDim2.fromScale(0.48, 0.26), Enum.TextXAlignment.Right, 14)
        stock.TextYAlignment = Enum.TextYAlignment.Top
        local title = label(content, UDim2.fromScale(0.49, 0.59), UDim2.fromScale(0.48, 0.045), Enum.TextXAlignment.Right, 14)
        title.Text, title.TextColor3 = "PET TRONG KHO", accent

        local list = Instance.new("ScrollingFrame")
        list.Position = UDim2.fromScale(0.49, 0.64)
        list.Size = UDim2.fromScale(0.48, 0.33)
        list.BackgroundTransparency = 1
        list.BorderSizePixel = 0
        list.ScrollBarThickness = 3
        list.CanvasSize = UDim2.new()
        list.AutomaticCanvasSize = Enum.AutomaticSize.Y
        list.Parent = content
        Instance.new("UIListLayout", list).SortOrder = Enum.SortOrder.LayoutOrder

        local previousRows
        local nextPetsAt = 0
        local function refresh()
            uptime.Text = uptimeText()
            diamonds.Text = formatBalance(currency.Get("Diamonds"))
            coins.Text = formatBalance(currency.Get(tycoonTypes.COIN))
            local data = save.Get()
            if not data then return end
            zones.Text, stock.Text = eventBoostText() .. "\n\n" .. zoneText(data), stockText()
            if os.clock() < nextPetsAt then return end
            nextPetsAt = os.clock() + 5
            local rows = petRows(data.Inventory and data.Inventory.Pet)
            local keys = {}
            for _, row in ipairs(rows) do
                table.insert(keys, table.concat({ row.kind, row.name, row.icon or "", row.amount }, "|"))
            end
            local signature = table.concat(keys, "\n")
            if signature == previousRows then return end
            previousRows = signature
            for _, child in ipairs(list:GetChildren()) do
                if child:IsA("Frame") then child:Destroy() end
            end
            for index, row in ipairs(rows) do
                local card = Instance.new("Frame")
                card.Size = UDim2.new(1, -6, 0, 44)
                card.BackgroundTransparency = 1
                card.LayoutOrder = index
                local icon = Instance.new("ImageLabel")
                icon.AnchorPoint = Vector2.new(1, 0)
                icon.Position = UDim2.fromScale(1, 0)
                icon.Size = UDim2.fromOffset(42, 42)
                icon.BackgroundTransparency = 1
                icon.Image = row.icon or ""
                icon.Parent = card
                local caption = label(card, UDim2.new(), UDim2.new(1, -46, 1, 0), Enum.TextXAlignment.Right, 12)
                caption.Text = ("%s\n%s%s"):format(row.kind, row.name, row.amount > 1 and (" ×" .. row.amount) or "")
                card.Parent = list
            end
        end

        activeGui = gui
        local rendered = pcall(function() runService:Set3dRenderingEnabled(false) end)
        if not rendered then features.EventOptimize.request(gui, true) end
        gui.Destroying:Connect(function()
            activeGui = nil
            if rendered then
                pcall(function() runService:Set3dRenderingEnabled(true) end)
            else
                features.EventOptimize.request(gui, false)
            end
        end)
        gui.Parent = playerGui
        task.defer(function()
            while activeGui == gui do
                local ok, err = pcall(refresh)
                if not ok then warn("[Stats Event] " .. tostring(err)) end
                task.wait(ok and 1 or 5)
            end
        end)
    end

    features.EventStatsGui = {
        setQuickClose = function(callback) onQuickClose = callback end,
        duy = function(on)
            if on then start() else stop() end
        end,
    }
end

return features
