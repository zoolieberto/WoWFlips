-- WoWFlips - Core.lua
-- Implementado por El Picador de Código.
-- Responsabilidad: init DB (WoWFlipsDB), eventos globales, helpers de chat, acceso a WoWFlipsDB.
-- NO implementar aquí finanzas, escaneo ni UI.

local ADDON_NAME = "WoWFlips"

WoWFlipsDB = WoWFlipsDB or {}
local db = WoWFlipsDB

Core = Core or {}

-- ------------------------------------------------------------------
-- EnsureDB: inicializa tablas vacías, migra version, no sobrescribe.
-- ------------------------------------------------------------------
function Core.EnsureDB()
  if type(db) ~= "table" then db = WoWFlipsDB end
  if type(db.wishlist) ~= "table" then db.wishlist = {} end
  local s = db.settings
  if type(s) ~= "table" then s = {} end

  -- Valores por defecto del esquema (WoWFlipsDB §2) — respetamos lo del usuario.
  if s.minROI == nil then s.minROI = 15 end
  if s.scanDelay == nil then s.scanDelay = 0.7 end
  if s.ahTierOverride == nil then s.ahTierOverride = nil end
  if s.maxBaitQty == nil then s.maxBaitQty = 2 end
  if s.baitPriceRatio == nil then s.baitPriceRatio = 50 end
  if s.minListings == nil then s.minListings = 5 end
  if s.minVolume == nil then s.minVolume = 10 end
  if s.historyCap == nil then s.historyCap = 50 end
  if s.timeoutSec == nil then s.timeoutSec = 10 end
  db.settings = s

  if type(db.realms) ~= "table" then db.realms = {} end

  -- Migración de versiones: 1 -> 2
  local v = tonumber(db.version) or 1
  if v < 2 then db.version = 2 end
  return db
end

-- ------------------------------------------------------------------
-- Acceso
-- ------------------------------------------------------------------
function Core.GetRealmDB()
  local realm = GetRealmName() or "Default"
  local realms = db and db.realms
  if type(realms) ~= "table" then realms = {}; db.realms = realms end
  if not realms[realm] or type(realms[realm]) ~= "table" then
    realms[realm] = { priceHistory = {}, lastScan = {} }
  end
  return realms[realm]
end

function Core.GetSettings()
  if type(db.settings) == "table" then return db.settings end
  db.settings = {}
  return db.settings
end

function Core.GetWishlist() return db.wishlist or {} end

function Core.Print(msg)
  print("[WoWFlips] " .. tostring(msg))
end

function Core.IsReady() return Core.readyState == true end

-- ------------------------------------------------------------------
-- Eventos globales (flujo §1)
-- ------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

local function OnEvent(self, event, ...)
  if event == "ADDON_LOADED" then
    if (...) == ADDON_NAME then
      Core.EnsureDB()
      if Tooltip and type(Tooltip.Initialize) == "function" then Tooltip.Initialize() end
    end
  elseif event == "PLAYER_LOGIN" then
    Core.readyState = true
  elseif event == "AUCTION_HOUSE_SHOW" then
    if Engine and type(Engine.DetectAHTier) == "function" then Engine.DetectAHTier() end
    if UI and type(UI.CreateTab) == "function" then UI.CreateTab() end
    if UI and type(UI.SetScanButtonsEnabled) == "function" then UI.SetScanButtonsEnabled(true) end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if Scanner and type(Scanner.StopScan) == "function" then Scanner.StopScan() end
    if UI and type(UI.Hide) == "function" then UI.Hide() end
  end
end

eventFrame:SetScript("OnEvent", OnEvent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
Core.EventFrame = eventFrame

-- Inicializar DB al cargar (por si PLAYER_LOGIN nunca segura).
Core.EnsureDB()
Core.Print("Core inicializado.")
