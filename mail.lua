-- Trading / Quét giá booth, mua theo danh sách và báo Discord.
local features = {}
local library = game:GetService("ReplicatedStorage").Library
local client = library.Client
local player = game:GetService("Players").LocalPlayer
local teleport = game:GetService("TeleportService")
local http = game:GetService("HttpService")
local network = require(client.Network)
local currency = require(client.CurrencyCmds)
local signal = require(library.Signal)
local items = require(library.Items)
local petTypes = require(library.Items.PetItem).Types
local normalPlace = require(library.Modules.PlaceFile).LocalPlaces.Trading
local launcherUrl = "https://raw.githubusercontent.com/duyvip453/dyu/refs/heads/main/UI.lua"
local saleIcon = "https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRGqBzt8-gWyK4EjXzygBwxYJE9zJZGbTviQfXU6-Ui5A&s"
local diamondIcon = "https://tr.rbxcdn.com/180DAY-9b4d094e1819c1b5ea67575b824a9101/150/150/Image/Png/noFilter"

local environment = type(getgenv) == "function" and getgenv() or _G
local runToken = {}
environment.RobloxHubTradingRun = runToken
local rules, visited, pending = {}, {}, {}
local sniperEnabled, webhookEnabled, hopEnabled = false, false, true
local webhookUrl, minDiamond = "", 0
local belowMinimum, delivery, job
local nextTravelAt, searchIndex = 0, 0
local nextSearchAt, pendingHop
local idleBeforeSearch = 5
local rejectedServers = {}
local lastNotice
local suffixes = { [""] = 1, k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
local variants = {
    normal = { petTypes.Normal, false, "Normal" },
    golden = { petTypes.Golden, false, "Golden" },
    rainbow = { petTypes.Rainbow, false, "Rainbow" },
    shiny = { petTypes.Normal, true, "Shiny" },
    shinygolden = { petTypes.Golden, true, "Shiny Golden" },
    shinyrainbow = { petTypes.Rainbow, true, "Shiny Rainbow" },
}

-- Chuẩn hóa chuỗi do launcher hoặc item cung cấp.
local function clean(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

-- Đọc số kim cương nguyên hoặc giá có hậu tố k, m, b và t.
local function parseDiamonds(value)
    if type(value) == "string" then
        local number, suffix = value:lower():gsub(",", ""):match("^%s*(%d+%.?%d*)%s*([kmbt]?)%s*$")
        value = number and tonumber(number) * suffixes[suffix]
    end
    if type(value) == "number" and value >= 0 and value < 2^53 and value % 1 == 0 then return value end
end

-- In cùng một lỗi một lần cho mỗi trạng thái liên tiếp.
local function notice(reason)
    if lastNotice == reason then return end
    lastNotice = reason
    warn("[Trading] " .. reason)
end

-- Hiển thị số kim cương đầy đủ theo nhóm ba chữ số.
local function formatDiamonds(value)
    return (("%.0f"):format(value):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Định dạng thời điểm theo múi giờ Việt Nam.
local function timeInVietnam()
    return os.date("!%H:%M:%S %d/%m/%Y", os.time() + 7 * 3600) .. " (UTC+7)"
end

-- Gửi một embed qua luồng HTTP của webhook hiện có.
local function emit(embed)
    if not webhookEnabled or webhookUrl == "" or not delivery then return end
    local url = webhookUrl
    task.defer(function()
        local ok, reason = delivery.post(url, function()
            return { embeds = { embed }, allowed_mentions = { parse = {} }, attachments = {} }
        end)
        if not ok then warn("[Webhook Trading] " .. reason) end
    end)
end

-- Chỉ ghi nhận giao dịch sau khi server báo mua thành công.
local function reportPurchase(name, quantity, price)
    local priceText = formatDiamonds(price) .. " 💎/món"
    if quantity > 1 then priceText ..= " · Tổng " .. formatDiamonds(quantity * price) .. " 💎" end
    emit({
        title = "Sale!",
        description = ("**you just bought:**\n%s\nx%d\n**price:**\n%s\n\n**time: %s**"):format(
            name, quantity, priceText, timeInVietnam()),
        color = 15595273,
        thumbnail = { url = saleIcon },
    })
end

-- Chỉ báo hết tiền khi số dư đi từ trên ngưỡng xuống dưới ngưỡng.
local function checkBalance(balance)
    if not webhookEnabled or type(balance) ~= "number" then return end
    local below = balance < minDiamond
    if below and belowMinimum == false then
        emit({
            title = "out of diamond !",
            description = ("hết tiền 🤣\n**time: %s**"):format(timeInVietnam()),
            color = 393185,
            thumbnail = { url = diamondIcon },
        })
    end
    belowMinimum = below
end

-- Giữ danh sách server vừa quét ở kích thước cố định.
local function rememberServer(id)
    if type(id) ~= "string" or id == "" or table.find(visited, id) then return end
    table.insert(visited, id)
    if #visited > 12 then table.remove(visited, 1) end
end

-- Chuyển cấu hình Trading sang lần chạy tiếp theo qua executor.
local function queueResume(targetJobId)
    local queue = queue_on_teleport or queue_on_tp or queueonteleport
    if type(queue) ~= "function" then
        notice("Executor thiếu queue_on_teleport. Cần chạy launcher lại ở server mới.")
        return false
    end
    local config = {
        toggles = { TradingSniperBooth = sniperEnabled, TradingWebhook = webhookEnabled },
        trading = { items = rules, webhookUrl = webhookUrl, minDiamond = minDiamond, hop = hopEnabled,
            visited = visited, searchIndex = searchIndex },
    }
    local source = ([=[
local env = type(getgenv) == "function" and getgenv() or _G
if not game:IsLoaded() then game.Loaded:Wait() end
local expectedJob = %q
if game.PlaceId ~= %d or (expectedJob ~= "" and game.JobId ~= expectedJob) then return end
if env.RobloxHubTradingResumedJob == game.JobId then return end
env.RobloxHubTradingResumedJob = game.JobId
env.RobloxHubConfig = game:GetService("HttpService"):JSONDecode(%q)
assert(loadstring(game:HttpGet(%q)))()
]=]):format(targetJobId or "", normalPlace, http:JSONEncode(config), launcherUrl)
    local ok = pcall(queue, source)
    if not ok then notice("Executor không thể nạp lại launcher sau teleport.") end
    return ok
end

-- Dùng đúng đường vào Trading Plaza Normal của game.
local function enterNormal()
    if os.clock() < nextTravelAt then return end
    nextTravelAt = os.clock() + 30
    queueResume()
    local ok, reason = network.Invoke("Travel to Trading Plaza", normalPlace)
    if not ok then notice(tostring(reason or "Game từ chối vào Trading Plaza Normal.")) end
end

-- Đọc bảng booth đã tải trong client thay vì quét giao diện.
local function getBooths()
    if not signal.Invoke("Booths_IsLoaded") then return nil end
    local getCallback = getcallbackvalue or getcallbackmember
    if type(getCallback) ~= "function" then
        notice("Executor không hỗ trợ đọc dữ liệu booth.")
        return nil
    end
    local callback = getCallback(signal.Invoked("Booths_GetIdWithStackKey"), "OnInvoke")
    if type(callback) ~= "function" then return nil end
    local cache, value = debug.getupvalue(callback, 1)
    if type(value) == "table" then cache = value end
    if type(cache) == "table" then return cache end
    notice("Chưa đọc được bảng listing của Trading Plaza.")
end

-- Khớp tên nội bộ hoặc tên hiển thị và biến thể pet đã chọn.
local function matches(rule, item)
    if item.Class.Name ~= rule.class then return false end
    local variant = rule.variant and variants[rule.variant]
    if variant and (item:GetType() ~= variant[1] or item:IsShiny() ~= variant[2]) then return false end
    local needle = rule.name:lower()
    return item:GetId():lower() == needle or item:GetName():lower() == needle
end

-- Tính số lượng mua được theo giá từng món và ví hiện tại.
local function quantityFor(row, rule, balance, now)
    if not row or not row.Item or type(row.ReadyTimestamp) ~= "number" or row.ReadyTimestamp > now then return 0 end
    local price = row.DiamondCost
    if type(price) ~= "number" or price <= 0 or price > rule.minAmount then return 0 end
    return math.min(row.Item:GetAmount(), math.floor(balance / price))
end

-- Ưu tiên quy tắc đầu tiên có hàng và giá thấp nhất trong quy tắc đó.
local function findListing(booths, balance)
    local now = workspace:GetServerTimeNow()
    local best
    for owner, booth in pairs(booths) do
        if owner == player or type(booth.Listings) ~= "table" then continue end
        for id, row in pairs(booth.Listings) do
            if not row.Item then continue end
            local key = tostring(booth.PlayerID or owner.UserId) .. ":" .. tostring(id)
            local held = pending[key]
            local eligible = not held or (held.amount and row.Item:GetAmount() < held.amount) or held.untilAt <= now
            for priority, rule in ipairs(rules) do
                if not matches(rule, row.Item) then continue end
                if not rule.stackKey then rule.stackKey = row.Item:StackKey() end
                if eligible and quantityFor(row, rule, balance, now) > 0
                    and (not best or priority < best.priority
                        or (priority == best.priority and row.DiamondCost < best.price)) then
                    best = { owner = owner, boothId = booth.BoothID, id = id, key = key,
                        priority = priority, price = row.DiamondCost, rule = rule }
                end
            end
        end
    end
    for key, held in pairs(pending) do
        if held.untilAt <= now then pending[key] = nil end
    end
    return best
end

-- Đứng cạnh booth theo cùng điểm đến mà Trading Terminal dùng.
local function approachBooth(boothId)
    local model = signal.Invoke("Booths_GetPlaceholderModelFromID", tostring(boothId))
    local character = player.Character
    local root = character and character.PrimaryPart
    if not model or not root then return end
    local pivot = model:GetPivot()
    if (root.Position - pivot.Position).Magnitude <= 16 then return end
    local target = pivot * CFrame.new(0, 0, -8)
    character:PivotTo(target)
    task.wait(0.3)
end

-- Xác nhận lại listing và số dư ngay trước khi gửi lệnh mua.
local function buyListing(booths, candidate)
    local scanner = require(library.Modules.LuaScanner)
    approachBooth(candidate.boothId)
    if not sniperEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    local booth = booths[candidate.owner]
    local row = booth and booth.Listings[candidate.id]
    if not row or not row.Item or not matches(candidate.rule, row.Item) then return end
    local balance = currency.Get("Diamonds")
    if type(balance) ~= "number" then return end
    local now = workspace:GetServerTimeNow()
    local quantity = quantityFor(row, candidate.rule, balance, now)
    if quantity < 1 then return end
    local price, name, amount = row.DiamondCost, row.Item:GetName(), row.Item:GetAmount()
    pending[candidate.key] = { untilAt = now + 4 }
    local accepted, reason = network.Invoke("Booths_RequestPurchase", booth.PlayerID or candidate.owner.UserId,
        { [candidate.id] = quantity }, scanner.Create(-1))
    if accepted then
        pending[candidate.key] = { amount = amount, untilAt = workspace:GetServerTimeNow() + 12 }
        lastNotice = nil
        reportPurchase(name, quantity, price)
    else
        notice(tostring(reason or "Game từ chối mua listing."))
    end
end

-- Dựng StackKey từ loại vật phẩm đã chọn khi booth hiện tại chưa có món đó.
local function terminalKey(rule)
    if rule.stackKey then return rule.stackKey end
    local data = { id = rule.name }
    local variant = rule.variant and variants[rule.variant]
    if variant then
        data.pt = variant[1] ~= petTypes.Normal and variant[1] or nil
        data.sh = variant[2] or nil
    end
    local ok, key = pcall(function() return items.From(rule.class, data):StackKey() end)
    if ok then rule.stackKey = key end
    return rule.stackKey
end

-- Gỡ listener ngay khi lần chuyển server kết thúc hoặc bị hủy.
local function clearPendingHop()
    if not pendingHop then return end
    pendingHop.connection:Disconnect()
    pendingHop = nil
end

-- Chuyển sang món kế tiếp khi Roblox từ chối server đích.
local function failHop(reason)
    rejectedServers[pendingHop.jobId] = os.clock() + 30
    clearPendingHop()
    nextSearchAt = os.clock() + 1
    notice("Chuyển server thất bại: " .. tostring(reason))
end

-- Dùng Terminal sau khi đủ 5 giây không có listing phù hợp.
local function searchNextServer()
    if not hopEnabled or not nextSearchAt or os.clock() < nextSearchAt then return end
    if type(queue_on_teleport or queue_on_tp or queueonteleport) ~= "function" then return end
    local now = os.clock()
    for id, expiresAt in pairs(rejectedServers) do
        if expiresAt <= now then rejectedServers[id] = nil end
    end
    searchIndex = searchIndex % #rules + 1
    local retryDelay = searchIndex == #rules and idleBeforeSearch or 1
    nextSearchAt = now + retryDelay
    local rule = rules[searchIndex]
    local key = terminalKey(rule)
    if not key then return end
    local okVoice, voice = pcall(function()
        return game:GetService("VoiceChatService"):IsVoiceEnabledForUserIdAsync(player.UserId)
    end)
    if not sniperEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    local ok, result, reason = pcall(network.Invoke, "TradingTerminal_Search", rule.class, key, nil, okVoice and voice == true)
    if not sniperEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    nextSearchAt = os.clock() + retryDelay
    if not ok or type(result) ~= "table" then
        local message = tostring((ok and reason or result) or "không tìm thấy listing")
        local cooldown = tonumber(message:lower():match("wait (%d+) seconds?"))
        if cooldown then nextSearchAt = os.clock() + math.max(cooldown, retryDelay) end
        if not ok then notice(("Terminal · %s · %s"):format(rule.name, message)) end
        return
    end
    if result.place_id ~= normalPlace or type(result.job_id) ~= "string" or result.job_id == ""
        or result.job_id == game.JobId or table.find(visited, result.job_id)
        or (rejectedServers[result.job_id] or 0) > os.clock() then return end

    -- Kiểm tra lại server hiện tại sau thời gian chờ phản hồi Terminal.
    local balance = currency.Get("Diamonds")
    local booths = getBooths()
    if not booths or type(balance) ~= "number" or balance <= 0 or findListing(booths, balance) then
        nextSearchAt = nil
        return
    end
    rememberServer(game.JobId)
    if not queueResume(result.job_id) then return end

    -- Chờ lỗi teleport bất đồng bộ như server đầy trước khi thử món khác.
    local attempt = { jobId = result.job_id, deadline = os.clock() + 25 }
    attempt.connection = teleport.TeleportInitFailed:Connect(function(who, outcome, message, placeId, options)
        if pendingHop ~= attempt or who ~= player or placeId ~= normalPlace then return end
        local failedJob = options and options.ServerInstanceId
        if failedJob and failedJob ~= "" and failedJob ~= result.job_id then return end
        failHop(message ~= "" and message or outcome)
    end)
    pendingHop = attempt
    -- Sniper tự đọc lại booth sau khi đến server tìm được.
    local sent, failure = pcall(teleport.TeleportToPlaceInstance, teleport, normalPlace, result.job_id, player)
    if not sent and pendingHop == attempt then failHop(failure) end
end

-- Chỉ quét và mua ở Plaza Normal.
local function tick()
    local balance = currency.Get("Diamonds")
    checkBalance(balance)
    if not sniperEnabled then return end
    if pendingHop then
        if os.clock() >= pendingHop.deadline then failHop("hết thời gian chờ Roblox phản hồi") end
        return
    end
    if game.PlaceId ~= normalPlace then
        enterNormal()
    elseif #rules > 0 and type(balance) == "number" and balance > 0 then
        local booths = getBooths()
        if not booths then
            nextSearchAt = nil
            return
        end
        local candidate = findListing(booths, balance)
        if candidate then
            nextSearchAt = nil
            buyListing(booths, candidate)
        else
            nextSearchAt = nextSearchAt or os.clock() + idleBeforeSearch
            searchNextServer()
        end
    else
        nextSearchAt = nil
    end
end

-- Dùng chung một worker cho hai toggle trong Trading.
local function start(shared)
    delivery = shared and shared.WebhookDelivery or delivery
    if job or not (sniperEnabled or webhookEnabled) then return end
    job = task.defer(function()
        while environment.RobloxHubTradingRun == runToken and (sniperEnabled or webhookEnabled) do
            local ok, reason = pcall(tick)
            if not ok then notice(tostring(reason)) end
            task.wait(ok and 1 or 5)
        end
        clearPendingHop()
        job = nil
    end)
end

-- Chuẩn hóa quy tắc săn từ cấu hình launcher.
local function configure(config)
    config = type(config) == "table" and config or {}
    webhookUrl = clean(config.webhookUrl)
    minDiamond = parseDiamonds(config.minDiamond) or 0
    hopEnabled = config.hop ~= false
    searchIndex = type(config.searchIndex) == "number" and math.max(0, math.floor(config.searchIndex)) or 0
    for _, id in ipairs(type(config.visited) == "table" and config.visited or {}) do rememberServer(id) end
    table.clear(rules)
    local descriptions = {}
    for index, entry in ipairs(type(config.items) == "table" and config.items or {}) do
        if type(entry) ~= "table" then continue end
        local class, name = clean(entry.class), clean(entry.name)
        local price = parseDiamonds(entry.minAmount or entry.maxUnitPrice)
        local variant = clean(entry.variant or entry.varities):lower():gsub("[^%a]", ""):gsub("gold$", "golden")
        if variant == "goldenshiny" or variant == "goldshiny" then variant = "shinygolden" end
        if variant == "rainbowshiny" then variant = "shinyrainbow" end
        if class == "" or name == "" or not price or price < 1 or (class == "Pet" and not variants[variant]) then
            descriptions[#descriptions + 1] = ("Dòng %d thiếu Class, tên, giá hoặc biến thể pet."):format(index)
            continue
        end
        variant = class == "Pet" and variant or nil
        rules[#rules + 1] = { class = class, name = name, minAmount = price, variant = variant }
        descriptions[#descriptions + 1] = ("%s · %s%s · ≤ %s 💎/món"):format(class, name,
            variant and (" · " .. variants[variant][3]) or "", formatDiamonds(price))
    end
    return #descriptions > 0 and table.concat(descriptions, "\n") or "Danh sách săn chưa có món."
end

features.TradingSniperBooth = {
    configure = configure,
    duy = function(on, shared)
        if on and not sniperEnabled then
            nextSearchAt = nil
            nextTravelAt = 0
        end
        sniperEnabled = on
        if not on then clearPendingHop() end
        start(shared)
    end,
}

features.TradingWebhook = {
    setUrl = function(value) webhookUrl = clean(value) end,
    setMinimum = function(value)
        local minimum = parseDiamonds(value)
        if minimum == nil then return end
        minDiamond = minimum
        belowMinimum = nil
    end,
    duy = function(on, shared)
        if on and not webhookEnabled then belowMinimum = nil end
        webhookEnabled = on
        start(shared)
    end,
}

return features
