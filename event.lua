-- Mystery Store / duyvip342. UI và cấu hình nằm trong UI.lua.
-- MS-CORE | MS-MOVE | MS-ACTION | MS-REGISTER | MS-LEVEL | MS-DECOR
-- MS-COMBINE | MS-STOCK | MS-MERCHANT | MS-GIFT | MS-BOOST | MS-FARM | MS-OPTIMIZE | MS-WORKERS.
local features = {}
local environment = type(getgenv)=="function" and getgenv() or _G
local previous = environment.RobloxHubMysteryStore
if previous and type(previous.Stop)=="function" then previous.Stop() end
local session = previous and previous.jobId==game.JobId and previous.session or {pending={},nextAt={}}
local controller: any = {active=true,jobId=game.JobId,session=session,flags={},jobs={},errors={},near={}}
environment.RobloxHubMysteryStore = controller
local dependencies
local lease
local assigned = {}
local movement={mode="teleport",timeout=45,version=0}
local boxKeep: {[string]:number} = {["MysteryStore Box 3"]=0,["MysteryStore Box 4"]=0}

-- ============================================================================
-- [MS-CORE] API chỉ nạp khi bật tính năng; load module không khởi tạo worker.
local function api()
    if dependencies then return dependencies end
    local library=game:GetService("ReplicatedStorage"):WaitForChild("Library",10)
    assert(library,"Mystery Store: Library unavailable")
    local client=library.Client
    local store=require(client.MysteryStoreCmds)
    dependencies={
        player=game:GetService("Players").LocalPlayer,
        store=store,base=store.Feature("Base"),pad=store.Feature("Pad"),
        save=require(client.Save),instancing=require(client.InstancingCmds),
        currency=require(client.CurrencyCmds),network=require(client.Network),
        upgrades=require(client.EventUpgradeCmds),
        upgradeDefs=require(library.Types.MysteryStore.Upgrades),
        definitions=require(library.Types.MysteryStore),
        buttons=require(library.Util.MysteryStoreButtons),
        boxes=require(library.Types.MysteryStore.Boxes),
        combine=require(library.Util.MysteryStoreCombine),
        decorDefs=require(library.Types.MysteryStore.Decor),
        decor=require(library.Util.MysteryStoreDecor),
        merchant=require(library.Util.MysteryStoreMerchant),
        items=require(library.Items),lootbox=require(client.LootboxCmds),
        consumables=require(client.ConsumableCmds),
        boostDefs=require(library.Util.MysteryStoreBoosts),
        playerPet=require(client.PlayerPet),pets=require(client.PetCmds),
        breaks=require(client.BreakableFrontend),
        instanceParent=require(library.Types.Breakables).ParentType.Instance,
    }
    return dependencies
end
local function report(key,message)
    message=message and tostring(message)
    if message and controller.errors[key]~=message then warn("[Mystery Store / "..key.."] "..message) end
    controller.errors[key]=message
end
local function enabled(flag)
    return controller.active and controller.flags[flag]==true
end
local function inventory(data,class)
    return data and ((data.Inventory and data.Inventory[class]) or data[class]) or {}
end
local function amount(data,class,id,uid)
    local total=0
    for key,item in pairs(inventory(data,class)) do
        if (not uid or uid==key) and item.id==id then total+=item._am or 1 end
    end
    return total
end
local function context()
    local a=api()
    if a.instancing.GetInstanceID()~="MysteryStore" then return end
    local p=a.base.Plot()
    if not p or p:IsDestroyed() or p:GetOwner()~=a.player then return end
    local model=p:GetModel()
    local character=a.player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart")
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    local data=a.save.Get()
    if not model or not model.Parent or not root or not humanoid or humanoid.Health<=0 or not data then return end
    return {api=a,plot=p,model=model,character=character,root=root,data=data,
        scope=tostring(p.Id),level=a.buttons.Level(p:Save("Level")),
        coins=a.currency.Get("MysteryStoreCoins") or 0,
        own=(data.InstanceVars and data.InstanceVars.MysteryStore) or {}}
end
local function valid(c,flag)
    if not enabled(flag) then return false end
    local a=c.api
    local humanoid=c.character:FindFirstChildOfClass("Humanoid")
    return a.instancing.GetInstanceID()=="MysteryStore" and a.player.Character==c.character
        and humanoid and humanoid.Health>0 and c.root.Parent==c.character
        and c.plot==a.base.Plot() and not c.plot:IsDestroyed()
        and c.plot:GetModel()==c.model and c.model.Parent~=nil
end
local function tier(c,track)
    return c.api.upgrades.GetTier(c.api.upgradeDefs.Id(track)) or 0
end
local function partSpot(part)
    if part and part:IsA("BasePart") then return part.CFrame*CFrame.new(0,part.Size.Y/2+3,0) end
    if part and part:IsA("Model") then return part:GetPivot()*CFrame.new(0,3,0) end
    return nil
end
local function machineSpot(c,name)
    local machines=c.model:FindFirstChild("Interactable")
    machines=machines and machines:FindFirstChild("Machines")
    local machine=machines and machines:FindFirstChild(name)
    if not machine then return end
    return partSpot(machine:FindFirstChild("Pad",true)) or machine:GetPivot()*CFrame.new(0,3,0)
