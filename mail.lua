local features = {}

local lib = game:GetService("ReplicatedStorage").Library
local net = require(lib.Client.Network)
local save = require(lib.Client.Save)
local items = require(lib.Items)
local constants = require(lib.Balancing.Constants)
local mailbox = require(lib.Types.Mailbox)
local flags = require(lib.Client.FFlags)
local player = game:GetService("Players").LocalPlayer
local mailJob

-- Tự nhận toàn bộ thư; khi server báo cooldown thì đợi 30 giây.
features.MailAutoClaim = {
    duy = function(on)
        if mailJob then
            task.cancel(mailJob)
            mailJob = nil
        end
        if not on then return end

        mailJob = task.defer(function()
            while true do
                local ok, result, message = pcall(net.Invoke, "Mailbox: Claim All")
                local responseText = string.lower(tostring(message or result or ""))
                local cooldown = responseText:find("wait") and responseText:find("second")
                task.wait(cooldown and 30 or 5)
            end
        end)
    end,
}

-- Auto Gift / Mỗi dòng là một món, có thể gửi qua nhiều stack cùng tên.
-- Sửa Class và ID nội bộ của món tại đây. Thứ tự ID trong mỗi nhóm là thứ tự dropdown.
local giftCatalog = {
    Currency = { "Diamonds" },
    Pet = { "Stingray" },
    Consumable = { "Patch Coin Boost II", "Pumpkin Damage Boost II", "Island Luck Boost II" },
}

-- Ghép tên boost cấp II với ID gốc và cấp trong inventory.
local configuredItems
local resolveConfigured
local directory = require(lib.Directory)
local tierTwoBoostIds = {
    ["Patch Coin Boost II"] = "Patch Coin Boost",
    ["Pumpkin Damage Boost II"] = "Pumpkin Damage Boost",
    ["Island Luck Boost II"] = "Island Luck Boost",
}

-- Giữ các dòng Auto Gift theo thứ tự Add Item.
local rules = {}
local recipient = ""
local giftEnabled = false
local giftJob
local giftRevision = 0
-- Quy đổi hậu tố k, m, b và t sang hệ số.
local suffixes = { [""] = 1, k = 1e3, m = 1e6, b = 1e9, t = 1e12 }

-- Đổi Amount hoặc Keep thành số nguyên hợp lệ.
local function parseAmount(text)
    local number, suffix = tostring(text or ""):lower():gsub(",", ""):match("^%s*(%d+%.?%d*)%s*([kmbt]?)%s*$")
    if not number then return nil end
    local amount = tonumber(number) * suffixes[suffix]
    if amount > 2^53 - 1 or amount % 1 ~= 0 then return nil end
    return amount
end

-- Kiểm tra stack có đủ điều kiện gửi qua mail.
local function canGiftItem(class, entry)
    if entry._lk then return false end
    local ok, tradable = pcall(function()
        return items.From(class, table.clone(entry)):IsTradable()
    end)
    return ok and tradable
end

-- Lấy kho hiện tại từ Save của client.
local function giftInventory()
    local data = save.Get()
    return data and data.Inventory or {}, data
end

-- Tính phí gửi thư theo dữ liệu mailbox của game.
local function mailFee(data)
    local multiplier = flags.Get(flags.Keys.DiamondSink_MailboxFee_Mult)
    if type(multiplier) ~= "number" or multiplier <= 0 then multiplier = 1 end
    local base = math.floor(constants.MailboxDiamondCost * multiplier)
    if not data.MailboxResetTime or data.MailboxResetTime < workspace:GetServerTimeNow()
        or (data.Gamepasses and data.Gamepasses.VIP) or player:GetAttribute("Partner") then
        return base
    end
    return math.min(math.floor(base * mailbox.DiamondCostGrowthRate^(data.MailboxSendsSinceReset or 0)),
        math.floor(mailbox.DiamondCostCap * multiplier))
end

-- Đếm Diamonds có thể dùng để kiểm tra phí.
local function countDiamonds(inventory)
    local count = 0
    for _, entry in pairs(inventory.Currency or {}) do
        if entry.id == "Diamonds" then count += entry._am or 1 end
    end
    return count
end

-- Tìm số lượng và stack lớn nhất theo đúng Class và Item ID.
local function findGiftStock(inventory, rule)
    local stock, largestUid, largest = 0, nil, 0
    for uid, entry in pairs(inventory[rule.class] or {}) do
        if entry.id == rule.id and (not rule.tier or (entry.tn or 1) == rule.tier) and canGiftItem(rule.class, entry) then
            local amount = entry._am or 1
            stock += amount
            if amount > largest then largestUid, largest = uid, amount end
        end
    end
    return stock, largestUid, largest
