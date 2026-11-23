-- WoWFlips - UI.lua
-- Pestaña WoWFlips integrada en AuctionHouseFrame sin taint, lista de oportunidades,
-- botones de compra 100% manuales (hardware events). Frames propios.

UI = UI or {}

local MAX_ROWS = 30
local ADDON = "WoWFlips"

UI.panel = nil
UI.rows = nil
UI.opportunities = {}
UI.oppRows = {}
UI.categoryInput = nil
UI.scanBar = nil
UI.btnQuick = nil
UI.btnCategory = nil
UI.btnStop = nil
UI.progressText = nil
UI.scanButtonsEnabled = false
UI.tabCreated = false

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------
function UI.MakeButton(parent, text, width, height)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetText(text)
  btn:SetSize(width or 100, height or 24)
  btn:EnableMouse(true)
  return btn
end

-- ------------------------------------------------------------------
-- Create
-- ------------------------------------------------------------------
function UI.Create()
  if UI.panel and UI.panel:IsObjectType("Frame") then return UI.panel end
  local parent = _G.AuctionHouseFrame
  if not parent then return nil end
  UI.panel = CreateFrame("Frame", ADDON .. "Frame", parent, "BackdropTemplate") -- O8
  local panel = UI.panel
  panel:SetSize(590, 310)
  panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 5, -35)
  panel:SetBackdrop({
    bgFile = "Interface\\CHATFRAME\\ChatFrameBackground", tile = true, tileSize = 32,
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
  })
  panel:SetBackdropColor(0.05, 0.05, 0.10, 0.95)
  panel:SetBackdropBorderColor(0.25, 0.25, 0.30, 1)
  panel:EnableMouse(true)
  panel:SetMovable(true) -- H7
  panel:SetClampedToScreen(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  -- Título
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", panel, "TOP", 0, -8)
  title:SetText("WoWFlips — Escáner de flips rápidos")

  -- Filas
  UI.rows = CreateFrame("Frame", nil, panel)
  UI.rows:SetPoint("TOP", panel, "TOP", 0, -38)
  UI.rows:EnableMouse(true)

  -- Barra de escaneo
  local scan = CreateFrame("Frame", nil, panel)
  scan:SetHeight(30)
  scan:SetPoint("BOTTOM", panel, "BOTTOM", 0, 4)
  scan:SetPoint("LEFT", panel, "LEFT", 6, 0)
  scan:SetPoint("RIGHT", panel, "RIGHT", -6, 0)
  UI.scanBar = scan

  -- Input de categoría
  local input = CreateFrame("EditBox", nil, scan, "BackdropTemplate")
  input:SetPoint("LEFT", scan, "LEFT", 4, 0)
  input:SetHeight(22)
  input:SetWidth(140)
  input:SetBackdropBorderColor(0.5, 0.5, 0.55, 1)
  input:SetTextInsets(4, 4, 2, 2)
  input:SetAutoFocus(false)
  UI.categoryInput = input
  input:SetScript("OnEnterPressed", function(self) UI.OnCategoryScanClick() end)

  -- Botones de escaneo
  UI.btnQuick = UI.MakeButton(scan, "Quick Scan", 44, 22)
  UI.btnQuick:SetPoint("LEFT", input, "RIGHT", 4, 0)
  UI.btnQuick:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnQuickScanClick() end end)

  UI.btnCategory = UI.MakeButton(scan, "Category", 52, 22)
  UI.btnCategory:SetPoint("LEFT", UI.btnQuick, "RIGHT", 4, 0)
  UI.btnCategory:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnCategoryScanClick() end end)

  UI.btnStop = UI.MakeButton(scan, "Stop", 40, 22)
  UI.btnStop:SetPoint("LEFT", UI.btnCategory, "RIGHT", 4, 0)
  UI.btnStop:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnStopScanClick() end end)
  UI.btnStop:Hide()

  -- Texto de progreso
  local prog = scan:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  prog:SetPoint("RIGHT", scan, "RIGHT", -4, 0)
  prog:SetText("")
  UI.progressText = prog

  -- Rebajuste de filas al bar de escaneo real
  UI.rows:SetPoint("BOTTOM", scan, "TOP", 0, -8)
  return panel
end