end

-- ============================================================================
-- [MS-MOVE] Một chủ vị trí; không trả nhân vật đã chết/đổi plot hoặc tự đi nơi khác.
local travel
local function releaseLease(owned)
    if owned and lease~=owned then return end
    local old=lease
    if not old then return end
    local c=old.context
    local humanoid=c.character:FindFirstChildOfClass("Humanoid")
    if c.api.instancing.GetInstanceID()=="MysteryStore" and c.api.player.Character==c.character
        and humanoid and humanoid.Health>0
        and not c.plot:IsDestroyed() and c.api.base.Plot()==c.plot and c.plot:GetModel()==c.model
        and c.root.Parent==c.character and (c.root.Position-old.destination.Position).Magnitude<9
        and old.version==movement.version then
        if old.mode=="walk" then
            if valid(c,old.flag) then travel(c,old.flag,old.back,old) end
        else c.character:PivotTo(old.back) end
    end
    if old.mode=="walk" and humanoid and c.root.Parent==c.character then humanoid:MoveTo(c.root.Position) end
    if lease==old then lease=nil end
end
travel=function(c,flag,spot,owned)
    if not valid(c,flag) or lease~=owned or owned.version~=movement.version then return false end
    if owned.mode=="teleport" then
        if (c.root.Position-spot.Position).Magnitude>2 then
            c.root.AssemblyLinearVelocity=Vector3.zero
            c.character:PivotTo(spot)
            task.wait(0.2)
        end
        return valid(c,flag) and lease==owned and owned.version==movement.version
    end
    local humanoid=c.character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    local service=c.api.pathfinding or game:GetService("PathfindingService")
    local path=service:CreatePath({AgentCanJump=true,WaypointSpacing=5})
    local ok=pcall(path.ComputeAsync,path,c.root.Position,spot.Position)
    if not valid(c,flag) or lease~=owned or owned.version~=movement.version then return false end
    if not ok or path.Status~=Enum.PathStatus.Success then
        report("movement","Không tìm được đường chạy bộ; chưa gửi thao tác.")
        return false
    end
    local deadline=os.clock()+movement.timeout
    for _,waypoint in ipairs(path:GetWaypoints()) do
        if not valid(c,flag) or lease~=owned or owned.version~=movement.version then return false end
        if waypoint.Action==Enum.PathWaypointAction.Jump then humanoid.Jump=true end
        humanoid:MoveTo(waypoint.Position)
        local segmentDeadline=math.min(deadline,os.clock()+8)
        while (c.root.Position-waypoint.Position).Magnitude>3 do
            if not valid(c,flag) or lease~=owned or owned.version~=movement.version then return false end
            if os.clock()>=segmentDeadline then
                humanoid:MoveTo(c.root.Position)
                report("movement","Chạy bộ bị kẹt hoặc hết thời gian; chưa gửi thao tác.")
                return false
            end
            task.wait(0.1)
        end
    end
    report("movement",nil)
    return valid(c,flag) and lease==owned and owned.version==movement.version
        and (c.root.Position-spot.Position).Magnitude<=5
end
local function approach(c,flag,spot)
    if not spot or lease or not valid(c,flag) then return false end
    local back=c.character:GetPivot()
    if enabled("EventStoreAutoCombine") and c.api.pad.OnPad() then back=c.api.base.ZoneLanding(c.plot) or back end
    lease={context=c,flag=flag,back=back,destination=spot,mode=movement.mode,version=movement.version}
    return travel(c,flag,spot,lease)
end

-- ============================================================================
-- [MS-ACTION] Khóa request trước Invoke; xác nhận bằng dữ liệu server, không UI giả.
local function confirmed(p,c)
    if p.scope~=c.scope then return true end
    if p.kind=="level" then return c.level>=p.want end
    if p.kind=="register" then return tier(c,p.track)>=p.want end
    if p.kind=="decor" then
        local placed=c.plot:Save("Plinths") or {}
        return (placed[tostring(p.slot)] or placed[p.slot])==p.id
    end
    if p.kind=="unlock" then
        return c.api.definitions.BoxLocked(c.own.BoxLocks,p.rung)==(p.locked==true)
    end
    if p.kind=="combine" or p.kind=="gift" then return amount(c.data,"Lootbox",p.id,p.uid)<p.before end
    if p.kind=="boost" then return amount(c.data,"Consumable",p.id,p.uid)<p.before end
    if p.kind=="merchant" then
        if amount(c.data,"Misc",p.id)>p.before then return true end
        local shelf=controller.offers and controller.offers.MysteryStoreDecorMerchant
        local offer=shelf and shelf.Seed==p.seed and shelf.Offers and shelf.Offers[tostring(p.slot)]
        return offer and offer.Stock<p.stock or false
    end
    return false
end
local function waiting(channel,c)
    local p=session.pending[channel]
    if not p then return false end
    if confirmed(p,c) then session.pending[channel]=nil;return false end
    if os.clock()-p.at<12 then return true end
    session.pending[channel]=nil
    session.nextAt[p.key]=os.clock()+5
    report(p.kind,"Chưa thấy dữ liệu xác nhận; giãn nhịp trước khi thử lại.")
    return false
