-- WoWFlips - Tooltip.lua
-- Enriquecimiento de GameTooltip: histórico local + margen sugerido.
-- Hook via TooltipDataProcessor.AddTooltipPostCall (API moderna, sin taint).

Tooltip = Tooltip or {}

function Tooltip.Initialize()
  local proc = _G.TooltipDataProcessor
  if not proc or type(proc.AddTooltipPostCall) ~= "function" then return end
  local Enum = _G.Enum
  if not Enum or not Enum.TooltipDataType or not Enum.TooltipDataType.Item then return end
  proc.AddTooltipPostCall(Enum.TooltipDataType.Item, Tooltip.OnTooltipSetItem)
end

-- ------------------------------------------------------------------
-- Líneas adicionales: solo si hay datos; nunca modificamos la base.
-- ------------------------------------------------------------------
function Tooltip.OnTooltipSetItem(tooltip, data)
  if not tooltip or type(tooltip.AddLine) ~= "function" then return end
  local itemID = tooltip:GetItem()
  if type(itemID) ~= "number" and data then
    if type(data.itemID) == "number" then itemID = data.itemID end
  end
  if type(itemID) ~= "number" or itemID <= 0 then return end

  -- Histórico (mediana)
  local realm = Core.GetRealmDB()
  local hist = realm and realm.priceHistory and realm.priceHistory[itemID]
  if hist and type(hist.median) == "number" and hist.median > 0 and type(hist.count) == "number" and hist.count > 0 then
    local ageMin = (GetTime() - (hist.lastUpdate or 0)) / 60
    tooltip:AddLine(string.format("WoWFlips — M %s", Engine.ToGoldString(hist.median)), 1, 1, 1)
    tooltip:AddLine(string.format("  Muestras: %d · Actualizado hace %d min", hist.count, math.max(0, math.floor(ageMin + 0.5))), 0.8, 0.8, 0.8)
  else
    tooltip:AddLine("WoWFlips — Sin histórico local — escanea la AH", 0.7, 0.7, 0.7)
  end

  -- Margen sugerido de reventa
  local margin = Tooltip.GetSuggestedMargin(itemID)
  if margin and margin > 0 then
    tooltip:AddLine(string.format("  Margen sugerido de reventa: %s", Engine.ToGoldString(margin)), 1, 0.82, 0.13)
  end
end

function Tooltip.AddHistoryLines(tooltip, itemID)
  if not tooltip or type(tooltip.AddLine) ~= "function" or type(itemID) ~= "number" then return end
  local realm = Core.GetRealmDB()
  local hist = realm and realm.priceHistory and realm.priceHistory[itemID]
  if hist and type(hist.median) == "number" and hist.median > 0 then
    local ageMin = (GetTime() - (hist.lastUpdate or 0)) / 60
    tooltip:AddLine(string.format("WoWFlips — M %s", Engine.ToGoldString(hist.median)), 1, 1, 1)
    tooltip:AddLine(string.format("  Muestras: %d · Actualizado hace %d min", hist.count or 0, math.max(0, math.floor(ageMin + 0.5))), 0.8, 0.8, 0.8)
  end
end

function Tooltip.GetSuggestedMargin(itemID)
  return Engine.ComputeBreakeven(0, itemID, Engine.GetAHTier())
end
