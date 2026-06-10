-- ============================================================
--  witherhook // Games/106131416903029.lua   (Cook & Sell!)
--  Loads the shared shell (main.lua) then adds the Cook & Sell tab:
--  auto-add ingredients + auto-claim dessert. Finds your plot by the
--  shop name label, fires the plot's CookingPotServerModel.Remote.
-- ============================================================
local ctx = ({ ... })[1]
ctx.load("Games/main.lua")(ctx)

local api = ctx.api
if not api then return end

local Window  = ctx.window
local library = ctx.library
local notify  = api.notify
local regToggle, regSlider, regDecimal = api.regToggle, api.regSlider, api.regDecimal

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local lplr      = Players.LocalPlayer

do
    local addActive, claimActive = false, false
    local addDelay = 0.1
    local cachedPlot

    -- ---- find MY plot by its "<username>'s Shop" label ----
    local function findMyPlot()
        local plots = Workspace:FindFirstChild("Plots")
        if not plots then return nil end
        local name = lplr.Name:lower()
        local disp = (lplr.DisplayName or lplr.Name):lower()
        for _, plot in ipairs(plots:GetChildren()) do
            local lbl = plot:FindFirstChild("ShopNameDisplay")
            lbl = lbl and lbl:FindFirstChild("BillboardGui")
            lbl = lbl and lbl:FindFirstChild("Frame")
            lbl = lbl and lbl:FindFirstChild("TextLabel")
            if lbl and lbl:IsA("TextLabel") then
                local txt = lbl.Text:lower()
                if txt ~= "" and (txt:find(name, 1, true) or txt:find(disp, 1, true)) then
                    return plot
                end
            end
        end
        return nil
    end
    local function myPlot()
        if cachedPlot and cachedPlot.Parent then return cachedPlot end
        cachedPlot = findMyPlot()
        return cachedPlot
    end
    local function getRemote()
        local p = myPlot(); if not p then return nil end
        local sm = p:FindFirstChild("CookingPotServerModel")
        return sm and sm:FindFirstChild("Remote")
    end

    -- ---- auto add: empty SpawnedIngredients into the pot by Name ----
    local function startAdd()
        if addActive then return end
        addActive = true
        if not myPlot() then notify("Cook&Sell: couldn't find your shop plot", 4, "alert") end
        task.spawn(function()
            while addActive and not library.Unloaded do
                local p      = myPlot()
                local remote = getRemote()
                local spawned = p and p:FindFirstChild("SpawnedIngredients")
                if remote and spawned then
                    for _, child in ipairs(spawned:GetChildren()) do
                        if not addActive or library.Unloaded then break end
                        if child and child.Parent and child.Name ~= "" then
                            pcall(function() remote:FireServer("AddIngredient", child.Name) end)
                            pcall(function() child:Destroy() end)
                            if addDelay > 0 then task.wait(addDelay) end
                        end
                    end
                end
                task.wait(0.1)
            end
            addActive = false
        end)
    end
    local function stopAdd() addActive = false end

    -- ---- auto claim: match client model by Base CFrame, claim when ready ----
    local function findMyClient(serverBase)
        if not serverBase then return nil end
        local target = serverBase.Position
        local best, bestD
        for _, m in ipairs(Workspace:GetDescendants()) do
            if m:IsA("Model") and m.Name == "CookingPotClientModel" then
                local b = m:FindFirstChild("Base", true)
                if b and b:IsA("BasePart") then
                    local d = (b.Position - target).Magnitude
                    if not bestD or d < bestD then best, bestD = m, d end
                end
            end
        end
        if best and bestD and bestD < 5 then return best end
        return nil
    end
    local function startClaim()
        if claimActive then return end
        claimActive = true
        task.spawn(function()
            local client
            while claimActive and not library.Unloaded do
                local p  = myPlot()
                local sm = p and p:FindFirstChild("CookingPotServerModel")
                local serverBase = sm and sm:FindFirstChild("Base", true)
                local remote     = sm and sm:FindFirstChild("Remote")
                -- re-resolve the client model if our cached one is stale
                local valid = client and client.Parent and serverBase
                if valid then
                    local b = client:FindFirstChild("Base", true)
                    valid = b and (b.Position - serverBase.Position).Magnitude < 5
                end
                if not valid then client = findMyClient(serverBase) end
                if client and remote then
                    local ct  = client:FindFirstChild("CookingTime", true)
                    local cap = ct and ct:FindFirstChild("Caption", true)
                    if cap and cap:IsA("TextLabel") then
                        local t = cap.Text:gsub("<[^>]+>", "")
                        if t:lower():find("ready to serve", 1, true) then
                            pcall(function() remote:FireServer("ClaimDessert") end)
                        end
                    end
                end
                task.wait(0.5)
            end
            claimActive = false
        end)
    end
    local function stopClaim() claimActive = false end

    -- ---- auto place: drop held/finished tools onto empty counter slots ----
    local placeActive = false
    local function getPlaceRemote()
        local rs      = game:GetService("ReplicatedStorage")
        local riese   = rs:FindFirstChild("Riese")
        local remotes = riese and riese:FindFirstChild("Remotes")
        return remotes and remotes:FindFirstChild("PlaceDownItem")
    end
    -- first counter slot (a numbered model) whose Taken attribute is false
    local function findEmptySlot()
        local p = myPlot()
        local counters = p and p:FindFirstChild("Counters")
        if not counters then return nil end
        for _, counter in ipairs(counters:GetChildren()) do
            if counter:IsA("Model") then
                for _, slot in ipairs(counter:GetChildren()) do
                    local num = tonumber(slot.Name)   -- the "1" / "2" ... models
                    if num and slot:GetAttribute("Taken") == false then
                        return counter, num
                    end
                end
            end
        end
        return nil
    end
    -- tools the player currently holds (equipped in character + in backpack)
    local function heldTools()
        local out = {}
        local char = lplr.Character
        if char then for _, c in ipairs(char:GetChildren()) do if c:IsA("Tool") then out[#out + 1] = c end end end
        local bp = lplr:FindFirstChild("Backpack")
        if bp   then for _, c in ipairs(bp:GetChildren())   do if c:IsA("Tool") then out[#out + 1] = c end end end
        return out
    end
    local function startPlace()
        if placeActive then return end
        placeActive = true
        task.spawn(function()
            while placeActive and not library.Unloaded do
                local remote = getPlaceRemote()
                if remote then
                    for _, tool in ipairs(heldTools()) do
                        if not placeActive then break end
                        local counter, num = findEmptySlot()
                        if counter and num and tool.Parent then
                            -- PlaceDownItem(tool, counterModel, slotNumber)
                            pcall(function() remote:FireServer(tool, counter, num) end)
                            task.wait(0.25)   -- let Taken + the tool's location update
                        end
                    end
                end
                task.wait(0.2)
            end
            placeActive = false
        end)
    end
    local function stopPlace() placeActive = false end

    -- ---- UI ----
    local Cook = Window:NewTab("Cook & Sell")
    Cook:NewSection("Auto cook")
    regToggle(Cook, "CSAutoAdd", "Auto add ingredients", false, function(v)
        if v then startAdd() else stopAdd() end
    end)
    -- shown in ms (1-60), applied to addDelay in seconds
    regDecimal(Cook, "CSAddDelay", "Add delay", " ms", 0.001, 0.06, 0.01, 1000, function(v) addDelay = v end)
    regToggle(Cook, "CSAutoClaim", "Auto claim dessert", false, function(v)
        if v then startClaim() else stopClaim() end
    end)
    regToggle(Cook, "CSAutoPlace", "Auto place finished items", false, function(v)
        if v then startPlace() else stopPlace() end
    end)
end

-- shared witherhook tabs below
api.buildShared()