end
local function distanceError(message)
    local s=tostring(message or ""):lower()
    return s:find("distance",1,true) or s:find("too far",1,true) or s:find("closer",1,true)
        or s:find("near the",1,true) or s:find("stand on",1,true) or s:find("nearby",1,true)
        or s:find("not enough space",1,true)
        or s:find("near ",1,true) or s:find("inside your",1,true)
        or s:find("your own store",1,true) or s:find("step on",1,true)
end
local function dispatch(c,flag,p,send,check,spot,forceNear,channel)
    channel=channel or "main"
    if (lease and channel~="boost") or not valid(c,flag) or waiting(channel,c)
        or os.clock()<(session.nextAt[p.key] or 0) then return false end
    local owned
    if forceNear or controller.near[p.kind] then
        local ok=approach(c,flag,spot)
        owned=lease
        if not ok then releaseLease(owned);return false end
    end
    local fresh=context()
    if not fresh or fresh.plot~=c.plot or not valid(c,flag) or (check and not check(fresh)) then
        if owned then releaseLease(owned) end
        return false
    end
    p.scope=c.scope;p.at=os.clock()
    session.pending[channel]=p
    local ok,accepted,message=pcall(send,fresh)
    if not controller.active then return true end
    session.nextAt[p.key]=os.clock()+0.5
    if ok and accepted==true then report(p.kind,nil)
    elseif ok then
        session.pending[channel]=nil
        local seconds=tonumber(tostring(message):match("([%d.]+)%s*second")) or 0
        session.nextAt[p.key]=os.clock()+math.max(3,math.min(30,seconds))
        if distanceError(message) and spot then controller.near[p.kind]=true end
        report(p.kind,message or "Game chưa chấp nhận thao tác.")
    else report(p.kind,accepted) end
    if owned then releaseLease(owned) end
    return true
end

-- ============================================================================
-- [MS-REGISTER] Tier2 là tổng cấp đã mua, không mua thêm 2 lần mỗi khi exec lại.
local otherTracks={"BoothSlots","PadSpeed","BoxDrops","CustomerFlow"}
local function foundationDone(c)
    for _,track in ipairs(otherTracks) do
        if tier(c,track)<math.min(2,c.api.upgradeDefs.MaxTier(track)) then return false end
    end
    return true
end
local function registerTrack(c)
    local defs=c.api.upgradeDefs
    if c.level<3 then
        if tier(c,"CoinYield")<defs.MaxTier("CoinYield") then return "CoinYield" end
    elseif c.level<5 then
        for _,track in ipairs(otherTracks) do
            local current=tier(c,track)
            local cost=defs.Price(track,current+1)
            if current<math.min(2,defs.MaxTier(track)) and cost and cost<=c.coins then return track end
        end
    else
        local order={"CoinYield","BoothSlots","PadSpeed","BoxDrops","CustomerFlow"}
        for offset=0,#order-1 do
            local index=((controller.upgradeIndex or 1)+offset-1)%#order+1
            local track=order[index]
            local current=tier(c,track)
            local cost=defs.Price(track,current+1)
            if current<defs.MaxTier(track) and cost and cost<=c.coins then return track,index end
        end
    end
end
local function registerStep(c)
    local flag="EventStoreAutoRegister"
    if not enabled(flag) then return false end
    local track,index=registerTrack(c)
    if not track then return false end
    local want=tier(c,track)+1
    local cost=c.api.upgradeDefs.Price(track,want)
    if not cost or cost>c.coins then return false end
    local sent=dispatch(c,flag,{kind="register",key="register:"..track,track=track,want=want},
        function(f)return f.api.upgrades.Purchase(f.api.upgradeDefs.Id(track))end,
        function(f)return tier(f,track)==want-1 and f.coins>=(f.api.upgradeDefs.Price(track,want) or math.huge)
            and registerTrack(f)==track end,machineSpot(c,"MysteryStoreUpgradeMachine"))
    if sent and index then controller.upgradeIndex=index%5+1 end
    return sent
end

-- ============================================================================
-- [MS-LEVEL] Đủ tiền mua tầng tiếp; nếu bật Register thì hoàn thành nền tier2 trước.
local function levelStep(c)
    local flag="EventStoreAutoLevel"
    if not enabled(flag) or c.level>=#c.api.definitions.LEVELS then return false end
    if c.level>=3 and enabled("EventStoreAutoRegister") and not foundationDone(c) then return false end
    local want=c.level+1
    local can,_,_,cost=c.api.buttons.CanBuy(c.level,want)
    if not can or not cost or c.coins<cost then return false end
    local spot=c.api.buttons.ResolvedSpot(c.model,want)
    if spot then spot=spot*CFrame.new(0,3,0) end
    return dispatch(c,flag,{kind="level",key="level:"..want,want=want},
        function(f)return f.plot:Invoke(f.api.definitions.NET.BuyLevel,want)end,
        function(f)return f.level==want-1 and f.coins>=(f.api.buttons.Price(want) or math.huge)
            and (f.level<3 or not enabled("EventStoreAutoRegister") or foundationDone(f))end,spot)
end

