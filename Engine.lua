-- WoWFlips - Engine.lua
-- Implementado por El Picador de Código.
-- Finanzas en cobre entero (contrato §3 y §4). Lua 5.1: sin floats en dinero.

Engine = Engine or {}

-- ------------------------------------------------------------------
-- Constantes financieras (contrato §3)
-- ------------------------------------------------------------------
Engine.COPPER_PER_SILVER = 100
Engine.COPPER_PER_GOLD = 10000
Engine.COMMISSION_FACTION = 5
Engine.COMMISSION_NEUTRAL = 15
Engine.DEPOSIT_FACTION_PCT = 15
Engine.DEPOSIT_NEUTRAL_PCT = 75
Engine.FAILED_ATTEMPTS = { [0] = 0, [7] = 0, [2] = 2, [4] = 2 }
Engine.MIN_RO_NET_BPS = 1500

-- Default de settings cuando Core no está disponible.
Engine.DEFAULT_SETTINGS = {
  minROI = 15, scanDelay = 0.7, ahTierOverride = nil, maxBaitQty = 2,
  baitPriceRatio = 50, minListings = 5, minVolume = 10, historyCap = 50, timeoutSec = 10,
}

function Engine.GetSettings()
  if Core and type(Core.GetSettings) == "function" then
    local s = Core.GetSettings()
    if type(s) == "table" then return s end
  end
  return Engine.DEFAULT_SETTINGS
end

-- ------------------------------------------------------------------
-- AH Tier (faccion/neutral)
-- ------------------------------------------------------------------
function Engine.DetectAHTier()
  local settings = Engine.GetSettings()
  if settings and settings.ahTierOverride then
    Engine.AH_TIER = settings.ahTierOverride
    return Engine.AH_TIER
  end
  local AH = _G.C_AuctionHouse
  -- API explícita (defensivo)
  if AH and type(AH.GetHouseFactionID) == "function" then
    local fid = AH.GetHouseFactionID()
    if type(fid) == "number" and fid == 0 then
      Engine.AH_TIER = "neutral"
      return Engine.AH_TIER
    end
  end
  -- Heurística de zonas neutrales (defensivo)
  local UnitFactionGroup = _G.UnitFactionGroup
  if UnitFactionGroup and type(UnitFactionGroup) == "function" and UnitFactionGroup("target") == nil then
    Engine.AH_TIER = "neutral"
    return Engine.AH_TIER
  end
  Engine.AH_TIER = "faction"
  return Engine.AH_TIER
end

function Engine.GetAHTier() return Engine.AH_TIER or "faction" end

function Engine.GetCommissionRate(tier)
  if tier == "neutral" then return Engine.COMMISSION_NEUTRAL end
  return Engine.COMMISSION_FACTION
end

function Engine.GetDepositPct(tier)
  if tier == "neutral" then return Engine.DEPOSIT_NEUTRAL_PCT end
  return Engine.DEPOSIT_FACTION_PCT
end

-- ------------------------------------------------------------------
-- Financials (caché fría → diferir, sin dereferenciar nil)
-- ------------------------------------------------------------------
function Engine.RequestItemLoad(itemID)
  local C = _G.C_Item
  if C and type(C.RequestLoadItemDataByID) == "function" then
    pcall(C.RequestLoadItemDataByID, itemID)
  end
end

function Engine.GetFinancials(itemID)
  if type(itemID) ~= "number" or itemID <= 0 then return nil end
  local info = { GetItemInfo(itemID) } -- capturamos TODOS los returns (contracto: select(11)/select(12))
  if not info[1] then
    Engine.RequestItemLoad(itemID)
    return nil
  end
  local vendorSellPrice = tonumber(info[11])
  local classID = tonumber(info[12])
  if not vendorSellPrice and not classID then
    Engine.RequestItemLoad(itemID)
    return nil
  end
  return { vendorSellPrice = vendorSellPrice or 0, classID = classID or 0 }
end

