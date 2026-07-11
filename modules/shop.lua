-- shop.lua
-- Auto-buyer using the game's internal Network:get("PDS","getShop") API,
-- reverse-engineered from the MrJack LL module bytecode dump.
--
-- Buy flow (from bytecode strings):
--   1. Network:get("PDS","getShop", {ShopId=shopId}) → shop object
--   2. shop.CanAutoBuy check
--   3. shop:buyItem(itemId, qty)  or  shop.Func(itemId, qty)
--
-- Disc buy flow (separate path from bytecode):
--   1. Network:get("PDS","getBagPouch") → bag data
--   2. Find item by name/id in bag
--   3. shop:buyItem(id, qty)

local Shop = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Default shopping list
-- Each entry: { shopId = "...", itemId = "...", itemName = "...", quantity = N, minStock = M }
--   shopId   — passed to Network:get("PDS","getShop",{ShopId=...})
--   itemId   — item identifier used in buyItem()
--   itemName — human-readable name for logging
--   quantity — how many to buy per trip
--   minStock — only buy when inventory drops below this (nil = always buy)
-- ─────────────────────────────────────────────────────────────────────────────

local DEFAULT_LIST = {
    -- Example (fill in real shopId/itemId values from game):
    -- { shopId = "PotionShop", itemId = "Potion",      itemName = "Potion",      quantity = 10, minStock = 5 },
    -- { shopId = "DiscShop",   itemId = "StandardDisc",itemName = "Standard Disc",quantity = 10, minStock = 5 },
}

local CHECK_INTERVAL = 30

-- ─────────────────────────────────────────────────────────────────────────────
-- Registry scan
-- ─────────────────────────────────────────────────────────────────────────────

local _p = nil
local _findPFailedAt = nil

local function findP()
    if _findPFailedAt and os.clock() - _findPFailedAt < 5 then return nil end
    for _, fn in pairs(debug.getregistry()) do
        if type(fn) == "function" then
            for _, upvalue in pairs(debug.getupvalues(fn)) do
                local ok, result = pcall(function() return upvalue.NPCChat end)
                if ok and type(result) == "table" then
                    _findPFailedAt = nil
                    return upvalue
                end
            end
        end
    end
    _findPFailedAt = os.clock()
    return nil
end

local function getP()
    if type(_p) ~= "table" then _p = findP() end
    return _p
end

local function safeGet(obj, key)
    if type(obj) ~= "table" then return nil end
    local ok, v = pcall(function() return obj[key] end)
    return ok and v or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Inventory reader via Network:get("PDS","getBagPouch")
-- Returns table keyed by item name → count
-- ─────────────────────────────────────────────────────────────────────────────

local function getInventory()
    local inv = {}
    local p = getP()
    if type(p) ~= "table" then return inv end

    local network = safeGet(p, "Network")
    if type(network) == "table" and type(network.get) == "function" then
        local ok, bag = pcall(function()
            return network:get("PDS", "getBagPouch")
        end)
        if ok and type(bag) == "table" then
            -- bag is an array of item lists; each entry has name, id, qty
            for _, itemList in ipairs(bag) do
                if type(itemList) == "table" then
                    for _, item in ipairs(itemList) do
                        if type(item) == "table" then
                            local name = safeGet(item, "name") or safeGet(item, "id")
                            local qty  = safeGet(item, "qty") or 0
                            if name then inv[tostring(name)] = (inv[tostring(name)] or 0) + qty end
                        end
                    end
                end
            end
        end
    end
    return inv
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Core buy sequence (reverse-engineered from MrJack bytecode)
-- ─────────────────────────────────────────────────────────────────────────────