-- ============================================================================
-- [MS-DECOR] Lấp chỗ trống rồi thay món có % thấp nhất; cùng % không thay qua lại.
local function decorChoice(c)
    local best,bestValue
    for _,id in ipairs(c.api.decorDefs.IDS) do
        local available=0
        for _,item in pairs(inventory(c.data,"Misc")) do
            if item.id==id and not item._lk then available+=item._am or 1 end
        end
        local value=c.api.decor.Value(id) or 0
        if available>0 and (not best or value>bestValue) then best,bestValue=id,value end
    end
    if not best then return end
    local placed=c.plot:Save("Plinths") or {}
    local worstSlot,worstValue
    for slot=1,c.api.decorDefs.PlinthCount(c.level) do
        local id=placed[tostring(slot)] or placed[slot]
        if not id then return slot,best,bestValue end
        local value=c.api.decor.Value(id) or 0
        if not worstSlot or value<worstValue then worstSlot,worstValue=slot,value end
    end
    if worstSlot and bestValue>worstValue then return worstSlot,best,bestValue end
end
local function decorStep(c)
    local flag="EventStoreAutoDecor"
    if not enabled(flag) then return false end
    local slot,id=decorChoice(c)
    if not slot then return false end
    local plinths=c.model:FindFirstChild("Plinths")
    local marker=plinths and plinths:FindFirstChild(c.api.decorDefs.Marker(slot))
    local placed=c.plot:Save("Plinths") or {}
    local old=placed[tostring(slot)] or placed[slot]
    if old then
        -- Tháo món thấp nhất, chờ server xác nhận rồi mới đặt món tốt hơn.
        return dispatch(c,flag,{kind="decor",key="decor:"..slot,slot=slot},
            function(f)return f.plot:Invoke(f.api.definitions.NET.PlaceDecor,slot,nil)end,
            function(f)local s,i=decorChoice(f);return s==slot and i==id end,partSpot(marker))
    end
    return dispatch(c,flag,{kind="decor",key="decor:"..slot,slot=slot,id=id},
        function(f)return f.plot:Invoke(f.api.definitions.NET.PlaceDecor,slot,id)end,
        function(f)local s,i=decorChoice(f);return s==slot and i==id end,partSpot(marker))
end

-- ============================================================================
-- [MS-COMBINE] Cấp cao trước, dùng số bộ theo Ratio game; không ghép vật phẩm khóa.
local function combineChoice(c)
    for rung=c.api.boxes.Count()-1,1,-1 do
        local box=c.api.boxes.Box(rung)
        local ratio=c.api.combine.Ratio(rung)
        local available=0
        for _,item in pairs(inventory(c.data,"Lootbox")) do
            if item.id==box.Id and not item._lk then available+=item._am or 1 end
        end
        local surplus=available-(boxKeep[box.Id] or 0)
        if ratio>0 and surplus>=ratio then
            for uid,item in pairs(inventory(c.data,"Lootbox")) do
                local count=item._am or 1
                if item.id==box.Id and not item._lk and count>=ratio then
                    return {uid=uid,id=item.id,before=count,rung=rung,
                        sets=math.min(math.floor(math.min(count,surplus)/ratio),c.api.combine.MAX_SETS)}
                end
            end
        end
    end
end
local function combineStep(c)
    local flag="EventStoreAutoCombine"
    if not enabled(flag) then return false end
    local choice=combineChoice(c)
    if not choice then return false end
    choice.kind="combine";choice.key="combine:"..choice.uid
    local onPad=c.api.pad.OnPad()
    local spot=onPad and c.api.base.ZoneLanding(c.plot) or machineSpot(c,"MysteryStoreCombineMachine")
    if controller.near.combine then spot=machineSpot(c,"MysteryStoreCombineMachine") end
    return dispatch(c,flag,choice,
        function(f)return f.plot:Invoke(f.api.definitions.NET.CombineBoxes,choice.uid,choice.sets)end,
        function(f)
            local item=inventory(f.data,"Lootbox")[choice.uid]
            local available=0
            for _,entry in pairs(inventory(f.data,"Lootbox")) do
                if entry.id==choice.id and not entry._lk then available+=entry._am or 1 end
            end
            local required=choice.sets*f.api.combine.Ratio(choice.rung)
            return item and item.id==choice.id and not item._lk
                and (item._am or 1)>=required and available-(boxKeep[choice.id] or 0)>=required
        end,spot,onPad)
end