-- ------------------------------------------------------------------
-- Tab
-- ------------------------------------------------------------------
function UI.CreateTab()
  if UI.tabCreated then return end
  local frame = _G.AuctionHouseFrame
  if not frame then return end
  UI.tabCreated = true
  local tab = CreateFrame("Button", ADDON .. "Tab", frame, "AuctionHouseFrameTabTemplate")
  tab:SetText("WoWFlips")
  frame.numTabs = (frame.numTabs or 3) + 1
  tab:SetID(frame.numTabs)
  PanelTemplates_SetNumTabs(frame, frame.numTabs)
  local lastTab = frame.Tabs and frame.Tabs[#frame.Tabs]
  if lastTab then
    tab:SetPoint("TOPLEFT", lastTab, "TOPRIGHT", -15, 0)
  else
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -20)
  end
  tab:Show()
  tab:SetScript("OnClick", function(self)
    PanelTemplates_SetTab(frame, self:GetID())
    local p = UI.Create()
    if p then p:Show() end
  end)
end

-- ------------------------------------------------------------------
-- Show / Hide
-- ------------------------------------------------------------------
function UI.Show()
  local p = UI.Create()
  if p then
    p:Show()
    UI.RefreshOpportunities(UI.opportunities)
  end
end

function UI.Hide()
  if UI.panel then UI.panel:Hide() end
end

-- ------------------------------------------------------------------
-- Opps
-- ------------------------------------------------------------------
function UI.RefreshOpportunities(list)
  UI.ClearOpportunities()
  if type(list) == "table" then
    for _, opp in ipairs(list) do UI.AddOpportunity(opp) end
  end
end

function UI.ClearOpportunities()
  for _, row in ipairs(UI.oppRows) do if row then row:Hide() end end
  UI.opportunities = {}
  UI.oppRows = {}
end

function UI.AddOpportunity(opp)
  local panel = UI.Create()
  if not panel or not opp then return end
  while #UI.opportunities >= MAX_ROWS and UI.oppRows[1] do
    local old = UI.oppRows[1]
    table.remove(UI.opportunities, 1)
    table.remove(UI.oppRows, 1)
    if old then old:Hide() end
  end
  UI.opportunities[#UI.opportunities + 1] = opp
  local i = #UI.opportunities
  local rows = UI.rows
  if not rows then return end
  local row = CreateFrame("Button", ADDON .. "Row" .. i, rows, "BackdropTemplate")
  row:SetHeight(26)
  row:SetPoint("TOPLEFT", rows, "TOPLEFT", 4, -(8 + (i - 1) * 30))
  row:SetBackdropColor(0.07, 0.07, 0.10, 0.9)
  row:SetBackdropBorderColor(0.15, 0.15, 0.20, 1)
  row.oppData = opp

  local nameFont = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  nameFont:SetPoint("LEFT", 6, 0)
  nameFont:SetPoint("TOP", row, "TOP", 0, -5)
  local nameText = GetItemInfo(opp.itemID) or tostring(opp.itemID) -- caché fría: sin deref nil
  if type(nameText) == "string" then nameText = nameText:gsub("^%[(.*)%]$", "%1") end
  nameFont:SetText(nameText)

  local roiFont = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  roiFont:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  roiFont:SetPoint("TOP", row, "TOP", 0, -5)
  local rarityColor = Engine.GetRarityColor(opp.roiBPS) or "|r"
  roiFont:SetFormattedText("%sROI %.2f%%|r", rarityColor, (opp.roiBPS or 0) / 100)

  local valueFont = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  valueFont:SetPoint("LEFT", row, "LEFT", 260, -5)
  valueFont:SetText(Engine.ToGoldString(opp.buyPrice or 0))

  local infoFont = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  infoFont:SetPoint("LEFT", row, "LEFT", 260, -22)
  infoFont:SetTextColor(0.75, 0.75, 0.75)
  infoFont:SetText(opp.reason or "")

  if opp.isCommodity then
    row.btnBuy = UI.MakeButton(row, "Comprar", 64, 18)
    row.btnBuy:SetPoint("RIGHT", row, "RIGHT", -4, -2)
    row.btnBuy:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnBuyCommodityClick(self) end end)
    row.btnConfirm = UI.MakeButton(row, "Confirmar", 82, 18)
    row.btnConfirm:Hide()
    row.btnConfirm:SetPoint("RIGHT", row.btnBuy, "LEFT", -6, 0)
    row.btnConfirm:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnConfirmCommodityClick(self) end end)
  else
    row.btnBuy = UI.MakeButton(row, "Puja", 64, 18)
    row.btnBuy:SetPoint("RIGHT", row, "RIGHT", -4, -2)
    row.btnBuy:SetScript("OnClick", function(self, button) if button == "LeftButton" then UI.OnBuyItemBidClick(self) end end)
  end
  -- C1: los handlers reciben el botón (self); los datos del opp deben vivir EN cada botón.
  row.btnBuy.oppData = opp
  if row.btnConfirm then row.btnConfirm.oppData = opp end

  row:SetScript("OnEnter", function(self) UI.OnRowEnter(self) end)
  row:SetScript("OnLeave", function(self) UI.OnRowLeave(self) end)
  table.insert(UI.oppRows, row)
