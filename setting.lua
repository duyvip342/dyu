-- Setting / Chuyển định kỳ sang server đông người còn chỗ của cùng map.
local features = {}
local players = game:GetService("Players")
local player = players.LocalPlayer
local teleport = game:GetService("TeleportService")
local http = game:GetService("HttpService")
local environment = type(getgenv) == "function" and getgenv() or _G
local previous = environment.RobloxHubTimedHop
if type(previous) == "table" and type(previous.stop) == "function" then previous.stop() end

local controller = { enabled = false, manual = false }
environment.RobloxHubTimedHop = controller
local minutes, dueAt = 30, 0
local seeking = false
local retrySeconds = 5
local job, pending, failureConnection
local getResumeConfig
local visited = {}
local rejected = {}
local lastError
local trading = require(game:GetService("ReplicatedStorage").Library.Client.TradingCmds)

-- In lỗi thay đổi để không lặp cùng cảnh báo mỗi giây.
local function report(reason)
    reason = tostring(reason)
    if reason ~= lastError then warn("[Timed Hop] " .. reason) end
    lastError = reason
end

-- Dọn listener và worker khi tắt hoặc exec lại launcher.
controller.stop = function()
    controller.enabled = false
    controller.manual = false
    seeking = false
    pending = nil
    if failureConnection then failureConnection:Disconnect(); failureConnection = nil end
end

-- Chọn hàm tiếp tục launcher mà executor cung cấp.
local function queueFunction()
    for _, scope in ipairs({ environment, _G }) do
        for _, key in ipairs({ "queue_on_teleport", "queue_on_tp", "queueonteleport", "queueontp" }) do
            if type(scope[key]) == "function" then return scope[key] end
        end
        for _, key in ipairs({ "syn", "fluxus" }) do
            local api = scope[key]
            if type(api) == "table" and type(api.queue_on_teleport) == "function" then return api.queue_on_teleport end
        end
    end
    if type(queue_on_teleport) == "function" then return queue_on_teleport end
    if type(queue_on_tp) == "function" then return queue_on_tp end
    if type(queueonteleport) == "function" then return queueonteleport end
    if type(queueontp) == "function" then return queueontp end
end

-- Đọc một trang server công khai theo số người giảm dần.
local function serverPage(cursor)
    local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
        .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
    if cursor then url ..= "&cursor=" .. http:UrlEncode(cursor) end
    local ok, body = pcall(game.HttpGet, game, url)
    if not ok then
        local send = type(request) == "function" and request or http_request
        assert(type(send) == "function", "Không đọc được danh sách server.")
        local response = send({ Url = url, Method = "GET" })
        assert(type(response) == "table" and tonumber(response.StatusCode) == 200, "Roblox chưa trả danh sách server.")
        body = response.Body
    end
    local page = http:JSONDecode(body)
    assert(type(page) == "table" and type(page.data) == "table", "Danh sách server không hợp lệ.")
    return page
end

-- Chọn server đông nhất còn ít nhất một chỗ và chưa ghé gần đây.
local function pickServer(rows, allowVisited)
    local best
    for _, row in ipairs(rows) do
        if type(row.id) == "string" and row.id ~= game.JobId and (allowVisited or not table.find(visited, row.id))
            and (rejected[row.id] or 0) <= os.clock()
            and type(row.playing) == "number" and type(row.maxPlayers) == "number"
            and row.playing > 0 and row.playing < row.maxPlayers
            and (not best or row.playing > best.playing) then best = row end
    end
    return best
end

-- Chuẩn bị cấu hình launcher cho server đích.
local function queueLauncher(target)
    local queue = queueFunction()
    if not queue then
        report("Executor thiếu queue_on_teleport; cần exec lại launcher ở server mới.")
        return
    end
    local config = getResumeConfig and getResumeConfig()
    local encoded = config and http:JSONEncode(config) or ""
    local source = ([=[
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId ~= %d or game.JobId ~= %q then return end
local env = type(getgenv) == "function" and getgenv() or _G
if env.RobloxHubTimedHopResumed == game.JobId then return end
env.RobloxHubTimedHopResumed = game.JobId
local config = %q
if config ~= "" then env.RobloxHubConfig = game:GetService("HttpService"):JSONDecode(config) end
assert(loadstring(game:HttpGet("https://raw.githubusercontent.com/duyvip453/dyu/refs/heads/main/UI.lua?reload=" .. os.time())))()
]=]):format(game.PlaceId, target, encoded)
    local ok, result = pcall(queue, source)
    if not ok or result == false then report("Executor không thể nạp lại launcher sau teleport.") end
