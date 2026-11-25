-- Trading / Quét giá booth, mua theo danh sách và báo Discord.
local features = {}
local library = game:GetService("ReplicatedStorage").Library
local client = library.Client
local player = game:GetService("Players").LocalPlayer
local teleport = game:GetService("TeleportService")
local http = game:GetService("HttpService")
local network = require(client.Network)
local currency = require(client.CurrencyCmds)
local inventory = require(client.InventoryCmds)
local save = require(client.Save)
local flags = require(client.FFlags)
local signal = require(library.Signal)
local items = require(library.Items)
local itemTypes = require(library.Items.Types)
local petTypes = require(library.Items.PetItem).Types
local plazaPlaces = require(library.Modules.PlaceFile).LocalPlaces
local normalPlace = plazaPlaces.Trading
local launcherUrl = "https://raw.githubusercontent.com/duyvip342/dyu/refs/heads/main/UI.lua"
local diamondIcon = "https://tr.rbxcdn.com/180DAY-9b4d094e1819c1b5ea67575b824a9101/150/150/Image/Png/noFilter"

local environment = type(getgenv) == "function" and getgenv() or _G
local runToken = {}
environment.RobloxHubTradingRun = runToken
local rules, visited, pending = {}, {}, {}
local sniperEnabled, webhookEnabled, hopEnabled = false, false, true
local searchCatalogs, searchOffsets = {}, {}
local sellEnabled = false
local autoTradeEnabled = false
local configureAutoTrade
local sellRules, pendingSales = {}, {}
local nextSellAt = 0
local nextClaimAt, sellerBoothId = 0, nil
local restorePending = false
local sellerPhase, restoreWaitUntil = "waiting", 0
local restoreRequestedAt
local resetListingId
local originalMessageNew, autoRestoreMessage
local message = require(client.Message)

-- Tự chọn Yes cho câu hỏi khôi phục booth khi Auto Sell đang bật.
local function enableRestorePrompt()
    if autoRestoreMessage then return end
    local previous = message.New
    local function answer(text, ...)
        if text == "Would you like to restore your booth listings?"
            and sellEnabled and environment.RobloxHubTradingRun == runToken then
            sellerPhase = "restore"
            restoreRequestedAt = os.clock()
            return true
        end
        return previous(text, ...)
    end
    originalMessageNew, autoRestoreMessage = previous, answer
    message.New = answer
end

-- Gỡ bộ trả lời của Auto Sell khi tắt toggle.
local function disableRestorePrompt()
    if autoRestoreMessage and message.New == autoRestoreMessage then message.New = originalMessageNew end
    originalMessageNew, autoRestoreMessage = nil, nil
end
local webhookUrl, minDiamond = "", 0
local belowMinimum, delivery, job
local lastWebhookError
local saleConnection
local nextTravelAt, searchIndex = 0, 0
local nextSearchAt, pendingHop
local idleBeforeSearch = 5
local rejectedServers = {}
local lastNotice
local tradingStatus, statusCallback = "Chưa bật Sniper Booth.", nil
local function setStatus(message)
    tradingStatus = message
    if statusCallback then pcall(statusCallback, message) end
