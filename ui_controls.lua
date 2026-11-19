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
        -- Class được tạo trước Item; cấu hình chạy trước toggle.
        for _, toggles in ipairs({ false, true }) do
            for _, id in ipairs(order) do
                local entry = records[id]
                if (entry.kind == "toggle") == toggles and values[id] ~= nil
                    and (not phase or (phase == "toggles") == toggles) then
                    self:Set(id, values[id])
                end
            end
        end
    end
    function api:Run(actions)
        for _, action in ipairs(actions or {}) do
            assert(type(action) == "table", "Mỗi action cần là bảng {set=..., value=...} hoặc {press=...}")
            if action.set then self:Set(action.set, action.value)
            elseif action.press then self:Press(action.press)
            else error("Action thiếu set hoặc press") end
        end
    end
    function api:WrapTab(tab, tabName)
        local quick = tab:CreateGroup({ direction = "column" })
        quick:CreateSection({ name = "Bật / tắt" })
        local details = tab:CreateGroup({ direction = "column" })
        details:CreateSection({ name = "Cấu hình / danh sách" })
        local function wrap(container)
            return setmetatable({}, { __index = function(_, method)
                if method == "CreateGroup" then
                    return function(_, props) return wrap(container:CreateGroup(props)) end
                end
                local kinds = { CreateToggle = "toggle", CreateInput = "input", CreateDropdown = "dropdown", CreateButton = "button" }
                local kind = kinds[method]
                if kind then
                    return function(_, props)
                        local options = {}
                        for key, value in pairs(props) do options[key] = value end
                        local id = props.flag or (tabName .. "/" .. props.name)
                        assert(not records[id], "Trùng flag control: " .. id)
                        local target = kind == "toggle" and quick or container
                        -- Rayfield Gen2 không có CreateInput trên Group; đặt input ở Tab.
                        if type(target[method]) ~= "function" then target = tab end
                        local control = target[method](target, options)
                        records[id] = { kind = kind, control = control, callback = props.callback,
                            name = props.name, tab = tabName }
                        order[#order + 1] = id
                        return control
                    end
                end
                if type(container[method]) == "function" then
                    return function(_, ...) return container[method](container, ...) end
                end
                return container[method]
            end })
        end
        return wrap(details)
    end
    return api
end