-- ============================================================================
-- [MS-STOCK] Giữ khóa bán loại có reserve; còn lại unlock. Không sửa CanStock.
local function stockStep(c)
    local flag="EventStoreAutoStock"
    if not enabled(flag) then return false end
    if enabled("EventStoreAutoCombine") and combineChoice(c) then return false end
    for rung=c.api.definitions.LOCKABLE_FROM,c.api.boxes.Count() do
        local box=c.api.boxes.Box(rung)
        local locked=(boxKeep[box.Id] or 0)>0
        if c.api.definitions.BoxLocked(c.own.BoxLocks,rung)~=locked then
            return dispatch(c,flag,{kind="unlock",key="boxlock:"..rung..":"..tostring(locked),rung=rung,locked=locked},
                function(f)return f.plot:Invoke(f.api.definitions.NET.LockBox,rung,locked)end,
                function()return ((boxKeep[box.Id] or 0)>0)==locked end)
        end
    end
    if c.api.pad.BoothFull() or os.clock()<(controller.nextStock or 0) then return false end
    local count=0
    for _,item in pairs(inventory(c.data,"Lootbox")) do
        if not item._lk and c.api.boxes.Index(item.id) and (boxKeep[item.id] or 0)==0 then count+=item._am or 1 end
    end
    if count==0 then return false end
    local pad=c.model:FindFirstChild("StockPad")
    local ok=approach(c,flag,partSpot(pad))
    local owned=lease
    if not ok then if owned and owned.flag==flag then releaseLease(owned)end;return false end
    local deadline=os.clock()+3
    while valid(c,flag) and os.clock()<deadline and not c.api.pad.BoothFull() do
        local fresh=context()
        if not fresh or fresh.plot~=c.plot then break end
        if enabled("EventStoreAutoCombine") and combineChoice(fresh) then break end
        task.wait(0.2)
    end
    releaseLease(owned)
    controller.nextStock=os.clock()+2
    return true
end

-- ============================================================================
-- [MS-MERCHANT] Chỉ mua loại decor chưa có trên kệ lẫn trong kho, giữ tiền nhà.
local function ownedDecor(c)
    local owned={}
    -- Đồ khóa cũng đã thuộc người chơi: không mua trùng chỉ vì chưa được đặt.
    for _,item in pairs(inventory(c.data,"Misc")) do
        if item.id and (item._am or 1)>0 then owned[item.id]=true end
    end
    for _,id in pairs(c.plot:Save("Plinths") or {}) do
        if type(id)=="string" then owned[id]=true end
    end
    return owned
end
local function merchantChoice(c,shelf)
    if type(shelf)~="table" or type(shelf.Offers)~="table" or type(shelf.Seed)~="number" then return end
    local reserve=0
    if enabled("EventStoreAutoLevel") and c.level<#c.api.definitions.LEVELS then
        reserve=c.api.buttons.Price(c.level+1) or 0
    end
    local owned=ownedDecor(c)
    local best
    for slot,offer in pairs(shelf.Offers) do
        local item,price=offer.ItemData,offer.PriceData
        local id=item and item.data and item.data.id
        local money=price and price.data
        if tonumber(slot) and offer.Stock and offer.Stock>0 and item and item.class=="Misc"
            and c.api.decorDefs.Piece(id) and not owned[id]
            and price and price.class=="Currency" and money and money.id=="MysteryStoreCoins" then
            local cost=money._am or 1
            local value=c.api.decor.Value(id) or 0
            if cost>0 and cost<=math.max(0,c.coins-reserve) and (not best or value>best.value) then
                best={kind="merchant",key="merchant:"..shelf.Seed..":"..slot,slot=tonumber(slot),
                    seed=shelf.Seed,id=id,stock=offer.Stock,before=amount(c.data,"Misc",id),cost=cost,value=value}
            end
        end
    end
    return best
end
local function merchantStep(c)
    local flag="EventStoreAutoMerchant"
    if not enabled(flag) or lease or os.clock()<(controller.nextOffers or 0) then return false end
    if not controller.merchantConnection then
        controller.merchantConnection=c.api.network.Fired("Merchant_Updated"):Connect(function(offers)
            if controller.active and type(offers)=="table" then controller.offers=offers;controller.nextOffers=0 end
        end)
    end
    if os.clock()>=(controller.fetchOffersAt or 0) then
        controller.fetchOffersAt=os.clock()+15
        local ok,result=pcall(c.api.network.Invoke,"Merchant_GetOffers")
        if not valid(c,flag) then return false end
        if ok and type(result)=="table" then controller.offers=result end
    end
    local shelf=controller.offers and controller.offers.MysteryStoreDecorMerchant
    if not shelf then
        -- Một số server chỉ gửi offers sau khi quầy ở gần được đăng ký.
        local moved=approach(c,flag,machineSpot(c,"MysteryStoreDecorMerchant"))
        local owned=lease
        if moved then task.wait(0.5) end
        if owned and owned.flag==flag then releaseLease(owned) end
        controller.nextOffers=os.clock()+15
        report("merchant","Đang chờ danh sách hàng và seed do game gửi.")
        return moved
    end
    local choice=merchantChoice(c,shelf)
    if not choice then controller.nextOffers=os.clock()+3;return false end
    return dispatch(c,flag,choice,function(f)
        return f.api.network.Invoke("Merchant_RequestPurchase","MysteryStoreDecorMerchant",choice.slot,false,choice.seed)
    end,function(f)
        local current=controller.offers and controller.offers.MysteryStoreDecorMerchant
        local offer=current and current.Offers and current.Offers[tostring(choice.slot)]
        local reserve=enabled("EventStoreAutoLevel") and f.level<#f.api.definitions.LEVELS
            and (f.api.buttons.Price(f.level+1) or 0) or 0
        local item=offer and offer.ItemData
        return current and current.Seed==choice.seed and offer and offer.Stock>0
            and item and item.class=="Misc" and item.data and item.data.id==choice.id
            and not ownedDecor(f)[choice.id] and f.coins-reserve>=choice.cost
    end,machineSpot(c,"MysteryStoreDecorMerchant"))
end

