-- WoWFlips - Scanner.lua
-- Implementado por El Picador de Código.
-- Quick Scan (wishlist) + Category Scan, rate-limiting, máquina de estados, caché fría.

Scanner = Scanner or {}

-- Constantes §7
Scanner.MIN_INTERVAL_QUICK = 0.6
Scanner.MIN_INTERVAL_CATEGORY = 1.0
Scanner.TIMEOUT_PER_QUERY = 10
Scanner.MAX_RETRIES = 1

Scanner.state = {
  mode = nil, running = false, queue = {}, index = 0, pending = nil,
  lastQuery = nil, deferred = nil, page = nil, hasMore = false, timeoutHandle = nil,
  -- internos
  retries = 0, backoff = 1, maxCap = {}, browseQueue = {}, browseIndex = 0,
  rateTimer = nil, dispatchTimer = nil, itemKey = nil, paging = false,
}

-- ------------------------------------------------------------------
-- Eventos de búsqueda (defensivo: existen en 12.x)
-- ------------------------------------------------------------------
local scanEvents = CreateFrame("Frame")
local function OnScanEvent(self, event, ...)
  local a = select(1, ...)
  if event == "COMMODITY_SEARCH_RESULTS_ADDED" or event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if type(a) == "number" then Scanner.OnCommodityResults(a) end
  elseif event == "ITEM_SEARCH_RESULTS_ADDED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
    if type(a) == "table" then Scanner.OnItemResults(a) end
  elseif event == "ITEM_DATA_LOAD_RESULT" then
    if type(a) == "number" then Scanner.OnItemDataLoad(a, select(2, ...)) end
  end
end
scanEvents:SetScript("OnEvent", OnScanEvent)
local scanEvts = {
  "COMMODITY_SEARCH_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_DATA_LOAD_RESULT",
}
for _, ev in ipairs(scanEvts) do
  if _G[ev] then scanEvents:RegisterEvent(ev) end
end
Scanner.scanEvents = scanEvents