end

-- ------------------------------------------------------------------
-- Buy flows — hardware events (OnClick)
-- ------------------------------------------------------------------
function UI.OnBuyCommodityClick(btn)
  local opp = btn and btn.oppData
  local C = _G.C_AuctionHouse
  if not (opp and C and type(C.StartCommoditiesPurchase) == "function") then return end
  -- C2: precio unitario como 3er argumento (blueprint). En 12.x el precio se
  -- confirma vía COMMODITY_PRICE_UPDATED; el arg extra es ignorado por versiones
  -- que no lo aceptan, y requerido por las que sí.
  local ok = pcall(C.StartCommoditiesPurchase, opp.itemID, opp.buyQty or 1, opp.buyPrice)
  -- O10: revelar explícitamente el botón Confirmar tras el primer clic.
  if ok and btn.GetParent then
    local row = btn:GetParent()
    if row then
      row.pendingConfirm = true
      if row.btnConfirm then row.btnConfirm:Show() end
    end
  end
end

function UI.OnConfirmCommodityClick(btn)
  local opp = btn and btn.oppData
  local C = _G.C_AuctionHouse
  if not (opp and C and type(C.ConfirmCommoditiesPurchase) == "function") then return end
  local ok = pcall(C.ConfirmCommoditiesPurchase, opp.itemID, opp.buyQty or 1, opp.buyPrice)
  if ok and btn.GetParent then
    local row = btn:GetParent()
    if row then
      row.pendingConfirm = false
      if row.btnConfirm then row.btnConfirm:Hide() end
    end
  end
end

function UI.OnBuyItemBidClick(btn)
  local opp = btn and btn.oppData
  local C = _G.C_AuctionHouse
  if not (opp and C and type(C.PlaceBid) == "function") then return end
  if not opp.auctionID then return end
  pcall(C.PlaceBid, opp.auctionID, opp.buyoutPrice or 0)
end

-- ------------------------------------------------------------------
-- Row hover
-- ------------------------------------------------------------------
function UI.OnRowEnter(row)
  if row then
    if row.btnBuy then row.btnBuy:Show() end
    if row.btnConfirm then row.btnConfirm:Show() end
  end
end

function UI.OnRowLeave(row)
  if row then
    if row.btnBuy then row.btnBuy:Hide() end
    -- O10: con compra pendiente de confirmar, el botón Confirmar permanece visible.
    if row.btnConfirm and not row.pendingConfirm then row.btnConfirm:Hide() end
  end
end

-- ------------------------------------------------------------------
-- Scan buttons — hardware events (OnClick)
-- ------------------------------------------------------------------
function UI.UpdateProgress(text)
  if UI.progressText then UI.progressText:SetText(text or "") end
end

function UI.SetScanButtonsEnabled(enabled)
  UI.scanButtonsEnabled = enabled
  if UI.btnQuick then UI.btnQuick:SetEnabled(enabled) end
  if UI.btnCategory then UI.btnCategory:SetEnabled(enabled) end
  if UI.btnStop then
    if enabled then UI.btnStop:Show() else UI.btnStop:Hide() end
  end
end

function UI.OnQuickScanClick()
  if not UI.scanButtonsEnabled then return end
  local st = Scanner.state
  if Scanner and Scanner.IsRunning() and st.mode == "quick" then
    Scanner.StopScan()
    UI.SetScanButtonsEnabled(true) -- H6: permitir reiniciar el scan
  else
    Scanner.StartQuickScan()
    UI.SetScanButtonsEnabled(true)
    if UI.progressText then UI.progressText:SetText("Quick Scan — 0/" .. #st.queue) end
  end
end

function UI.OnCategoryScanClick()
  if not UI.scanButtonsEnabled then return end
  local st = Scanner.state
  if Scanner and Scanner.IsRunning() then
    Scanner.StopScan()
  end
  local query = UI.categoryInput and UI.categoryInput:GetText() or ""
  if type(query) == "string" and #query > 0 then
    Scanner.StartCategoryScan(query)
    UI.SetScanButtonsEnabled(true)
  end
end

function UI.OnStopScanClick()
  if Scanner then Scanner.StopScan() end
  UI.SetScanButtonsEnabled(true) -- H6: permitir reiniciar el scan
  UI.UpdateProgress("")
end