end

-- Gửi đúng Amount trong một thư khi stack và phần Keep đều đủ.
local function sendRule(rule, revision)
    local inventory, data = giftInventory()
    if not data then return end
    local stock, uid, stack = findGiftStock(inventory, rule)
    local quantity = rule.amount
    if not uid or stack < quantity then return end
    local fee = mailFee(data)
    if countDiamonds(inventory) < fee then return end
    local isDiamonds = rule.class == "Currency" and rule.id == "Diamonds"
    local available = stock - rule.keep - (isDiamonds and fee or 0)
    if available < quantity or not giftEnabled or revision ~= giftRevision then return end

    -- Chờ trước khi đọc lại kho nếu server báo gửi lỗi.
    local ok, accepted = pcall(net.Invoke, "EF_Relay", recipient, "", rule.class, uid, quantity)
    if not ok or not accepted then
        task.wait(5)
        return
    end

    -- Đợi kho xác nhận trừ stack trước khi gửi thư kế tiếp.
    repeat
        task.wait(0.25)
        local live, liveData = giftInventory()
        local entry = live[rule.class] and live[rule.class][uid]
        if liveData and (not entry or (entry._am or 1) < stack) then break end
    until not giftEnabled or revision ~= giftRevision
end

-- Duyệt lần lượt các quy tắc gửi quà khi Auto Gift đang bật.
local function autoGift()
    while giftEnabled do
        local revision = giftRevision
        if recipient ~= "" and recipient:lower() ~= player.Name:lower() then
            for _, rule in ipairs(rules) do
                if not giftEnabled or revision ~= giftRevision then break end
                sendRule(rule, revision)
            end
        end
        task.wait(2)
    end
    giftJob = nil
end

-- Xuất chức năng cấu hình Auto Gift cho tab Mail.
features.MailAutoGift = {
    configureCatalog = function(values, resolve)
        assert(type(values) == "table", "lists.mail phải là bảng Class -> danh sách")
        local catalog, resolved = {}, {}
        for class, names in pairs(values) do
            assert(items.Types[class], "Mail Class không hợp lệ: " .. tostring(class))
            local _, labels, byName = resolve(directory, class, names)
            catalog[class], resolved[class] = labels, byName
        end
        giftCatalog, configuredItems, resolveConfigured = catalog, resolved, resolve
    end,
    getFee = mailFee,
    setRecipient = function(value)
        local name = value:match("^%s*(.-)%s*$")
        if recipient ~= name then recipient = name; giftRevision += 1 end
    end,
    -- Liệt kê Class từ bảng giftCatalog.
    getClasses = function()
        local classes = {}
        for class in pairs(giftCatalog) do classes[#classes + 1] = class end
        table.sort(classes)
        return classes
    end,
    -- Lấy riêng các Item ID của Class đã chọn.
    getNames = function(class)
        return table.clone(giftCatalog[class] or {})
    end,
    add = function(class, name, amountText, keepText)
        local ids = giftCatalog[class]
        local selected
        if configuredItems and ids and name then
            local ok, entries = pcall(resolveConfigured, directory, class, {name})
            if not ok then return false, tostring(entries) end
            selected = entries[1]
            name = selected.name
        end
        if not ids or not name or (not selected and not table.find(ids, name)) then
            return false, "Chọn Item Class và Item ID trong cùng nhóm"
        end
        local amount, keep = parseAmount(amountText), parseAmount(keepText)
        if not amount or amount <= 0 or keep == nil then
            return false, "Amount phải lớn hơn 0 và Keep từ 0 trở lên"
        end
        local boostId = not configuredItems and class == "Consumable" and tierTwoBoostIds[name]
        rules[#rules + 1] = {
            class = class,
            name = name,
            id = selected and selected.id or boostId or name,
            tier = selected and selected.tier or (boostId and 2 or nil),
            amount = amount,
            keep = keep,
        }
        giftRevision += 1
        return true
    end,
    -- Xóa quy tắc Auto Gift được thêm gần nhất.
    removeLast = function()
        if #rules > 0 then table.remove(rules); giftRevision += 1 end
    end,
    getList = function() return table.clone(rules) end,
    duy = function(enabled)
        if giftEnabled ~= enabled then giftRevision += 1 end
        giftEnabled = enabled
        if enabled and not giftJob then giftJob = task.defer(autoGift) end
    end,
}

return features