-- ------------------------------------------------------------------
-- Lifecycle
-- ------------------------------------------------------------------
function Scanner.StartQuickScan()
  local st = Scanner.state
  local settings = Core.GetSettings()
  local wishlist = WoWFlipsDB.wishlist or {}
  local queue = {}
  st.maxCap = {}
  for i = 1, #wishlist do
    local e = wishlist[i]
    if e and type(e.itemID) == "number" then
      queue[#queue + 1] = e.itemID
      if e.maxCapCobre ~= nil then st.maxCap[e.itemID] = e.maxCapCobre end
    end
  end
  st.mode = "quick"
  st.running = true
  st.queue = queue
  st.index = 1
  st.pending = nil
  st.lastQuery = nil
  st.retries = 0
  st.backoff = 1
  st.hasMore = false
  st.page = nil
  st.timeoutHandle = nil
  st.rateTimer = nil
  st.dispatchTimer = nil
  st.browseQueue = {}
  st.browseIndex = 0
  st.itemKey = nil
  if UI and type(UI.UpdateProgress) == "function" then UI.UpdateProgress("Quick Scan — 0/" .. #queue) end
  Scanner.ProcessNext()
end

function Scanner.StartCategoryScan(browseQuery)
  if type(browseQuery) ~= "string" or browseQuery == "" then return end
  local st = Scanner.state
  st.mode = "category"
  st.running = true
  st.queue = {}
  st.index = 0
  st.pending = nil
  st.lastQuery = nil
  st.retries = 0
  st.backoff = 1
  st.hasMore = false
  st.page = nil
  st.timeoutHandle = nil
  st.rateTimer = nil
  st.dispatchTimer = nil
  st.browseQueue = {}
  st.browseIndex = 0
  st.itemKey = nil
  local AH = _G.C_AuctionHouse
  if AH and type(AH.SendBrowseQuery) == "function" then
    -- Firma moderna: AuctionHouseBrowseQuery; fallback a string/struct (defensivo).
    if not pcall(AH.SendBrowseQuery, { query = browseQuery }) then
      pcall(AH.SendBrowseQuery, browseQuery)
    end
  end
  if UI and type(UI.UpdateProgress) == "function" then UI.UpdateProgress("Category Scan") end
end

function Scanner.StopScan()
  local st = Scanner.state
  st.running = false
  st.mode = nil
  st.pending = nil
  st.timeoutHandle = nil
  st.rateTimer = nil
  st.dispatchTimer = nil
  st.queue = {}
  st.index = 0
  st.lastQuery = nil
  st.retries = 0
  st.backoff = 1
  st.hasMore = false
  st.page = nil
  st.browseQueue = {}
  st.browseIndex = 0
  st.itemKey = nil
  if UI and type(UI.UpdateProgress) == "function" then UI.UpdateProgress("") end
end

function Scanner.IsRunning()
  return Scanner.state.running == true
end

function Scanner.GetProgress()
  local st = Scanner.state
  return { current = st.index, total = #st.queue, mode = st.mode }
end

-- ------------------------------------------------------------------
-- Quick Scan: state machine
-- ------------------------------------------------------------------
function Scanner.ProcessNext()
  local st = Scanner.state
  if not st.running then return end
  if st.mode == "quick" then
    local itemID = st.queue[st.index]
    if not itemID then Scanner.StopScan() return end
    if st.pending then return end
    local delay = 0
    if st.lastQuery then
      delay = Scanner.MIN_INTERVAL_QUICK - (GetTime() - st.lastQuery)
      local scanDelay = tonumber(Core.GetSettings().scanDelay) or 0.7
      if scanDelay > Scanner.MIN_INTERVAL_QUICK then
        delay = math.max(delay, scanDelay) -- respeta scanDelay > MIN (defaults: 0.7)
      end
    end
    if st.backoff > 1 then delay = math.max(delay, st.backoff) end
    if delay > 0 then
      st.rateTimer = C_Timer.After(delay, function() st.rateTimer = nil; Scanner.ProcessNext() end)
      return
    end
    Scanner.RequestCurrent()
  elseif st.mode == "category" then
    Scanner.DispatchBrowseNext()
  end
end

function Scanner.RequestCurrent()
  local st = Scanner.state
  local itemID = st.pending or st.queue[st.index]
  if not itemID then return end
  local AH = _G.C_AuctionHouse
  if not AH then Scanner.StopScan() return end
  st.pending = itemID
  st.lastQuery = GetTime()
  if Engine.IsCommodity(itemID) then
    Scanner.RequestCommoditySearch(itemID)
  else
    st.itemKey = Engine.MakeItemKey(itemID)
    Scanner.RequestItemSearch(st.itemKey)
  end
end

function Scanner.AdvanceQuickScan()
  local st = Scanner.state
  if st.mode ~= "quick" then return end
  st.index = st.index + 1
  st.lastQuery = GetTime()
  st.backoff = 1
  st.retries = 0
  st.pending = nil
  Scanner.ProcessNext()
end

function Scanner.OnCommodityResults(itemID)
  local st = Scanner.state
  if not (st and st.running and (st.pending == itemID or st.mode == "category")) then return end
  st.pending = nil
  st.timeoutHandle = nil
  Scanner.EvaluateItem(itemID, Scanner.GetScanResults(itemID))
end

function Scanner.OnItemResults(itemKey)
  local st = Scanner.state
  local itemID = itemKey and itemKey.itemID
  if not (st and st.running and (st.pending == itemID or st.mode == "category")) then return end
  st.pending = nil
  st.timeoutHandle = nil
  local results = Scanner.ReadItemSearchResults(itemKey)
  Scanner.EvaluateItem(itemID, results)
end

function Scanner.OnItemDataLoad(itemID, success)
  if not (success == true and itemID) then return end
  if not Scanner.state.running then return end
  Scanner.EvaluateItem(itemID, Scanner.GetScanResults(itemID))
end

function Scanner.EvaluateItem(itemID, results)
  local st = Scanner.state
  if not (st and st.running) then return nil end
  local settings = Core.GetSettings()
  local tier = Engine.GetAHTier()
  if not results then results = Scanner.GetScanResults(itemID) end
  local consensus = Engine.GetConsensusPrice(results, settings, itemID)
  local buyPrice = nil
  if consensus then
    local t = consensus.tiers.list[consensus.tiers.start]
    buyPrice = t and t.price or nil
    local cap = st.maxCap and st.maxCap[itemID]
    if type(cap) == "number" and consensus.price and consensus.price > cap then
      buyPrice = nil -- maxCapCobre: media de reventa por encima del cap del wishlist
    end
  end
  local opp = buyPrice and Engine.IsOpportunity(itemID, buyPrice, consensus, tier, settings)
                      or { isOpp = false, roiBPS = nil, rarity = nil, reason = "no_consensus", buyQty = 0 }
  if opp.isOpp and UI and type(UI.AddOpportunity) == "function" then
    local first = results and results[1]
    local entry = {
      itemID = itemID,
      isCommodity = Engine.IsCommodity(itemID),
      buyPrice = buyPrice,
      sellPrice = consensus and consensus.price,
      buyQty = opp.buyQty or 0,
      roiBPS = opp.roiBPS,
      rarity = opp.rarity,
      reason = opp.reason,
      tier = tier,
      source = st.mode,
      auctionID = first and first.auctionID or nil,
      buyoutPrice = first and first.unitPrice or buyPrice,
      listedAt = GetTime(),
    }
    UI.AddOpportunity(entry)
    if Core.IsReady and Core.IsReady() then
      Engine.UpdatePriceHistory(itemID, consensus, settings)
    end
  end
  if st.mode == "quick" then Scanner.AdvanceQuickScan() end
  if UI and type(UI.UpdateProgress) == "function" then
    UI.UpdateProgress(st.mode .. " — " .. st.index .. "/" .. #st.queue)
  end
  return opp
end

-- ------------------------------------------------------------------
-- Commodity search (defensivo: API moderna 12.x + fallback viejo)
-- ------------------------------------------------------------------
function Scanner.RequestCommoditySearch(itemID)
  local st = Scanner.state
  local AH = _G.C_AuctionHouse
  if not AH or type(itemID) ~= "number" then return end
  if st.timeoutHandle and st.timeoutHandle.Cancel then st.timeoutHandle:Cancel() end
  st.timeoutHandle = C_Timer.After(Scanner.TIMEOUT_PER_QUERY, function() Scanner.OnTimeout() end)
  if type(AH.RefreshCommoditySearchResults) == "function" then
    pcall(AH.RefreshCommoditySearchResults, itemID)
  elseif type(AH.RequestCommoditySearchResults) == "function" then
    pcall(AH.RequestCommoditySearchResults, itemID)
  end
end

function Scanner.RequestItemSearch(itemKey)
  local st = Scanner.state
  local AH = _G.C_AuctionHouse
  if not AH or not itemKey then return end
  if st.timeoutHandle and st.timeoutHandle.Cancel then st.timeoutHandle:Cancel() end
  st.timeoutHandle = C_Timer.After(Scanner.TIMEOUT_PER_QUERY, function() Scanner.OnTimeout() end)
  if type(AH.SendSearchQuery) == "function" then
    -- SendSearchQuery(itemKey, sorts, separateOwnerItems, minLevelFilter, maxLevelFilter)
    if not pcall(AH.SendSearchQuery, itemKey, {}, false) then
      pcall(AH.RequestItemSearchResults, itemKey) -- fallback viejo
    end
  elseif type(AH.RequestItemSearchResults) == "function" then
    pcall(AH.RequestItemSearchResults, itemKey)
  end
end

function Scanner.ReadCommodityResults(itemID)
  local AH = _G.C_AuctionHouse
  local results = {}
  if not AH or type(itemID) ~= "number" then return results end
  local n = 0
  if type(AH.GetNumCommoditySearchResults) == "function" then
    n = tonumber(AH.GetNumCommoditySearchResults(itemID)) or 0
  elseif type(AH.GetCommoditySearchResults) == "function" then
    -- fallback viejo (0..offset, local)
    local t = AH.GetCommoditySearchResults(itemID)
    if t then n = #t end
  end
  if type(AH.GetCommoditySearchResultInfo) == "function" then
    for i = 1, n do
      local r = AH.GetCommoditySearchResultInfo(itemID, i)
      if r then
        local p = tonumber(r.unitPrice)
        local q = tonumber(r.quantity)
        if p and p > 0 and q and q > 0 then
          results[#results + 1] = { unitPrice = p, quantity = q, auctionID = r.auctionID }
        end
      end
    end
  end
  return results
end

function Scanner.ReadItemSearchResults(itemKey)
  local AH = _G.C_AuctionHouse
  local results = {}
  if not AH or not itemKey then return results end
  local n = 0
  if type(AH.GetNumItemSearchResults) == "function" then
    n = tonumber(AH.GetNumItemSearchResults(itemKey)) or 0
  end
  if type(AH.GetItemSearchResultInfo) == "function" then
    for i = 1, n do
      local r = AH.GetItemSearchResultInfo(itemKey, i)
      if r then
        local p = tonumber(r.unitPrice or r.buyoutAmount or r.buyoutPrice or r.bidAmount or r.bidPrice or r.price)
        local q = tonumber(r.quantity)
        if p and p > 0 and q and q > 0 then
          results[#results + 1] = { unitPrice = p, quantity = q, auctionID = r.auctionID }
        end
      end
    end
  end
  return results
end

function Scanner.GetScanResults(itemID)
  local results = {}
  if not itemID then return results end
  if Engine.IsCommodity(itemID) then
    return Scanner.ReadCommodityResults(itemID)
  end
  local key = Scanner.state.itemKey or Engine.MakeItemKey(itemID)
  return Scanner.ReadItemSearchResults(key)
end

function Scanner.OnTimeout()
  local st = Scanner.state
  if not (st and st.running and st.pending) then return end
  st.retries = (st.retries or 0) + 1
  if st.retries > Scanner.MAX_RETRIES then
    st.pending = nil
    st.retries = 0
    st.backoff = 1
    if st.mode == "quick" then Scanner.AdvanceQuickScan() end
  else
    -- Backoff exponencial (x2, cap 8s) si throttle
    st.backoff = math.min((st.backoff or 1) * 2, 8)
    Scanner.RequestCurrent()
  end
end

-- ------------------------------------------------------------------
-- Browse: category scan
-- ------------------------------------------------------------------
function Scanner.OnBrowseResults(addedBrowseResults)
  local st = Scanner.state
  if not (st and st.running) then return end
  local added = addedBrowseResults or (_G.C_AuctionHouse and _G.C_AuctionHouse.GetBrowseResults() or {})
  local appended = 0
  for i = 1, #added do
    local r = added[i]
    if r and type(r.itemID) == "number" and r.itemID > 0 then
      st.browseQueue[#st.browseQueue + 1] = r.itemID
      appended = appended + 1
    end
  end
  st.hasMore = appended > 0
  st.paging = false
  st.page = #st.browseQueue
  if UI and type(UI.UpdateProgress) == "function" then
    UI.UpdateProgress("Category Scan — " .. st.browseIndex .. "/" .. #st.browseQueue)
  end
  Scanner.DispatchBrowseNext()
end

function Scanner.OnBrowseResultsUpdated()
  local st = Scanner.state
  if not (st and st.running and st.mode == "category") then return end
  Scanner.DispatchBrowseNext()
end

function Scanner.DispatchBrowseNext()
  local st = Scanner.state
  if not (st and st.running and st.mode == "category") then return end
  local itemID = st.browseQueue[st.browseIndex + 1]
  if not itemID then
    -- Paginamos: pedimos más resultados del browse (si hay pendientes)
    if st.hasMore and not st.paging then
      st.paging = true
      local AH = _G.C_AuctionHouse
      if AH and type(AH.RequestMoreBrowseResults) == "function" then
        AH.RequestMoreBrowseResults()
      end
    end
    return
  end
  -- Rate-limit de una página por evento
  local delay = 0
  if st.lastQuery then delay = Scanner.MIN_INTERVAL_CATEGORY - (GetTime() - st.lastQuery) end
  if delay > 0 then
    if not st.dispatchTimer then
      st.dispatchTimer = C_Timer.After(delay, function() st.dispatchTimer = nil; Scanner.DispatchBrowseNext() end)
    end
    return
  end
  st.browseIndex = st.browseIndex + 1
  st.lastQuery = GetTime()
  if Engine.IsCommodity(itemID) then
    Scanner.RequestCommoditySearch(itemID)
  else
    st.itemKey = Engine.MakeItemKey(itemID)
    Scanner.RequestItemSearch(st.itemKey)
  end
end