end
local suffixes = { [""] = 1, k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
local variants = {
    normal = { petTypes.Normal, false, "Normal" },
    golden = { petTypes.Golden, false, "Golden" },
    rainbow = { petTypes.Rainbow, false, "Rainbow" },
    shiny = { petTypes.Normal, true, "Shiny" },
    shinygolden = { petTypes.Golden, true, "Shiny Golden" },
    shinyrainbow = { petTypes.Rainbow, true, "Shiny Rainbow" },
}
local romanParts = {
    { "M", 1000 }, { "CM", 900 }, { "D", 500 }, { "CD", 400 },
    { "C", 100 }, { "XC", 90 }, { "L", 50 }, { "XL", 40 },
    { "X", 10 }, { "IX", 9 }, { "V", 5 }, { "IV", 4 }, { "I", 1 },
}

-- Chuẩn hóa chuỗi do launcher hoặc item cung cấp.
local function clean(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

-- Đọc hậu tố La Mã hợp lệ trong tên vật phẩm.
local function romanTier(roman)
    if not roman then return nil end
    local value, position = 0, 1
    for _, part in ipairs(romanParts) do
        local symbol, amount = part[1], part[2]
        while roman:sub(position, position + #symbol - 1) == symbol do
            position += #symbol
            value += amount
        end
    end
    if position <= #roman or value < 1 or value > 3999 then return nil end
    local canonical, remaining = {}, value
    for _, part in ipairs(romanParts) do
        canonical[#canonical + 1] = part[1]:rep(remaining // part[2])
        remaining %= part[2]
    end
    if table.concat(canonical) == roman then return value end
end

-- Tách cấp viết bằng số La Mã hoặc cú pháp [Cấp N].
local function itemTier(name)
    local itemId, tier = name:match("^(.-)%s+%[Cấp (%d+)%]$")
    if tier then return itemId, tonumber(tier) end
    local base, suffix = name:match("^(.-)%s+([IVXLCDM]+)$")
    tier = romanTier(suffix)
    if tier then return base, tier, true end
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
    setStatus(reason)
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

-- Báo cấu hình webhook bị thiếu ngay khi bật hoặc chuẩn bị gửi.
local function webhookReady()
    local reason
    if webhookUrl == "" then
        reason = "Hãy điền Trading Webhook URL."
    elseif type(delivery) ~= "table" or type(delivery.post) ~= "function" then
        reason = "Thiếu hàm gửi Discord. Hãy cập nhật webhook.lua cùng phiên bản với trading.lua."
    end
    if reason and lastWebhookError ~= reason then warn("[Webhook Trading] " .. reason) end
    lastWebhookError = reason
    return reason == nil
end

-- Gửi một embed qua luồng HTTP của webhook hiện có.
local function emit(buildEmbed)
    if not webhookEnabled or not webhookReady() then return end
    local url = webhookUrl
    local post = delivery.post
    task.defer(function()
        local built, result = pcall(buildEmbed)
        if not built then
            warn("[Webhook Trading] Không dựng được nội dung thông báo.")
            return
        end
        local embeds = result.title and { result } or result
        local batch, characters = {}, 0
        local function sendBatch()
            local payload = { embeds = batch, allowed_mentions = { parse = {} }, attachments = {} }
            local ran, ok, reason = pcall(post, url, function() return payload end)
            if not ran then
                warn("[Webhook Trading] Không gọi được hàm gửi Discord.")
            elseif not ok then
                warn("[Webhook Trading] " .. tostring(reason or "Discord chưa nhận thông báo."))
            end
            return ran and ok
        end
        for _, embed in ipairs(embeds) do
            local size = #(embed.title or "") + #(embed.description or "")
            if #batch >= 10 or characters + size > 5500 then
                if not sendBatch() then return end
                batch, characters = {}, 0
            end
            batch[#batch + 1] = embed
            characters += size
        end
        if #batch > 0 then sendBatch() end
    end)
end

-- Đếm theo nhóm stack của game để giữ đúng cấp và biến thể.
local function inventoryAmount(item)
    local ok, amount = pcall(function()
        if inventory.Container() then return item:CountAny() end
    end)
    if ok and type(amount) == "number" then return amount end
end

-- Chờ kho đồng bộ lượt mua trên luồng gửi webhook.
local function purchaseInventoryText(item, before, quantity)
    local deadline = os.clock() + 2
    local latest
    repeat
        local amount = inventoryAmount(item)
        if amount ~= nil then
            latest = amount
            if before ~= nil and amount >= before + quantity then return formatDiamonds(amount) end
        end
        task.wait(0.15)
    until os.clock() >= deadline
    if latest == nil then return "Chưa đọc được kho" end
    if before == nil then return formatDiamonds(latest) end
    return formatDiamonds(latest) .. " (đang đồng bộ)"
end

-- Chỉ ghi nhận giao dịch sau khi server báo mua thành công.
local function reportPurchase(item, name, quantity, price, before)
    local priceText = formatDiamonds(price) .. " 💎/món"
    if quantity > 1 then priceText ..= " · Tổng " .. formatDiamonds(quantity * price) .. " 💎" end
    local boughtAt = timeInVietnam()
    emit(function()
        local embed = {
            title = "Sale!",
            description = ("**you just bought:**\n%s\nx%d\n**price:**\n%s\n**Trong kho:** %s\n\n**time: %s**"):format(
                name, quantity, priceText, purchaseInventoryText(item, before, quantity), boughtAt),
            color = 15595273,
        }
        -- Lấy icon của đúng món đã mua cho thumbnail Discord.
        if type(delivery.thumbnail) == "function" then
            local ok, image = pcall(function() return delivery.thumbnail(item:GetIcon()) end)
            if ok and type(image) == "string" then embed.thumbnail = { url = image } end
        end
        return embed
    end)
end

-- Chỉ báo hết tiền khi số dư đi từ trên ngưỡng xuống dưới ngưỡng.
local function checkBalance(balance)
    if not webhookEnabled or type(balance) ~= "number" then return end
    local below = balance < minDiamond
    if below and belowMinimum == false then
        emit(function()
            return {
                title = "out of diamond !",
                description = ("hết tiền 🤣\n**time: %s**"):format(timeInVietnam()),
                color = 393185,
                thumbnail = { url = diamondIcon },
            }
        end)
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
local function teleportQueue()
    -- Không dùng chuỗi `or`: một alias không phải hàm có thể che alias hợp lệ.
    for _, scope in ipairs({ environment, _G }) do
        for _, name in ipairs({ "queue_on_teleport", "queue_on_tp", "queueonteleport", "queueontp" }) do
            if type(scope[name]) == "function" then return scope[name] end
        end
        for _, name in ipairs({ "syn", "fluxus" }) do
            local api = scope[name]
            if type(api) == "table" and type(api.queue_on_teleport) == "function" then
                return api.queue_on_teleport
            end
        end
    end
    -- Một số executor tách globals của script khỏi getgenv().
    if type(queue_on_teleport) == "function" then return queue_on_teleport end
    if type(queue_on_tp) == "function" then return queue_on_tp end
    if type(queueonteleport) == "function" then return queueonteleport end
    if type(queueontp) == "function" then return queueontp end
end

local function queueResume(targetJobId)
    local queue = teleportQueue()
    if type(queue) ~= "function" then
        notice("Executor thiếu queue_on_teleport. Cần chạy launcher lại ở server mới.")
        return false
    end
    local function exportRules(source)
        local output = {}
        for _, rule in ipairs(source) do
            output[#output + 1] = { class = rule.class, name = rule.name, price = rule.price,
                variant = rule.variant, minPrice = rule.minPrice }
        end
        return output
    end
    local config = {
        toggles = { TradingSniperBooth = sniperEnabled,
            TradingWebhook = webhookEnabled, TradingAutoSell = sellEnabled },
        trading = { items = exportRules(rules), webhookUrl = webhookUrl, minDiamond = minDiamond, hop = hopEnabled,
            visited = visited, searchIndex = searchIndex, sell = exportRules(sellRules), autoTrade = autoTradeEnabled },
    }
    local ui = environment.RobloxHubUI
    if type(ui) == "table" and ui.ready and type(ui.Snapshot) == "function" then
        config.controls = ui:Snapshot()
    end
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
    local ok, result = pcall(queue, source)
    if not ok or result == false then notice("Executor không thể nạp lại launcher sau teleport.") end
    return ok and result ~= false
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
    if not signal.Invoke("Booths_IsLoaded") then
        setStatus("Đang chờ game tải dữ liệu booth...")
        return nil
    end
    local getCallback = getcallbackvalue or getcallbackmember
    if type(getCallback) ~= "function" then
        notice("Executor không hỗ trợ đọc dữ liệu booth.")
        return nil
    end
    local callback = getCallback(signal.Invoked("Booths_GetIdWithStackKey"), "OnInvoke")
    if type(callback) ~= "function" then
        notice("Executor chưa đọc được callback booth; không thể quét hoặc hop.")
        return nil
    end
    local cache, value = debug.getupvalue(callback, 1)
    if type(value) == "table" then cache = value end
    if type(cache) == "table" then return cache end
    notice("Chưa đọc được bảng listing của Trading Plaza.")
end

-- Dùng chung ID nội bộ, cấp và thuộc tính cho mua, bán và tìm Terminal.
local function matches(rule, item)
    if rule.class and item.Class.Name ~= rule.class then return false end
    if rule.variant then
        if item.Class.Name ~= "Pet" then return false end
        local variant = variants[rule.variant]
        if item:GetType() ~= variant[1] or item:IsShiny() ~= variant[2] then return false end
    end
    if rule.huge then return item.Class.Name == "Pet" and item:IsHuge() end
    local id, display = item:GetId(), item:GetName()
    local baseId, idTier = itemTier(id)
    local baseDisplay, displayTier = itemTier(display)
    local needle = (rule.itemId or rule.name):lower()
    local nameMatches = id:lower() == rule.name:lower() or display:lower() == rule.name:lower()
        or (baseId or id):lower() == needle or (baseDisplay or display):lower() == needle
    if not nameMatches then return false end
    if not rule.tier then return true end
    local tier = type(item.GetTier) == "function" and item:GetTier() or item:GetData().tn
    return (tier or displayTier or idTier) == rule.tier
end

-- Price không có % là kim cương; có % là mức giảm/tăng so với RAP.
local function rulePrice(rule, item, selling)
    if not rule.percent then return parseDiamonds(rule.price) end
    local rap = item:GetRAP()
    if type(rap) ~= "number" or not (rap > 0 and rap < 2^53) then return nil end
    local value = rap * (1 + (selling and 1 or -1) * rule.percent / 100)
    value = selling and math.ceil(value) or math.floor(value)
    if value >= 1 and value < 2^53 then return value end
end

-- Lấy số slot đã dùng và số lượng đang rao theo UID trên booth của mình.
local function saleSpace(booth, now)
    local data = save.Get()
    if not booth or not data or type(data.BoothSlots) ~= "number" then return nil end
    local configured = flags.Get(flags.Keys.BoothMaxSlots)
    local limit = type(configured) == "number" and configured == configured
        and math.clamp(math.floor(configured), 4, 100) or 25
    local listed, used = {}, 0
    for _, row in pairs(booth.Listings) do
        local uid = row.Item:GetUID()
        listed[uid] = (listed[uid] or 0) + row.Item:GetAmount()
        used += 1
    end
    for uid, previous in pairs(pendingSales) do
        if previous.expires <= now or (previous.expected and (listed[uid] or 0) >= previous.expected) then
            pendingSales[uid] = nil
        elseif previous.expected then
            used += 1
        end
    end
    if used < math.min(data.BoothSlots, limit) then return listed end
end

local matchesSale = matches

-- Chỉ nhận thông báo bán của các món có trong danh sách sell.
local function isSellItem(item)
    for _, rule in ipairs(sellRules) do
        if matchesSale(rule, item) then return true end
    end
    return false
end

-- Gắn ảnh thật của item vào embed nếu Roblox trả được thumbnail.
local function itemThumbnail(embed, item)
    if delivery and type(delivery.thumbnail) == "function" then
        local ok, image = pcall(function() return delivery.thumbnail(item:GetIcon()) end)
        if ok and type(image) == "string" then embed.thumbnail = { url = image } end
    end
end

-- Tổng số đơn vị hàng khớp list sell, không khóa và có thể đăng bán.
local function sellInventoryTotal()
    local container = inventory.Container()
    if not container then return "Đang đồng bộ" end
    local total, scanned = 0, 0
    for _, class in pairs(items.Types) do
        for _, item in pairs(container:All(class)) do
            if not item:IsLocked() and item:IsTradable() then
                for _, rule in ipairs(sellRules) do
                    if matchesSale(rule, item) and rulePrice(rule, item, true) then
                        total += item:GetAmount()
                        break -- Một stack chỉ đếm một lần khi khớp nhiều quy tắc.
                    end
                end
            end
            scanned += 1
            if scanned % 64 == 0 then task.wait() end
        end
    end
    -- Hàng đang rao vẫn thuộc kho; không cộng listing thêm lần nữa.
    return formatDiamonds(total)
end

-- Đọc số kim cương thực nhận từ phía Received của lịch sử giao dịch.
local function saleRecord(record)
    if type(record) ~= "table" or type(record.Given) ~= "table" or type(record.Received) ~= "table" then return end
    local given = itemTypes.DecodeUnpacked(record.Given)
    local received = itemTypes.DecodeUnpacked(record.Received)
    local sold, amount, net = {}, 0, 0
    for _, item in ipairs(given) do
        if item.Class.Name == "Currency" then return end
        if isSellItem(item) then
            sold[#sold + 1] = item
            amount += item:GetAmount()
        end
    end
    for _, item in ipairs(received) do
        if item.Class.Name ~= "Currency" then return end
        if item:GetId() == "Diamonds" then net += item:GetAmount() end
    end
    if #sold > 0 and net > 0 then return sold, amount, net end
end

-- Báo một giao dịch đã bán kèm số dư và hàng còn lại trong list.
local function reportSale(record)
    local sold, amount, net = saleRecord(record)
    if not sold then return end
    local soldAt = timeInVietnam()
    emit(function()
        task.wait(0.5)
        local balance = currency.Get("Diamonds")
        local names = {}
        for _, item in ipairs(sold) do
            names[#names + 1] = ("%s ×%s"):format(item:GetName(), formatDiamonds(item:GetAmount()))
        end
        local embed = {
            title = "Sold!",
            description = ("**you just sold:**\n%s\n**Số lượng đã bán:** %s\n**Kim cương thực nhận:** +%s 💎\n"
                .. "**Kim cương hiện tại:** %s 💎\n**Hàng còn có thể bán:** %s\n\n**time: %s**"):format(
                    table.concat(names, "\n"), formatDiamonds(amount), formatDiamonds(net),
                    type(balance) == "number" and formatDiamonds(balance) or "Đang đồng bộ", sellInventoryTotal(), soldAt),
            color = 15595273,
        }
        itemThumbnail(embed, sold[1])
        return { embed }
    end)
end

-- Theo dõi giao dịch mới từ server và gỡ listener của lần exec cũ.
local function watchSales()
    if environment.RobloxHubTradingSaleConnection then
        environment.RobloxHubTradingSaleConnection:Disconnect()
        environment.RobloxHubTradingSaleConnection = nil
    end
    if saleConnection then saleConnection:Disconnect(); saleConnection = nil end
    if not webhookEnabled then return end
    saleConnection = network.Fired("Booths: Add History"):Connect(function(record)
        if not webhookEnabled or environment.RobloxHubTradingRun ~= runToken then return end
        local ok, reason = pcall(reportSale, record)
        if not ok then warn("[Webhook Trading] Không đọc được lịch sử bán: " .. tostring(reason)) end
    end)
    environment.RobloxHubTradingSaleConnection = saleConnection
end

-- Tính giá mỗi món và giới hạn lượng đăng theo số còn rảnh trong kho.
local function saleDetails(rule, item, listed)
    if not item or item:IsLocked() or not item:IsTradable() then return nil end
    local amount = math.min(item:GetAmount() - listed, 50_000)
    if amount < 1 then return nil end
    local price = rulePrice(rule, item, true)
    if price then return price, amount end
end

-- Tìm một stack phù hợp còn hàng và có RAP.
local function findSale(container, listed)
    for _, rule in ipairs(sellRules) do
        local function findInClass(class)
            for uid, item in pairs(container:All(class)) do
                if not pendingSales[uid] and matchesSale(rule, item) and saleDetails(rule, item, listed[uid] or 0) then
                    return uid
                end
            end
        end
        if rule.class then
            local uid = findInClass(items.Types[rule.class])
            if uid then return uid, rule end
        else
            for _, class in pairs(items.Types) do
                local uid = findInClass(class)
                if uid then return uid, rule end
            end
        end
    end
end

-- Giá trần Huge là giới hạn nghiêm ngặt trên giá rao từng món.
local function quantityFor(row, rule, balance, now)
    if not row or not row.Item or type(row.ReadyTimestamp) ~= "number" or row.ReadyTimestamp > now then return 0 end
    local price = row.DiamondCost
    if type(price) ~= "number" or not (price > 0 and price < 2^53) then return 0 end
    local limit = rulePrice(rule, row.Item, false)
    if not limit or price > limit then return 0 end
    if rule.huge and rule.minPrice and price >= rule.minPrice then return 0 end
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
            if sniperEnabled then
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

-- Đăng một listing trên booth của mình rồi chờ game cập nhật số đã rao.
local function ensureSellerBooth(booths)
    local booth = booths[player]
    if not booth then
        sellerBoothId = nil
        if os.clock() < nextClaimAt then return false end
        nextClaimAt = os.clock() + 3
        local plaza = workspace:FindFirstChild("TradingPlaza")
        local spawns = plaza and plaza:FindFirstChild("BoothSpawns")
        if not spawns or not flags.Get(flags.Keys.Booth) then return false end
        local occupied = {}
        for _, other in pairs(booths) do occupied[tostring(other.BoothID)] = true end
        for _, model in ipairs(spawns:GetChildren()) do
            local id = model:GetAttribute("ID")
            if id and not occupied[tostring(id)] then
                approachBooth(id)
                if not sellEnabled or environment.RobloxHubTradingRun ~= runToken then return false end
                if booths[player] then return false end
                local accepted, reason = network.Invoke("Booths_ClaimBooth", id)
                if accepted then
                    restorePending = true
                    if sellerPhase ~= "reset" then sellerPhase = "waiting" end
                    restoreWaitUntil = os.clock() + 5
                else notice("Nhận booth · " .. tostring(reason or "Booth không còn trống.")) end
                return false
            end
        end
        notice("Chưa có booth trống, sẽ tự thử lại.")
        return false
    end
    if sellerBoothId ~= booth.BoothID then
        approachBooth(booth.BoothID)
        if not sellEnabled or environment.RobloxHubTradingRun ~= runToken then return false end
        sellerBoothId = booth.BoothID
        restorePending = true
        restoreWaitUntil = os.clock() + 5
        require(client.TabController).OpenTab("BoothPrompt")
    end
    if sellerPhase ~= "ready" then
        local data = save.Get()
        if not data then return false end
        local recovery = flags.Get(flags.Keys.BoothRestoring)
            and type(data.BoothRecovery) == "table" and next(data.BoothRecovery) ~= nil
        if (sellerPhase == "waiting" or sellerPhase == "restore") and recovery then
            if os.clock() < (restoreRequestedAt or -10) + 5 then return false end
            sellerPhase = "restore"
            restoreRequestedAt = os.clock()
            local accepted, reason = network.Invoke("Booths_Restore")
            if not accepted then
                notice("Khôi phục booth · " .. tostring(reason or "Game chưa chấp nhận."))
                return false
            end
            sellerPhase = "restored"
            restoreWaitUntil = os.clock() + 2
            return false
        end
        if sellerPhase == "restore" and not recovery then
            sellerPhase = "restored"
            restoreWaitUntil = os.clock() + 2
        end
        if sellerPhase == "restored" then
            if os.clock() < restoreWaitUntil then return false end
            sellerPhase, restorePending = "ready", false
            table.clear(pendingSales)
            nextSellAt = os.clock() + 2
            return false
        end
        if sellerPhase == "waiting" then
            if os.clock() < restoreWaitUntil then return false end
            sellerPhase = "reset"
        end
        if sellerPhase == "reset" then
            if os.clock() < nextClaimAt then return false end
            if resetListingId and booth.Listings[resetListingId] then
                if os.clock() < nextClaimAt + 4 then return false end
            end
            local id = next(booth.Listings)
            if id then
                nextClaimAt = os.clock() + 1
                local accepted, reason = network.Invoke("Booths_RemoveListing", id)
                if accepted then resetListingId = id
                else
                    nextClaimAt = os.clock() + 5
                    notice("Gỡ listing · " .. tostring(reason or "Game chưa chấp nhận."))
                end
                return false
            end
            table.clear(pendingSales)
            sellerPhase, restorePending, resetListingId = "ready", false, nil
        end
    end
    return true
end

local function sellOne(booths)
    if #sellRules == 0 then
        notice("Auto Sell chưa có danh sách bán. Đặt món trong RobloxHubConfig.trading.sell trước khi tải UI.lua.")
        return
    end
    local now = os.clock()
    if now < nextSellAt then return end
    nextSellAt = now + 3
    if not flags.Get(flags.Keys.Booth) then return end
    local booth = booths[player]
    local listed = saleSpace(booth, now)
    local container = inventory.Container()
    if not listed or not container then return end
    local uid, rule = findSale(container, listed)
    if not uid then return end

    local boothId = booth.BoothID
    approachBooth(boothId)
    if not sellEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    booth = booths[player]
    if not booth or booth.BoothID ~= boothId then return end
    listed = saleSpace(booth, os.clock())
    local item = container:Get(uid)
    if not listed or not item or not matchesSale(rule, item) then return end
    local alreadyListed = listed[uid] or 0
    local price, amount = saleDetails(rule, item, alreadyListed)
    if not price then return end

    pendingSales[uid] = { expires = os.clock() + 10 }
    local accepted, reason = network.Invoke("Booths_CreateListing", uid, price, amount)
    if accepted then
        pendingSales[uid] = { expires = os.clock() + 12, expected = alreadyListed + amount }
        nextSellAt = os.clock() + 1
    else
        notice("Auto Sell · " .. tostring(reason or "Game từ chối đăng món."))
    end
end

-- Xác nhận lại listing và số dư ngay trước khi gửi lệnh mua.
local function buyListing(booths, candidate)
    local scanner = require(library.Modules.LuaScanner)
    approachBooth(candidate.boothId)
    if environment.RobloxHubTradingRun ~= runToken
        or not sniperEnabled then return end
    local booth = booths[candidate.owner]
    local row = booth and booth.Listings[candidate.id]
    if not row or not row.Item or not matches(candidate.rule, row.Item) then return end
    local balance = currency.Get("Diamonds")
    if type(balance) ~= "number" then return end
    local now = workspace:GetServerTimeNow()
    local quantity = quantityFor(row, candidate.rule, balance, now)
    if quantity < 1 then return end
    local item = row.Item
    local price, name, amount = row.DiamondCost, item:GetName(), item:GetAmount()
    local before = webhookEnabled and inventoryAmount(item) or nil
    pending[candidate.key] = { untilAt = now + 4 }
    local accepted, reason = network.Invoke("Booths_RequestPurchase", booth.PlayerID or candidate.owner.UserId,
        { [candidate.id] = quantity }, scanner.Create(-1))
    if accepted then
        pending[candidate.key] = { amount = amount, untilAt = workspace:GetServerTimeNow() + 12 }
        lastNotice = nil
        if webhookEnabled then reportPurchase(item, name, quantity, price, before) end
    else
        notice(tostring(reason or "Game từ chối mua listing."))
    end
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

-- Luân phiên các vật phẩm khớp danh sách trong danh mục Terminal.
local function nextSearchRule()
    if not sniperEnabled or not hopEnabled or #rules == 0 then return end
    searchIndex = searchIndex % #rules + 1
    local rule = rules[searchIndex]
    local catalog = searchCatalogs[rule.class]
    if not catalog or not next(catalog) then
        catalog = require(library.Util.TradingTerminalUtil).ByClasses({ rule.class })
        if type(catalog) ~= "table" or not next(catalog) then
            setStatus("Danh mục Terminal chưa sẵn sàng; sẽ tải lại.")
            return
        end
        searchCatalogs[rule.class] = catalog
    end
    local pool = rule.searchPool
    if not pool then
        pool = {}
        for _, item in pairs(catalog) do
            if matches(rule, item) then pool[#pool + 1] = item end
        end
        table.sort(pool, function(a, b) return a:StackKey() < b:StackKey() end)
        if #pool > 0 then rule.searchPool = pool end
    end
    if #pool == 0 then
        searchCatalogs[rule.class] = nil
        setStatus("Terminal chưa có mục khớp " .. rule.name .. "; sẽ thử món tiếp theo.")
        return
    end
    local index = (searchOffsets[searchIndex] or 0) % #pool + 1
    searchOffsets[searchIndex] = index
    return pool[index]
end

-- Sau 5 giây hết món đạt giá, tìm một món trong list bằng Trading Terminal.
local function searchNextServer()
    if not sniperEnabled or not hopEnabled or not nextSearchAt or os.clock() < nextSearchAt then return end
    nextSearchAt = os.clock() + 1
    local now = os.clock()
    for id, expiresAt in pairs(rejectedServers) do
        if expiresAt <= now then rejectedServers[id] = nil end
    end
    local item = nextSearchRule()
    if not item then return end
    -- Terminal nhận StackKey chứa ID nội bộ dù giao diện hiện tên khác.
    local class, key, name = item.Class.Name, item:StackKey(), item:GetName()
    setStatus("Terminal đang tìm: " .. name)
    local voiceOk, voice = pcall(function()
        return game:GetService("VoiceChatService"):IsVoiceEnabledForUserIdAsync(player.UserId)
    end)
    if not sniperEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    local ok, result, reason = pcall(network.Invoke, "TradingTerminal_Search", class, key, nil, voiceOk and voice == true)
    if not sniperEnabled or environment.RobloxHubTradingRun ~= runToken then return end
    nextSearchAt = os.clock() + 1
    if not ok or type(result) ~= "table" then
        local message = tostring((ok and reason or result) or "Không tìm thấy listing.")
        local cooldown = tonumber(message:lower():match("wait (%d+) seconds?"))
        if cooldown then nextSearchAt = os.clock() + math.max(cooldown, 1) end
        setStatus("Terminal · " .. name .. " · " .. message)
        return
    end
    if result.place_id ~= normalPlace or type(result.job_id) ~= "string" or result.job_id == ""
        or result.job_id == game.JobId or table.find(visited, result.job_id)
        or (rejectedServers[result.job_id] or 0) > os.clock() then
        setStatus("Terminal trả server hiện tại/đã ghé/không phù hợp; đang thử món tiếp theo.")
        return
    end
    local balance = currency.Get("Diamonds")
    local booths = getBooths()
    if not booths or type(balance) ~= "number" or balance <= 0 or findListing(booths, balance) then
        nextSearchAt = nil
        return
    end
    rememberServer(game.JobId)
    local resumed = queueResume(result.job_id)
    local attempt = { jobId = result.job_id, deadline = os.clock() + 25 }
    attempt.connection = teleport.TeleportInitFailed:Connect(function(who, outcome, message, placeId, options)
        if pendingHop ~= attempt or who ~= player or placeId ~= normalPlace then return end
        local failedJob = options and options.ServerInstanceId
        if failedJob and failedJob ~= "" and failedJob ~= result.job_id then return end
        failHop(message ~= "" and message or outcome)
    end)
    pendingHop = attempt
    setStatus("Đang chuyển tới server có " .. name .. (resumed and "" or " · cần exec lại khi đến."))
    local sent, failure = pcall(function()
        teleport:TeleportToPlaceInstance(normalPlace, result.job_id, player, nil, {
            TradingSniperTarget = { class = class, stackKey = key, boothId = result.booth },
        })
    end)
    if not sent and pendingHop == attempt then failHop(failure) end
end

-- Chỉ quét và mua ở Plaza Normal.
local function tick()
    local balance = currency.Get("Diamonds")
    checkBalance(balance)
    local buying = sniperEnabled
    if not (buying or sellEnabled) then return end
    if pendingHop then
        if os.clock() >= pendingHop.deadline then failHop("hết thời gian chờ Roblox phản hồi") end
        return
    end
    local placeId = game.PlaceId
    local selling = sellEnabled and (placeId == normalPlace or placeId == plazaPlaces.ProTrading)
    if (buying and placeId ~= normalPlace) or (sellEnabled and not selling) then
        enterNormal()
        return
    end
    buying = (sniperEnabled and #rules > 0) and type(balance) == "number" and balance > 0
    if buying or selling then
        local booths = getBooths()
        if not booths then
            nextSearchAt = nil
            return
        end
        if selling and #sellRules == 0 then
            notice("Auto Sell chưa có danh sách bán. Đặt món trong RobloxHubConfig.trading.sell trước khi tải UI.lua.")
        elseif selling then
            if not ensureSellerBooth(booths) then return end
            sellOne(booths)
        end
        local candidate = buying and findListing(booths, balance)
        if candidate then
            nextSearchAt = nil
            buyListing(booths, candidate)
        else
            if buying then
                nextSearchAt = nextSearchAt or os.clock() + idleBeforeSearch
                searchNextServer()
            end
        end
    else
        nextSearchAt = nil
    end
end

-- Dùng chung một worker cho các toggle trong Trading.
local function start(shared)
    delivery = shared and shared.WebhookDelivery or delivery
    if webhookEnabled then webhookReady() end
    if job or not (sniperEnabled or sellEnabled or webhookEnabled) then return end
    job = task.defer(function()
        while environment.RobloxHubTradingRun == runToken and (sniperEnabled or sellEnabled or webhookEnabled) do
            local ok, reason = pcall(tick)
            if not ok then notice(tostring(reason)) end
            task.wait(ok and 1 or 5)
        end
        clearPendingHop()
        job = nil
    end)
end

-- Auto Trade / Điều khiển từ trading.autoTrade trong launcher.
do
    local players = game:GetService("Players")
    local trading = require(client.TradingCmds)
    local targetName = "duyvip453"
    local controller = { enabled = false }
    local worker
    local lastError

    controller.stop = function()
        controller.enabled = false
        autoTradeEnabled = false
    end

-- Chỉ nhận đúng username Roblox của tài khoản được phép.
local function allowed(other)
    return other and other ~= player and other.Name:lower() == targetName
end

-- Phần gửi của mình phải trống trước khi Ready hoặc Confirm.
local function hasOwnItems(state, index)
    for _, group in pairs(state._items[index] or {}) do
        if next(group) then return true end
    end
    return false
end

-- Xử lý lời mời đang tồn tại qua đúng API nhận trade của game.
local function processInvitations()
    for _, other in ipairs(players:GetPlayers()) do
        if not controller.enabled then return end
        if other ~= player and trading.HasRequestFromPlayer(other) then
            if allowed(other) then
                return trading.Request(other)
            else
                trading.Reject(other)
            end
        end
    end
end

-- Theo trạng thái thật để không bấm Ready thành Unready.
local function step()
    local state = trading.GetState()
    if not state then return processInvitations() end
    if state._destroyed or state._executing then return end
    local index = state:PlayerIndex(player)
    if not index then return end
    if not allowed(state:Player2(index)) then return trading.Decline() end

    if hasOwnItems(state, index) then
        if state._ready[index] then trading.SetReady(false) end
        return false, "Phần gửi của bạn có đồ hoặc kim cương; tự động xác nhận đang chờ."
    end
    if not state._ready[index] then return trading.SetReady(true) end
    if state._readyTimer ~= nil and state:IsEveryoneReady() and not state._confirmed[index] then
        return trading.SetConfirmed(true)
    end
end

    -- Chỉ chạy một worker cho tài khoản được phép.
    configureAutoTrade = function(on)
        local previous = environment.DuyTrustedAutoTrade
        if previous ~= controller and type(previous) == "table" and type(previous.stop) == "function" then
            previous.stop()
        end
        environment.DuyTrustedAutoTrade = controller
        autoTradeEnabled = on == true
        controller.enabled = autoTradeEnabled
        if not controller.enabled or worker then return end
        worker = task.defer(function()
            while controller.enabled and environment.DuyTrustedAutoTrade == controller
                and environment.RobloxHubTradingRun == runToken do
                local ok, accepted, reason = pcall(step)
                local problem = not ok and tostring(accepted)
                    or (accepted == false and tostring(reason or "Game chưa chấp nhận thao tác."))
                if problem and problem ~= lastError then warn("[Auto Trade] " .. problem) end
                lastError = problem
                task.wait(1)
            end
            worker = nil
        end)
    end
end

-- Chuẩn hóa quy tắc săn từ cấu hình launcher.
local function configure(config)
    config = type(config) == "table" and config or {}
    configureAutoTrade(config.autoTrade == true)
    webhookUrl = clean(config.webhookUrl)
    minDiamond = parseDiamonds(config.minDiamond) or 0
    hopEnabled = config.hop ~= false
    searchIndex = type(config.searchIndex) == "number" and math.max(0, math.floor(config.searchIndex)) or 0
    for _, id in ipairs(type(config.visited) == "table" and config.visited or {}) do rememberServer(id) end
    table.clear(sellRules)
    table.clear(rules)
    table.clear(searchOffsets)
    local descriptions = {}
    local function addRule(entry, selling, index)
        if type(entry) ~= "table" then return end
        local name, class = clean(entry.name or entry.item), clean(entry.class)
        local huge = name:lower() == "huge"
        if huge and class == "" then class = "Pet" end
        local price = entry.price
        -- Tương thích launcher cũ; cấu hình mới chỉ lưu price.
        if price == nil then
            if selling and entry.rap ~= nil then price = tostring(entry.rap):gsub("%%$", "") .. "%"
            else price = entry.minAmount or entry.maxUnitPrice end
        end
        local percent = type(price) == "string" and tonumber(clean(price):match("^(%-?%d+%.?%d*)%s*%%$")) or nil
        local diamonds = not percent and parseDiamonds(price) or nil
        local variant = clean(entry.rarities or entry.variant or entry.varities):lower():gsub("[^%a]", ""):gsub("gold$", "golden")
        if variant == "goldenshiny" or variant == "goldshiny" then variant = "shinygolden" end
        if variant == "rainbowshiny" then variant = "shinyrainbow" end
        local rawCap = entry.minPrice or entry["min price"]
        local cap = rawCap ~= nil and clean(tostring(rawCap)) ~= "" and parseDiamonds(rawCap) or nil
        -- Sell nhận phần trăm giảm lớn hơn -100%; Sniper giữ mức giảm 0..dưới100%.
        local validPrice = percent and (selling and percent > -100 or not selling and percent >= 0)
            and percent < (selling and 2^53 or 100)
            or diamonds and diamonds >= 1
        if name == "" or not validPrice or (class ~= "" and not items.Types[class])
            or (not selling and class == "") or (huge and class ~= "Pet")
            or (variant ~= "" and (not variants[variant] or (class ~= "" and class ~= "Pet")))
            or (rawCap ~= nil and clean(tostring(rawCap)) ~= "" and (not cap or cap < 1)) then
            descriptions[#descriptions + 1] = ("%s dòng %d: tên, Class, Price hoặc bộ lọc không hợp lệ."):format(selling and "Sell" or "Sniper", index)
            return
        end
        local itemId, tier, roman
        if class ~= "Pet" then itemId, tier, roman = itemTier(name) end
        local rule = { name = name, class = class ~= "" and class or nil, huge = huge,
            price = percent and (tostring(percent) .. "%") or diamonds, percent = percent,
            variant = variant ~= "" and variant or nil, minPrice = cap,
            itemId = itemId, tier = tier, roman = roman }
        table.insert(selling and sellRules or rules, rule)
        descriptions[#descriptions + 1] = ("%s · %s · Price %s%s"):format(selling and "Sell" or "Sniper", name,
            tostring(rule.price), cap and (" · giá < " .. formatDiamonds(cap)) or "")
    end
    for index, entry in ipairs(type(config.sell) == "table" and config.sell or {}) do addRule(entry, true, index) end
    for index, entry in ipairs(type(config.items) == "table" and config.items or {}) do addRule(entry, false, index) end
    return #descriptions > 0 and table.concat(descriptions, "\n") or "Danh sách giao dịch chưa có món."
end



features.TradingSniperBooth = {
    configure = configure,
    setStatusCallback = function(callback)
        statusCallback = callback
        if callback then pcall(callback, tradingStatus) end
    end,
    setHop = function(on)
        hopEnabled = on == true
        nextSearchAt = nil
        setStatus(hopEnabled and "Đã bật tìm server qua Terminal." or "Hop đang tắt; chỉ quét server hiện tại.")
    end,
    duy = function(on, shared)
        if on and not sniperEnabled then
            nextSearchAt = nil
            nextTravelAt = 0
        end
        sniperEnabled = on
        if on then setStatus("Đang quét booth; nếu không có món đạt giá sẽ tìm qua Terminal.")
        else setStatus("Đã tắt Sniper Booth.") end
        if not on and pendingHop then clearPendingHop() end
        start(shared)
    end,
}



-- Bật đăng bán theo danh sách từ launcher.
features.TradingAutoSell = {
    duy = function(on, shared)
        if on and #sellRules == 0 then
            notice("Auto Sell chưa có danh sách bán. Đặt món trong RobloxHubConfig.trading.sell trước khi tải UI.lua.")
        end
        local wasEnabled = sellEnabled
        sellEnabled = on
        if on and not wasEnabled then
            local firstInServer = environment.RobloxHubSellerJob ~= game.JobId
            environment.RobloxHubSellerJob = game.JobId
            sellerPhase = firstInServer and "waiting" or "reset"
            restoreWaitUntil = os.clock() + 5
            restoreRequestedAt, resetListingId = nil, nil
            nextSellAt, nextClaimAt, sellerBoothId = 0, 0, nil
            enableRestorePrompt()
        elseif not on then
            disableRestorePrompt()
        end
        start(shared)
    end,
}

features.TradingWebhook = {
    setUrl = function(value)
        webhookUrl = clean(value)
        if webhookEnabled then webhookReady() end
    end,
    setMinimum = function(value)
        local minimum = parseDiamonds(value)
        if minimum == nil then return end
        minDiamond = minimum
        belowMinimum = nil
    end,
    duy = function(on, shared)
        if on and not webhookEnabled then belowMinimum = nil end
        webhookEnabled = on
        watchSales()
        start(shared)
    end,
}

return features