function Engine.GetVendorSellPrice(itemID)
  local f = Engine.GetFinancials(itemID)
  if not f then return nil end
  return f.vendorSellPrice or 0
end

function Engine.GetClassID(itemID)
  local f = Engine.GetFinancials(itemID)
  if not f then return nil end
  return f.classID or 0
end

function Engine.GetFailedAttempts(classID)
  return Engine.FAILED_ATTEMPTS[classID] or 0
end

-- ------------------------------------------------------------------
-- Matemática financiera (contrato §4)
-- ------------------------------------------------------------------
function Engine.ComputeDepositCost(itemID, tier)
  local financials = Engine.GetFinancials(itemID)
  if not financials then return nil end
  local depositPer = math.floor(financials.vendorSellPrice * Engine.GetDepositPct(tier) / 100)
  local failed = Engine.GetFailedAttempts(financials.classID)
  return depositPer * (1 + failed)
end

function Engine.ComputeNetRevenue(sellPriceCopper, tier)
  local commission = Engine.GetCommissionRate(tier)
  return math.floor(sellPriceCopper * (100 - commission) / 100)
end

function Engine.ComputeTotalCost(buyPriceCopper, itemID, tier)
  if type(buyPriceCopper) ~= "number" then return nil end
  local financials = Engine.GetFinancials(itemID)
  if not financials then return nil end
  local depositCost = Engine.ComputeDepositCost(itemID, tier)
  if not depositCost then return nil end
  return buyPriceCopper + depositCost
end

function Engine.ComputeROI(buyPriceCopper, sellPriceCopper, itemID, tier)
  if type(buyPriceCopper) ~= "number" or type(sellPriceCopper) ~= "number" then return nil end
  local totalCost = Engine.ComputeTotalCost(buyPriceCopper, itemID, tier)
  if not totalCost or totalCost <= 0 then return nil end
  local commission = Engine.GetCommissionRate(tier)
  local numerator = (sellPriceCopper * (100 - commission) - totalCost * 100) * 100
  return math.floor(numerator / totalCost)
end

function Engine.ComputeBreakeven(buyPriceCopper, itemID, tier)
  if type(buyPriceCopper) ~= "number" then return nil end
  local totalCost = Engine.ComputeTotalCost(buyPriceCopper, itemID, tier)
  if not totalCost or totalCost <= 0 then return nil end
  local commission = Engine.GetCommissionRate(tier)
  -- C4: precio mínimo de venta para ROI >= 15% (115 = 100% costo + 15% ROI; ceil
  -- garantiza el umbral). math.ceil siempre produce entero representable.
  return math.ceil(totalCost * 115 / (100 - commission))
end

-- ------------------------------------------------------------------
-- Rareza
-- ------------------------------------------------------------------
function Engine.ClassifyRarity(roiBPS)
  if not roiBPS or roiBPS < Engine.MIN_RO_NET_BPS then return nil end
  if roiBPS < 2500 then return "green" end
  if roiBPS < 4500 then return "blue" end
  if roiBPS < 7500 then return "purple" end
  return "orange"
end

function Engine.GetRarityColor(roiBPS)
  if not Engine.ClassifyRarity(roiBPS) then return nil end
  if roiBPS < 2500 then return "|cff1eff00" end
  if roiBPS < 4500 then return "|cff0070dd" end
  if roiBPS < 7500 then return "|cffa335ee" end
  return "|cffff8000"
end