-- ============================================================================
-- [MS-GIFT] Worker riêng; giữ animation gốc, chỉ mở Squishy Gift trong Lootbox.
local function giftStep(c)
    local flag="EventStoreAutoGift"
    if not enabled(flag) or waiting("gift",c) then return end
    for uid,item in pairs(inventory(c.data,"Lootbox")) do
        if item.id=="Squishy Gift" and not item._lk then
            local p={kind="gift",key="gift:"..uid,uid=uid,id=item.id,before=item._am or 1}
            local count=math.min(8,p.before)
            return dispatch(c,flag,p,function(f)
                for _,candidate in pairs(f.api.items.Lootbox("Squishy Gift"):FindAny() or {}) do
                    if candidate:GetUID()==uid and not candidate:IsLocked() then return f.api.lootbox.Open(candidate,count) end
                end
                return false,"Stack quà chưa sẵn sàng."
            end,function(f)
                local current=inventory(f.data,"Lootbox")[uid]
                return current and current.id==p.id and not current._lk and (current._am or 1)>=count
            end,c.api.base.ZoneLanding(c.plot),false,"gift")
        end
    end
end

-- ============================================================================
-- [MS-BOOST] Dùng hết mọi cấp boost event, không đọc thời gian hiệu ứng đang có.
local function boostStep(c)
    local flag="EventStoreAutoBoost"
    if not enabled(flag) or waiting("boost",c) then return end
    local allowed={}
    for _,id in pairs(c.api.boostDefs.ITEMS) do allowed[id]=true end
    local candidates={}
    for uid,item in pairs(inventory(c.data,"Consumable")) do
        if allowed[item.id] and not item._lk and (item._am or 1)>0 then
            candidates[#candidates+1]={uid=uid,id=item.id,before=item._am or 1,tier=item.tn or 1}
        end
    end
    table.sort(candidates,function(a,b)
        if a.tier~=b.tier then return a.tier>b.tier end
        return tostring(a.uid)<tostring(b.uid)
    end)
    session.boostBatch=session.boostBatch or {}
    for _,p in ipairs(candidates) do
        if not valid(c,flag) then return end
        p.kind="boost";p.key="boost:"..p.uid
        if os.clock()<(session.nextAt[p.key] or 0) then continue end
        local count=math.min(p.before,session.boostBatch[p.uid] or p.before)
        local sent=dispatch(c,flag,p,function(f)
            for _,item in pairs(f.api.items.Consumable(p.id):FindAny() or {}) do
                if item:GetUID()==p.uid and not item:IsLocked() then
                    local accepted,message=f.api.consumables.Consume(item,count)
                    if accepted==false then
                        -- Server từ chối lô lớn: thử lô nhỏ hơn sau cooldown, vẫn dùng tới hết.
                        session.boostBatch[p.uid]=math.max(1,math.floor(count/2))
                    end
                    return accepted,message
                end
            end
            return false,"Stack boost chưa sẵn sàng."
        end,function(f)
            local item=inventory(f.data,"Consumable")[p.uid]
            return item and item.id==p.id and not item._lk and (item._am or 1)>=count
        end,nil,false,"boost")
        if sent then return end
    end
end

-- ============================================================================
-- [MS-FARM] Giữ mục tiêu sống, chia pet/bulk; chỉ AreaID thuộc plot của mình.
local function clearFarm()
    if dependencies then
        for _,pet in pairs(dependencies.playerPet.GetByPlayer(dependencies.player) or {}) do
            local uid=pet.euid and assigned[pet.euid]
            if uid and pet:GetTargetType()=="Breakable" and pet:GetTargetValue()==uid then pet:ClearTarget() end
        end
    end
    table.clear(assigned)
end
local function farmTargets(c)
    local things=workspace:FindFirstChild("__THINGS")
    local folder=things and things:FindFirstChild("Breakables")
    local result={}
    if not folder then return result end
    for _,model in ipairs(folder:GetChildren()) do
        if model:GetAttribute("ParentType")==c.api.instanceParent and model:GetAttribute("ParentID")=="MysteryStore"
            and model:GetAttribute("AreaID")=="MysteryStoreZone_"..c.scope then
            local uid=model:GetAttribute("BreakableUID")
            local data=uid and c.api.breaks.Get(uid)
            if data and data.health>0 and not data.disableDamage then result[#result+1]={uid=uid,health=data.health} end
        end
    end
    table.sort(result,function(a,b)
        if a.health~=b.health then return a.health<b.health end
        return tostring(a.uid)<tostring(b.uid)
    end)
    return result
end
local function farmStep(c)
    if not enabled("EventStoreFastFarm") then return end
    if controller.farmScope~=c.scope then clearFarm();controller.farmScope=c.scope end
    local now=os.clock()
    if now<(controller.nextTargets or 0) then return end
    controller.nextTargets=now+0.12
    if now>=(controller.nextEquip or 0) then c.api.pets.EquipBest();controller.nextEquip=now+15 end
    if not valid(c,"EventStoreFastFarm") then return end
    local targets=farmTargets(c)
    if #targets==0 then clearFarm();return end
    local counts,eligible,new={},{},{}
    for _,target in ipairs(targets)do eligible[target.uid]=true end
    local idle={}
    for _,pet in pairs(c.api.playerPet.GetByPlayer(c.api.player) or {})do
        local id=pet.euid
        if id then
            local uid=assigned[id]
            if uid and eligible[uid] then new[id]=uid;counts[uid]=(counts[uid] or 0)+1 else idle[#idle+1]=id end
        end
    end
    for _,id in ipairs(idle)do
        local best=targets[1].uid
        for _,target in ipairs(targets)do if (counts[target.uid] or 0)<(counts[best] or 0)then best=target.uid end end
        new[id]=best;counts[best]=(counts[best] or 0)+1
    end
    local changed=false
    for id,uid in pairs(new)do if assigned[id]~=uid then changed=true;break end end
    assigned=new
    if not valid(c,"EventStoreFastFarm") then return end
    if next(new) and (changed or now>=(controller.nextBulk or 0))then
        c.api.network.Fire("Breakables_JoinPetBulk",new);controller.nextBulk=now+1
    end
    c.api.network.UnreliableFire("Breakables_PlayerDealDamage",targets[1].uid)
end

-- ============================================================================
-- [MS-OPTIMIZE] Giảm công tạo/animate model và FX, phần Super Optimize chưa chặn.
-- Không sửa save, mạng, customers metadata, máy/pad, collision hoặc cách tính reward.
local visualEdits={}
local visualInstalled=false
local function restoreVisuals()
    for index=#visualEdits,1,-1 do
        local edit=visualEdits[index]
        -- Không ghi đè patch mới của script khác khi người dùng tắt/reload.
        if edit.object[edit.key]==edit.applied then
            local ok,problem=pcall(function()edit.object[edit.key]=edit.original end)
            if not ok then report("optimize",problem) end
        end
    end
    table.clear(visualEdits)
    visualInstalled=false
    controller.optimizeCount=0
end
local function installVisuals()
    if visualInstalled then return end
    local a=api()
    local function patch(object,key,value)
        if type(object)~="table" or object[key]==nil then return end
        local original=object[key]
        local ok,problem=pcall(function()object[key]=value end)
        if ok then visualEdits[#visualEdits+1]={object=object,key=key,original=original,applied=value}
        else report("optimize",problem) end
    end
    local function cosmetic(object,key,zero)
        local original=object and object[key]
        if type(original)~="function" then return end
        patch(object,key,function(...)
            if enabled("EventStoreOptimize") and a.instancing.GetInstanceID()=="MysteryStore" then
                if zero then return 0 end
                return
            end
            return original(...)
        end)
    end
    local function feature(name)
        local ok,value=pcall(a.store.Feature,name)
        if ok then return value end
        report("optimize:"..name,value)
        return nil
    end
    local rigs=feature("Rigs")
    cosmetic(rigs,"OnScreen",true)
    cosmetic(rigs,"DrawDistance",true)
    cosmetic(rigs,"AnimDistance",true)
    patch(rigs,"MAX_PINS",0)
    local customers=feature("Customers")
    patch(customers,"PINNED",{})
    patch(customers,"SELECT_EVERY",1)
    patch(customers,"SELECT_BACKLOG",1)
    -- Giữ callback mạng gốc; chỉ bỏ phần tạo mô hình/hoạt ảnh phía client.
    local swap=feature("Swap")
    cosmetic(swap,"Play")
    cosmetic(swap,"PlayChase")
    patch(feature("BoxDropFx"),"MAX_ALIVE",0)
    local decor=feature("DecorFx")
    cosmetic(decor,"Placed")
    cosmetic(decor,"ChipChanged")
    cosmetic(feature("LevelFx"),"LevelUp")
    local boost=feature("BoostFx")
    for _,key in ipairs({"Pulse","Flash","TierThree","Expired"})do cosmetic(boost,key)end
    cosmetic(feature("Upgrades"),"FXScale",true)
    controller.optimizeCount=#visualEdits
    visualInstalled=true
end

-- ============================================================================
-- [MS-WORKERS] Main tuần tự; farm/gift/boost riêng, không bị animation giữ vòng chính.
local function mainStep(c)
    if waiting("main",c) or lease then return end
    if levelStep(c) or registerStep(c) or decorStep(c) or combineStep(c) or merchantStep(c) or stockStep(c) then return end
    if enabled("EventStoreFastFarm") and not lease and not c.api.pad.OnPad() then
        local landing=c.api.base.ZoneLanding(c.plot)
        if landing and (c.root.Position-landing.Position).Magnitude>12 then
            local ok=approach(c,"EventStoreFastFarm",landing)
            local owned=lease
            if ok and owned then owned.back=landing end
            if owned then releaseLease(owned) end
        end
    end
end
local function anyEnabled()
    -- Optimize đơn lẻ không tạo 4 worker auto hoặc đọc Save liên tục.
    for flag,on in pairs(controller.flags)do if flag~="EventStoreOptimize" and on then return true end end
    return false
end
local function stopJobs()
    for _,job in pairs(controller.jobs)do pcall(task.cancel,job)end
    table.clear(controller.jobs)
    if controller.merchantConnection then controller.merchantConnection:Disconnect();controller.merchantConnection=nil end
    pcall(releaseLease)
    pcall(clearFarm)
end
controller.Stop=function()
    controller.active=false
    if controller.entryJob then pcall(task.cancel,controller.entryJob);controller.entryJob=nil end
    stopJobs();restoreVisuals()
end
-- Một luồng vào event dùng chung, kể cả khi chỉ bật Optimize từ launcher.
local function ensureEntry()
    if controller.entryJob then return end
    controller.entryJob=task.defer(function()
        local nextAttempt=0
        while controller.active do
            local wanted=false
            for _,on in pairs(controller.flags)do if on then wanted=true;break end end
            if not wanted then break end
            local ok,problem=pcall(function()
                local library=game:GetService("ReplicatedStorage"):FindFirstChild("Library")
                local client=library and library:FindFirstChild("Client")
                local module=client and client:FindFirstChild("InstancingCmds")
                if not module then return end
                local instancing=require(module)
                if not controller.active then return end
                local stillWanted=false
                for _,on in pairs(controller.flags)do if on then stillWanted=true;break end end
                if not stillWanted or instancing.GetInstanceID()=="MysteryStore" or os.clock()<nextAttempt then return end
                nextAttempt=os.clock()+10
                if instancing.DoesMeetRequirement("MysteryStore") then
                    instancing.Enter("MysteryStore")
                end
            end)
            if not ok then report("entry",problem) end
            task.wait(1)
        end
        controller.entryJob=nil
    end)
end
local function worker(name,delay,step)
    controller.jobs[name]=task.defer(function()
        while controller.active and anyEnabled() do
            local ok,problem=pcall(function()
                local c=context()
                if c then step(c) elseif name=="farm" then clearFarm() end
            end)
            if not ok then
                if lease and lease.flag~="EventStoreAutoGift" and name=="main"
                    or lease and lease.flag=="EventStoreAutoGift" and name=="gift" then pcall(releaseLease) end
                report(name,problem)
            else report(name,nil) end
            task.wait(ok and delay or 2)
        end
    end)
end
local function setToggle(flag,on,shared)
    if not controller.active then return end
    controller.flags[flag]=on==true
    controller.shared=shared or controller.shared
    if on then ensureEntry() end
    if flag=="EventStoreOptimize" then
        if on then
            local ok,problem=pcall(installVisuals)
            if not ok then restoreVisuals();report("optimize",problem) end
        else restoreVisuals() end
        return
    end
    if not on then
        if flag=="EventStoreFastFarm" then pcall(clearFarm) end
        if lease and lease.flag==flag then pcall(releaseLease) end
        if flag=="EventStoreAutoMerchant" and controller.merchantConnection then
            controller.merchantConnection:Disconnect();controller.merchantConnection=nil
        end
    end
    if not anyEnabled() then stopJobs();return end
    if not next(controller.jobs) then
        worker("main",0.25,mainStep)
        worker("farm",0.12,farmStep)
        worker("gift",1,giftStep)
        worker("boost",0.5,boostStep)
    end
end
controller.Status=function()
    local flags={}
    for flag,on in pairs(controller.flags)do flags[flag]=on end
    local keep={}
    for id,count in pairs(boxKeep) do keep[id]=count end
    return {active=controller.active,flags=flags,movement=movement.mode,keepBoxes=keep,moving=lease and lease.flag,
        optimizePatches=controller.optimizeCount or 0,
        pending=session.pending,errors=controller.errors}
end
local function configure(settings)
    if not controller.active then return end
    settings=settings or {}
    assert(type(settings)=="table","eventStore cần là bảng cấu hình")
    local mode=settings.movement or movement.mode
    assert(mode=="teleport" or mode=="walk","eventStore.movement cần là teleport hoặc walk")
    local timeout=tonumber(settings.walkTimeout) or movement.timeout
    assert(timeout>=5 and timeout<=180,"eventStore.walkTimeout cần từ5 tới180giây")
    local keep={}
    for id,count in pairs(boxKeep) do keep[id]=count end
    if settings.keepBoxes~=nil then
        assert(type(settings.keepBoxes)=="table","eventStore.keepBoxes cần là bảng số lượng giữ")
        for id,value in pairs(settings.keepBoxes) do
            assert(boxKeep[id]~=nil,"keepBoxes chỉ hỗ trợ MysteryStore Box 3 và MysteryStore Box 4")
            local count=tonumber(value)
            assert(count and count>=0 and count<math.huge and count==math.floor(count),"Số hộp giữ cần là số nguyên >=0")
            keep[id]=count
        end
    end
    movement.version+=1
    movement.mode, movement.timeout=mode,timeout
    boxKeep=keep
    if lease then releaseLease() end
end
controller.Configure=configure
features.EventStoreSettings={configure=configure}

-- ============================================================================
-- [MS-EXPORT] Callback chung cho UI và launcher; không tự bật khi load.
for _,flag in ipairs({"EventStoreFastFarm","EventStoreAutoRegister","EventStoreAutoLevel","EventStoreAutoDecor",
    "EventStoreAutoStock","EventStoreAutoGift","EventStoreAutoMerchant","EventStoreAutoCombine","EventStoreAutoBoost","EventStoreOptimize"}) do
    features[flag]={duy=function(on,shared)setToggle(flag,on,shared)end}
end
return features