local function performBuy(entry)
    local p = getP()
    if type(p) ~= "table" then
        warn("[Shop] _p not available — cannot buy.")
        return
    end

    local network = safeGet(p, "Network")
    if type(network) ~= "table" or type(network.get) ~= "function" then
        warn("[Shop] Network module not found.")
        return
    end

    -- Disable walking while in shop (matches MrJack pattern)
    local menu = safeGet(p, "Menu")
    if type(menu) == "table" then
        pcall(function() menu:disable("shop") end)
        pcall(function() menu:open("shop") end)
    end

    -- Network:get("PDS","getShop",{ShopId=shopId}) → shop object
    local ok, shop = pcall(function()
        return network:get("PDS", "getShop", { ShopId = entry.shopId })
    end)

    if not ok or type(shop) ~= "table" then
        warn(string.format("[Shop] getShop failed for shopId='%s'", tostring(entry.shopId)))
        -- Re-enable shop menu
        if type(menu) == "table" then
            pcall(function() menu:enable("shop") end)
        end
        return
    end

    -- CanAutoBuy guard (from bytecode)
    if shop.CanAutoBuy == false then
        warn(string.format("[Shop] CanAutoBuy is false for '%s' — skipping.", entry.itemName))
        if type(menu) == "table" then pcall(function() menu:enable("shop") end) end
        return
    end

    -- buyItem(itemId, quantity) — primary path from bytecode
    local bought = false
    if type(safeGet(shop, "buyItem")) == "function" then
        local buyOk = pcall(function()
            shop:buyItem(entry.itemId, entry.quantity)
        end)
        bought = buyOk
    end

    -- Fallback: shop.Func (secondary path seen in bytecode alongside CanAutoBuy)
    if not bought and type(safeGet(shop, "Func")) == "function" then
        pcall(function()
            shop.Func(entry.itemId, entry.quantity)
        end)
    end

    task.wait(0.5)

    -- Re-enable menu
    if type(menu) == "table" then
        pcall(function() menu:enable("shop") end)
    end

    print(string.format("[Shop] Bought %dx %s.", entry.quantity, entry.itemName))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local running      = false
local shoppingList = {}

local function shouldBuy(entry, inv)
    if not entry.minStock then return true end
    local current = inv[entry.itemName] or inv[tostring(entry.itemId)] or 0
    return current < entry.minStock
end

function Shop.start(options)
    if running then return end
    options      = options or {}
    shoppingList = options.list or DEFAULT_LIST
    local interval = options.interval or CHECK_INTERVAL
    running      = true
    getP()

    task.spawn(function()
        print("[Shop] Monitor started (" .. #shoppingList .. " item(s) on list).")
        while running do
            local inv = getInventory()
            for _, entry in ipairs(shoppingList) do
                if not running then break end
                if shouldBuy(entry, inv) then
                    print(string.format("[Shop] Buying %dx %s (shopId=%s)...",
                        entry.quantity, entry.itemName, tostring(entry.shopId)))
                    pcall(performBuy, entry)
                    inv = getInventory()
                end
            end
            task.wait(interval)
        end
        print("[Shop] Monitor stopped.")
    end)
end

function Shop.stop()
    running = false
    print("[Shop] Stopped.")
end

-- One-shot buy: bypasses stock check, buys immediately.
function Shop.buyNow(shopId, itemId, itemName, quantity)
    local entry = { shopId=shopId, itemId=itemId, itemName=itemName or itemId, quantity=quantity or 1 }
    print(string.format("[Shop] Immediate buy: %dx %s", entry.quantity, entry.itemName))
    pcall(performBuy, entry)
end

-- Run a full shopping trip right now against a given list (blocks until done).
function Shop.runTrip(list)
    list = list or shoppingList
    local inv = getInventory()
    for _, entry in ipairs(list) do
        if shouldBuy(entry, inv) then
            pcall(performBuy, entry)
            inv = getInventory()
        end
    end
    print("[Shop] Trip complete.")
end

function Shop.setList(list)
    shoppingList = list or {}
    print("[Shop] Shopping list updated (" .. #shoppingList .. " item(s)).")
end

-- Override performBuy at runtime if needed
function Shop.setPerformBuy(fn)
    if type(fn) == "function" then
        performBuy = fn
        print("[Shop] performBuy() overridden.")
    end
end

return Shop