-- ------------------------------------------------------------------
-- Consenso anti-bait
-- results = { {unitPrice=cobre, quantity=n}, ... }
-- Devuelve { price, volume, confidence, baitExcluded, anomaly, tiers }
-- ------------------------------------------------------------------
function Engine.GetConsensusPrice(results, settings, itemID)
  local s = (type(settings) == "table") and settings or Engine.GetSettings()

  local tiers = {}
  local totalQty = 0
  if type(results) == "table" then
    for i = 1, #results do
      local r = results[i]
      if r then
        local p = tonumber(r.unitPrice)
        local q = tonumber(r.quantity)
        if p and p > 0 and q and q > 0 then
          tiers[#tiers + 1] = { price = p, qty = q }
          totalQty = totalQty + q
        end
      end
    end
  end
  if totalQty == 0 then return nil end
  table.sort(tiers, function(a, b) return a.price < b.price end)

  -- Bait: tier1 muy barato (qty<=maxBaitQty Y price*100 < tier2.price*baitPriceRatio)
  local maxBaitQty = tonumber(s.maxBaitQty) or 2
  local baitRatio = tonumber(s.baitPriceRatio) or 50
  local baitExcluded = 0
  local start = 1
  if #tiers >= 2 and tiers[1].qty <= maxBaitQty and tiers[1].price * 100 < tiers[2].price * baitRatio then
    baitExcluded = 1
    totalQty = totalQty - tiers[1].qty
    start = 2
  end
  if totalQty <= 0 then return nil end

  -- Mediana ponderada por volumen sobre los tiers restantes
  local acc = 0
  local median = nil
  for i = start, #tiers do
    acc = acc + tiers[i].qty
    if acc * 2 >= totalQty then median = tiers[i].price; break end
  end
  if not median then median = tiers[#tiers].price end

  -- Confianza
  local usable = #tiers - start + 1
  local minListings = tonumber(s.minListings) or 5
  local minVolume = tonumber(s.minVolume) or 10
  local confidence = "low"
  if baitExcluded > 0 or (usable >= minListings and totalQty >= minVolume) then
    confidence = "high"
  elseif usable >= 3 then
    confidence = "medium"
  end

  -- Anomalía vs priceHistory (% porcentuales vs hist.median)
  local anomaly = false
  if itemID and Core and type(Core.GetRealmDB) == "function" then
    local realm = Core.GetRealmDB()
    local hist = realm and realm.priceHistory and realm.priceHistory[itemID]
    if hist and tonumber(hist.count) and hist.count >= 5 and type(hist.median) == "number" and hist.median > 0 then
      if median < hist.median * 50 / 100 then anomaly = true end
      if median > hist.median * 200 / 100 then anomaly = true end
    end
  end

  return {
    price = median,
    volume = totalQty,
    confidence = confidence,
    baitExcluded = baitExcluded,
    anomaly = anomaly,
    tiers = { start = start, last = #tiers, list = tiers },
  }
end

-- ------------------------------------------------------------------
-- Oportunidad
-- ------------------------------------------------------------------
function Engine.IsOpportunity(itemID, buyPrice, consensus, tier, settings)
  local buyQty = 0
  if consensus and consensus.tiers and consensus.tiers.list then
    local t = consensus.tiers.list
    for i = consensus.tiers.start, consensus.tiers.last do
      if t[i] and t[i].price == buyPrice then buyQty = t[i].qty end
    end
  end
  if type(buyPrice) ~= "number" or buyPrice <= 0 then
    return { isOpp = false, roiBPS = nil, rarity = nil, reason = "invalid_buy", buyQty = buyQty }
  end
  if not consensus or type(consensus.price) ~= "number" or consensus.price <= 0 then
    return { isOpp = false, roiBPS = nil, rarity = nil, reason = "no_consensus", buyQty = buyQty }
  end
  local roiBPS = Engine.ComputeROI(buyPrice, consensus.price, itemID, tier)
  if roiBPS == nil then
    return { isOpp = false, roiBPS = nil, rarity = nil, reason = "no_cost_data", buyQty = buyQty }
  end
  local thresholdBps = (tonumber((settings and settings.minROI)) or 15) * 100
  local rarity = Engine.ClassifyRarity(roiBPS)
  local isOpp = roiBPS >= thresholdBps
  return {
    isOpp = isOpp,
    roiBPS = roiBPS,
    rarity = rarity,
    reason = isOpp and "above_min_roi" or "below_min_roi",
    buyQty = buyQty,
  }
end

-- ------------------------------------------------------------------
-- priceHistory
-- ------------------------------------------------------------------
function Engine.UpdatePriceHistory(itemID, consensus, settings)
  if type(itemID) ~= "number" or not consensus or type(consensus.price) ~= "number" or consensus.price <= 0 then return false end
  if not consensus.confidence or consensus.confidence == "low" then return false end
  local realm = Core and type(Core.GetRealmDB) == "function" and Core.GetRealmDB()
  if not realm or not realm.priceHistory then return false end
  local cap = tonumber((settings and settings.historyCap) or 50)
  if cap and cap >= 1 then
  else cap = 50 end
  local entry = realm.priceHistory[itemID]
  if not entry or type(entry) ~= "table" then
    entry = { samples = {}, median = nil, count = 0, lastUpdate = 0 }
    realm.priceHistory[itemID] = entry
  end
  entry.samples[#entry.samples + 1] = { price = consensus.price, qty = consensus.volume or 0, ts = GetTime() }
  while #entry.samples > cap do table.remove(entry.samples, 1) end
  -- Recomputar mediana (entera)
  local prices = {}
  for i = 1, #entry.samples do prices[i] = entry.samples[i].price end
  table.sort(prices)
  local n = #prices
  local med
  if n == 0 then med = nil
  elseif n % 2 == 1 then med = prices[(n + 1) / 2]
  else med = math.floor((prices[n / 2] + prices[n / 2 + 1]) / 2) end
  entry.median = med
  entry.count = n
  entry.lastUpdate = GetTime()
  return true
end

-- ------------------------------------------------------------------
-- Commodity detection
-- ------------------------------------------------------------------
function Engine.IsCommodity(itemID)
  if type(itemID) ~= "number" or itemID <= 0 then return false end
  local C = _G.C_Item
  if C and type(C.IsItemCommodity) == "function" then
    local v = C.IsItemCommodity(itemID)
    if type(v) == "boolean" then return v end
  end
  local AH = _G.C_AuctionHouse
  if AH and type(AH.GetItemCommodityStatus) == "function" then
    local v = AH.GetItemCommodityStatus(itemID)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
  end
  -- Heurística defensiva: commodities con stack>1 (Weapon=2 y Armor=3, Mount=17).
  local info = { GetItemInfo(itemID) }
  if not info[1] then return false end
  local classID = tonumber(info[12])
  local maxStack = tonumber(info[8])
  if type(classID) ~= "number" or type(maxStack) ~= "number" then return false end
  if classID == 2 or classID == 3 or classID == 17 then return false end
  return maxStack > 1
end

-- ------------------------------------------------------------------
-- ItemKey (MakeItemKey: síncrono en la API)
-- ------------------------------------------------------------------
function Engine.MakeItemKey(itemID)
  local AH = _G.C_AuctionHouse
  if AH and type(AH.MakeItemKey) == "function" then
    local key = AH.MakeItemKey(itemID)
    if key then return key end
  end
  return { itemID = itemID or 0, itemLevel = 0, itemSuffixID = 0 }
end

-- ------------------------------------------------------------------
-- Formatters
-- ------------------------------------------------------------------
function Engine.ToGoldString(copper)
  if type(copper) ~= "number" then return "0 cobre" end
  copper = math.max(0, math.floor(copper))
  if copper == 0 then return "0 cobre" end -- O6: sin "0 plata"
  local gold = math.floor(copper / Engine.COPPER_PER_GOLD)
  local silver = math.floor((copper - gold * Engine.COPPER_PER_GOLD) / Engine.COPPER_PER_SILVER)
  local copperRem = copper % Engine.COPPER_PER_SILVER
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. " oro" end
  if silver > 0 or (gold == 0 and copperRem == 0) then parts[#parts + 1] = silver .. " plata" end
  if copperRem > 0 then parts[#parts + 1] = copperRem .. " cobre" end
  return table.concat(parts, " ")
end
