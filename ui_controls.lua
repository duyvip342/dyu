-- Registry chung cho bố cục UI và điều khiển từ launcher/script bên ngoài.
return function(window)
    local api = { ready = false }
    local records, order = {}, {}
    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for key, entry in pairs(value) do result[key] = copy(entry) end
        return result
    end
    local function record(id)
        return assert(records[id], "Không có control: " .. tostring(id))
    end
    function api:Get(id)
        return copy(record(id).control.value)
    end
    function api:Set(id, value)
        local entry = record(id)
        assert(entry.kind ~= "button", "Dùng Press để bấm nút: " .. id)
        if entry.kind == "toggle" then assert(type(value) == "boolean", id .. " cần true/false") end
        if entry.kind == "input" then
            assert(type(value) == "string" or type(value) == "number", id .. " cần chuỗi/số")
        end
        if entry.kind == "dropdown" then
            local requested = type(value) == "table" and value or { value }
            for _, name in ipairs(requested) do
                assert(table.find(entry.control.options, name), id .. " không có lựa chọn: " .. tostring(name))
            end
        end
        -- Cập nhật hình thức im lặng rồi gọi cùng callback, chờ xong trước lệnh tiếp.
        entry.control:Set(copy(value), true)
        local actual = entry.control.value
        if entry.kind == "dropdown" then
            actual = entry.control.multiSelect and actual or actual[1]
        end
        if entry.callback then entry.callback(copy(actual)) end
        return self:Get(id)
    end
    function api:Press(id)
        local entry = record(id)
        assert(entry.kind == "button", "Control không phải nút: " .. id)
        if entry.callback then return entry.callback() end
    end
    function api:List()
        local result = {}
        for _, id in ipairs(order) do
            local entry = records[id]
            result[#result + 1] = { id = id, name = entry.name, type = entry.kind, tab = entry.tab }
        end
        return result
    end
    function api:Snapshot()
        local result = {}
        for _, id in ipairs(order) do
            if records[id].kind ~= "button" then result[id] = self:Get(id) end
        end
        return result
    end
    function api:Apply(values, phase)
        values = values or {}
        -- Báo lỗi flag sai thay vì âm thầm bỏ qua.
        for id in pairs(values) do
            assert(record(id).kind ~= "button", "Đặt nút trong actions: " .. id)
        end