end

-- Ghi server đã lỗi và tiếp tục đợt hop sau 5 giây.
local function fail(reason)
    if pending then rejected[pending.id] = os.clock() + 60 end
    pending = nil
    dueAt = os.clock() + retrySeconds
    report(reason)
end

-- Đến hạn mới đọc server và chờ giao dịch hiện tại kết thúc.
local function tick()
    if pending then
        if os.clock() >= pending.deadline then fail("Hết thời gian chờ chuyển server.") end
        return
    end
    if os.clock() < dueAt then return end
    if trading.GetState() then
        if controller.manual then report("Đang giao dịch; sẽ hop ngay khi giao dịch kết thúc.") end
        return
    end
    seeking = true
    for id, expires in pairs(rejected) do if expires <= os.clock() then rejected[id] = nil end end
    local cursor, selected, revisitable
    for _ = 1, 3 do
        local page = serverPage(cursor)
        if not (controller.enabled or controller.manual) then return end
        selected = pickServer(page.data)
        if selected then break end
        local candidate = pickServer(page.data, true)
        if candidate and (not revisitable or candidate.playing > revisitable.playing) then revisitable = candidate end
        cursor = page.nextPageCursor
        if type(cursor) ~= "string" or cursor == "" then break end
    end
    selected = selected or revisitable
    if not selected then
        dueAt = os.clock() + retrySeconds
        report("Chưa có server còn chỗ; tiếp tục tìm sau 5 giây.")
        return
    end
    if not (controller.enabled or controller.manual) or trading.GetState() then return end
    table.insert(visited, game.JobId)
    if #visited > 12 then table.remove(visited, 1) end
    queueLauncher(selected.id)
    if not (controller.enabled or controller.manual) then return end
    pending = { id = selected.id, deadline = os.clock() + 25 }
    print(("[Timed Hop] Đang chuyển tới server %d/%d người."):format(selected.playing, selected.maxPlayers))
    local ok, reason = pcall(function() teleport:TeleportToPlaceInstance(game.PlaceId, selected.id, player) end)
    if not ok then fail(reason) end
end

features.SettingsTimedHop = {
    setMinutes = function(value)
        local number = tonumber(value)
        if not number or not (number > 0 and number <= 10080) then return false end
        minutes = number
        if controller.enabled and not seeking then dueAt = os.clock() + minutes * 60 end
        return true
    end,
    getMinutes = function() return minutes end,
    setResumeConfig = function(callback) getResumeConfig = callback end,
    getVisited = function() return table.clone(visited) end,
    setVisited = function(values)
        table.clear(visited)
        for _, id in ipairs(type(values) == "table" and values or {}) do
            if type(id) == "string" and #visited < 12 then visited[#visited + 1] = id end
        end
    end,
    duy = function(on)
        if not on then controller.stop(); return end
        if controller.enabled and job then return end
        controller.enabled = true
        seeking = false
        dueAt = os.clock() + minutes * 60
        failureConnection = teleport.TeleportInitFailed:Connect(function(who, result, reason, placeId, options)
            if not pending or who ~= player or placeId ~= game.PlaceId then return end
            local id = options and options.ServerInstanceId
            if id and id ~= "" and id ~= pending.id then return end
            fail(reason ~= "" and reason or result)
        end)
        if job then return end
        job = task.defer(function()
            while (controller.enabled or controller.manual) and environment.RobloxHubTimedHop == controller do
                local ok, reason = pcall(tick)
                if not ok then dueAt = os.clock() + retrySeconds; report(reason) end
                task.wait(1)
            end
            job = nil
        end)
    end,
}

-- Dùng chung bộ tìm server và xử lý lỗi, không bật lịch hop định kỳ.
features.SettingsTimedHop.hopNow = function()
    if pending or controller.manual then
        report("Đang tìm hoặc chuyển server, vui lòng chờ.")
        return
    end
    local wasEnabled = controller.enabled
    -- Khởi động worker/listener nếu lịch định kỳ đang tắt.
    features.SettingsTimedHop.duy(true)
    controller.enabled = wasEnabled
    controller.manual = true
    seeking = true
    dueAt = 0
end

return features
