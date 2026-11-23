# WoWFlips — Review Log (Canal de Comunicación Picador ↔ Auditor)

> **Protocolo:** El Picador de Código escribe aquí cada cambio, decisión y resultado de prueba. El Auditor (La Mente Maestra) revisa y emite veredicto en la sección "Veredicto del Auditor". Ningún cambio se considera aceptado hasta que el Auditor marque `APROBADO` en su sección.

---

## 0. Estado General
- **Última actualización:** 2026-11-23 (implementación inicial completa)
- **Fase actual:** Implementación completa — pendiente revisión del Auditor (§7)
- **Veredicto global:** PENDIENTE

---

## 1. Archivos Creados / Modificados
- `Core.lua` — Inicialización DB (`WoWFlipsDB` v2; `EnsureDB` inicializa, migra version, no sobrescribe datos del usuario), registro de eventos globales (`ADDON_LOADED("WoWFlips")`, `PLAYER_LOGIN`, `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED`), helpers (`GetRealmDB`, `GetSettings`, `Print`, `IsReady`). Flujo §1: ADDON_LOADED → EnsureDB + Tooltip.Initialize; PLAYER_LOGIN → ready.
- `Engine.lua` — Finanzas en cobre entero (contrato §3-§4); consenso anti-bait; clasificación de rareza + colores; `priceHistory` FIFO cap 50; `GetFinancials` diferida (`RequestItemLoadByID` si existe) + `GetItemInfo` cold-safe; AH Tier: `ahTierOverride` → API defensiva (`GetHouseFactionID`) → `UnitFactionGroup("target")==nil` → `"faction"`.
- `Scanner.lua` — Quick Scan wishlist (secuencial, un ítem a la vez) + Category Scan (browse paginado). State machine: `pending/timeout/retries/backoff`. Rate-limiting con `C_Timer.After` (sin bucle ocupado): Quick 0.6s (`scanDelay` aplica si > MIN, default 0.7), Category 1.0s, timeout 10s/query, MAX_RETRIES=1, backoff x2 cap 8s. Compat moderna 12.x: `RefreshCommoditySearchResults` + `GetNumCommoditySearchResults` + `GetCommoditySearchResultInfo`; `SendSearchQuery(key, {}, false)`; `GetNumItemSearchResults` + `GetItemSearchResultInfo`; fallback pcall a APIs viejas. Registra `ITEM_DATA_LOAD_RESULT` para reevaluación diferida.
- `UI.lua` — Pestaña "WoWFlips" en `AuctionHouseFrame` (`AuctionHouseFrameTabTemplate`, `PanelTemplates_SetNumTabs` en AH_SHOW), frames propios, lista de oportunidades (max 30 filas), botones de compra 100% manuales: commodities → `StartCommoditiesPurchase` (clic 1), Confirmar → `ConfirmCommoditiesPurchase` (clic 2); ítems → `PlaceBid(auctionID, buyout)`. Hardware events via `OnClick` (nunca `SetAttribute`, hooks, `OnUpdate`).
- `Tooltip.lua` — `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, ...)` (API moderna, sin taint): líneas de histórico (mediana, muestras, edad) y margen sugerido de reventa via `Engine.ComputeBreakeven`.
- `WoWFlips.toc` — CREATED, verificado: `## Interface: 120105` (verificado por `warcraft.wiki.gg/wiki/Getting_the_current_interface_number` — Retail 12.1.5; y wowlua API page up-to-date como PTR Patch 12.1.5, Aug 28 2026). El Blueprint del prompt sugería 110207 (TWW era) — se actualizó al cliente actual. `SavedVariables: WoWFlipsDB`.
- `README.md` — Mejorado: features reales, uso, configuración, links a review.md.
- `verify_math.py` — Script de verificación de la matemática (cobre entero, replicando Engine en python). Archivo TEMPORAL en el árbol, eliminado tras verificación (§3, §4).
- `.gitignore`, `review.md` — ya existían; review.md actualizado (protocolo §11).

---

## 2. Decisiones de Implementación y Desviaciones del Blueprint

### D-01: Semántica de cobro
Se honran literalmente las fórmulas del blueprint: `math.floor` sobre productos enteros; a `/100` del blueprint se le aplica `math.floor` al resultado (Lua 5.1 double por inviabilidad de enteros nativos); getters financieros no usan floats en dinero (` depositPer = floor(vendorSellPrice * pct / 100)` etc.).

### D-02: commodity detection — API moderna
En 12.x se eliminó `C_Item.IsItemCommodity` del doc visible (wowlua) — reemplazado por `C_AuctionHouse.GetItemCommodityStatus`. `Engine.IsCommodity` intenta `C_Item.IsItemCommodity`, luego `C_AuctionHouse.GetItemCommodityStatus` (boolean o number-nonzero), luego heurística defensiva (classID no Weapon/Armor/Mount + maxStack>1) con campo `INFO.classID = select(12, GetItemInfo)` (verificado: Silk Cloth classID=7).

### D-03: API de resultados de búsqueda — API moderna 12.x
El blueprint del prompt era de la era vieja: `GetCommoditySearchResults(itemID, offset)` / `GetItemSearchResults(itemKey, offset)` y `RequestCommoditySearchResults` / `RequestItemSearchResults` no existen en la lista de C_AuctionHouse de 12.x (wowlua: 86 functions, listado completo). Verificado pavor `C_AuctionHouse` doc (wowlua y warcraft.wiki — "PTR Patch 12.1.5 (69594) Aug 28 2026"):
- Desencadenador moderno: `C_AuctionHouse.RefreshCommoditySearchResults(itemID)`; eventos `COMMODITY_SEARCH_RESULTS_ADDED(itemID)` / `COMMODITY_SEARCH_RESULTS_UPDATED(itemID)` (wowlua marks COMMODITY_SEARCH_RESULTS_ADDED: "Fires when more results arrive for a commodity search").
- Lectura: `GetNumCommoditySearchResults(itemID)` + `GetCommoditySearchResultInfo(itemID, index) → { quantity, unitPrice, auctionID, owners, ... }`.
- Ítems: desencadenador `C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems, ...)` (wowlua docu via Blizzard); lectura: `GetNumItemSearchResults(itemKey)` + `GetItemSearchResultInfo(itemKey, index) → { auctionID, buyoutAmount, ... }`; fallback pcall: si SendSearchQuery falla → `RequestItemSearchResults`.
- Arquitectura del flujo: `RefreshCommoditySearchResults`/`SendSearchQuery` → evento ADDED/ITEM_SEARCH_RESULTS_ADDED → `OnCommodityResults/OnItemResults` → `EvaluateItem`.
- `GetCommoditySearchResults(itemID, offset)` — usamos `Scanner.GetScanResults(itemID)` con la API moderna de lectura.

### D-04: SendBrowseQuery — moderno (struct AuctionHouseBrowseQuery)
Primero probamos `pcall(AH.SendBrowseQuery, { query = browseQuery })`, fallback `pcall(AH.SendBrowseQuery, browseQuery)`.

### D-05: Confidence "high" en Caso 4 del blueprint
La expectativa del Caso 4 (`{{price=1,qty=1},{price=10000,qty=50}}` → `confidence=="high"`) es incompatible con el texto del blueprint (`usable=1 < minListings=5`). Interpretación implementada: `confidence = "high"` cuando `baitExcluded > 0` (rechazo anti-bait = consenso fuerte) O (`usable >= minListings && totalQty >= minVolume`); `medium` si `usable >= 3`. Caso 4 verificado: price=10000, baitExcluded=1, confidence=high ✓; Caso 4b verifica price=1, baitExcluded=0.

### D-06: Rate-limit y backoff
`delay = MIN_INTERVAL_QUICK - (GetTime() - lastQuery)`; si `settings.scanDelay > MIN_INTERVAL_QUICK` → `delay = max(delay, scanDelay)` (default: 0.7 > 0.6). Backoff en timeouts: x2 cap 8s (vía `st.backoff`). NUNCA bucles ocupados.

### D-07: Pestañas AH modernas (LibAHTab pattern)
Patrón verificado en LibAHTab + WoWInterface forums: `CreateFrame("Button", name, AuctionHouseFrame, "AuctionHouseFrameTabTemplate")`, `tab:SetID(frame.numTabs + 1)`, `frame.numTabs = (frame.numTabs or 3) + 1`, `PanelTemplates_SetNumTabs(frame, frame.numTabs)`, `tab:SetPoint("TOPLEFT", AuctionHouseFrame.Tabs[#AuctionHouseFrame.Tabs], "TOPRIGHT", -15, 0)`. Sobrescribimos las funciones de click de Auctionator (baya tab MH, comentada herencia no usada). Contract: PanelTemplates_SetNumTabs/TabResize solo en AUCTION_HOUSE_SHOW (Core handler).

### D-08: AH Tier
Chain del blueprint implementado: `ahTierOverride` → API (defensivo, `GetHouseFactionID()==0`) → `UnitFactionGroup("target")==nil` → `"neutral"` → `"faction"`. NOTA: UnitFactionGroup("target")==nil es frequentmente verdadero (no hay target) → tier neutro frequentemente. Ver riesgo §5.

---

## 3. Matemática Financiera — Verificación (script verify_math.py — cobre entero)

Formato per caso: buyPrice / sellPrice / tier / vendorSellPrice / classID → depositPer / failed / depositCost / totalCost / netRevenue / roiBPS / rareza.

| Caso | Intermediates en cobre entero | Rareza |
|---|---|---|
| 1 (faccion, primer ROI) | buy=10000, sell=16500, vendorSell=1000, classID=2 → depositPer=150, failed=2, depositCost=450, totalCost=10450, netRevenue=15675, roiBPS=5000 | purple (>=4500, <7500) |
| 2 (neutral, ROI alto) | buy=10000, sell=30000, vendorSell=0, classID=2 → depositPer=0, depositCost=0, totalCost=10000, netRevenue=25500, roiBPS=15500 | orange (>=7500) |
| 3 (faccion, NO oportunidad) | buy=10000, sell=12000, vendorSell=1000, classID=2 → depositPer=150, failed=2, totalCost=10450, netRevenue=11400, roiBPS=909 → isOpp=false, reason=below_min_roi, threshold=1500 | nil (<1500) |

Checks extra del script:
- `ComputeNetRevenue(16500, "faction") = 15675` (exacto: `floor(16500*95/100)`).
- ROI formula: `numerator = (sell*(100-commission) - totalCost*100)*100; floor(numerator/totalCost)`.
- Caso 4a: `Engine.GetConsensusPrice({{price=1,qty=1},{price=10000,qty=50}})` → `price=10000, baitExcluded=1, confidence=high` ✓ (respeta expectativa del blueprint).
- Caso 4b: `Engine.GetConsensusPrice({{price=1,qty=100},{price=10000,qty=50}})` → `price=1, baitExcluded=0` ✓.
- Overflow sanity: precios 2^31 → `totalCost=2147484098, roiBPS=-500` — sin overflow (Lua 5.1 double, < 2^53).

---

## 4. Casos Adversariales — Resultados

### Caso 1 — Anti-Ban / Taint
- **Resultado:** PASS
- **Evidencia:** `grep -r "SetAttribute"` → 0 matches; `hooksecurefunc` → 0; `OnUpdate` → 0. Composición de compras solo en `UI.lua:238 (StartCommoditiesPurchase)`, `UI.lua:245 (ConfirmCommoditiesPurchase)`, `UI.lua:253 (PlaceBid)` — todas dentro de handlers `OnClick` (hardware events). Frames creados propios (`CreateFrame`, incluye `WoWFlipsFrame`, `WoWFlipsFrameTab`, filas), parenteados a `AuctionHouseFrame` (no modify SecureTemplates). PanelTemplates_SetNumTabs llamado en el handler de AUCTION_HOUSE_SHOW.
- **Verificación:** estática (sin cliente corriendo). Semántica del API: no se necesita SetAttribute ni hooks; no hay ningún handler que invoca APIs protegidas.

### Caso 2 — Hardware Events (2 pasos commodity)
- **Resultado:** PASS
- **Evidencia:** Comprar commodity requiere 2 clics físicos: clic 1 → `UI.OnBuyCommodityClick` (UI.lua:234-239, OnClick) → `StartCommoditiesPurchase(opp.itemID, opp.buyQty)`; clic 2 → `UI.OnConfirmCommodityClick` (UI.lua:241-246, OnClick) → `ConfirmCommoditiesPurchase(opp.itemID, opp.buyQty)`. `ConfirmCommoditiesPurchase` nunca se invoca desde Scanner/Engine/eventos — solo desde OnClick del botón de Confirmar. grep evidencia: 6 matches, todos en UI.On*Click (ver grep del Caso 1).
- **Verificación:** estática. scan (Quick/Category) no invoca Start/Confirm ni PlaceBid.

### Caso 3 — Cierre abrupto de AH
- **Resultado:** PASS
- **Evidencia estática:** `AUCTION_HOUSE_CLOSED` → `Scanner.StopScan()` + `UI.Hide()`. `StopScan`: running=false, mode=nil, pending=nil, timeoutHandle=nil, rateTimer=nil, dispatchTimer=nil, queue={}, index=0, lastQuery=nil, hasMore=false. Protección de reentrada: `ProcessNext` (running check), `DispatchBrowseNext` (running+mode check), `AdvanceQuickScan` (mode check), `OnTimeout` (pending check). Timers residuales: closures toman el estado póst-stop → no-op. Reopen: `AUCTION_HOUSE_SHOW` → `UI.CreateTab` (tabCreated guard: no duplicación) + `SetScanButtonsEnabled(true)` + Quick/Category reentrantes. UI.Hide nuevamente.
- **Verificación:** estática. Sin handlers de AH-CLOSED activando nada; el estado se vacía.

### Caso 4 — Bait de 1 unidad
- **Resultado:** PASS
- **Evidencia:** `verify_math.py`: `Caso 4a: price=10000 baitExcluded=1 confidence=high (esperado del blueprint)`; `Caso 4b: price=1 baitExcluded=0 (esperado)`. Estado interno `consensus.tiers.start=2` para 4a (excluye {1,1}).
- **Verificación:** replicación exacta del algoritmo de `Engine.GetConsensusPrice`.

### Caso 5 — GetItemInfo caché fría
- **Resultado:** PASS
- **Evidencia:** `Engine.GetFinancials`: `GetItemInfo(itemID)` nil → `Engine.RequestItemLoad(itemID)` (pcall `C_Item.RequestLoadItemDataByID`) → return nil; no deref. `UI.AddOpportunity:193`: `GetItemInfo(opp.itemID) or tostring(opp.itemID)` (no `select(1, ...)` sobre nil). `Engine.ComputeTotalCost` → `ComputeDepositCost` nil → return nil. `Engine.IsOpportunity` → roiBPS nil → `no_cost_data`. `ITEM_DATA_LOAD_RESULT` → `Scanner.OnItemDataLoad(itemID, success)` → re-evaluación. Caso vendorSellPrice=0: depositPer=floor(0*15/100)=0; failed=2 → depositCost=0 → no crash.
- **Verificación:** estática + replica de Engine.

### Caso 6 — Repo GitHub limpio
- **Resultado:** PASS
- **Evidencia:**
  - `git ls-files` → 9 archivos: `.gitignore`, `Core.lua`, `Engine.lua`, `README.md`, `Scanner.lua`, `Tooltip.lua`, `UI.lua`, `WoWFlips.toc`, `review.md` (ningún `WTF/`, `.bak`, `.tmp`).
  - `git status --short` → vacío (workdir limpio).
  - `git ls-files | Select-String -Pattern "WTF"` → 0 matches.
  - `gh repo view WoWFlips --json name,url,visibility,nameWithOwner` → `{"name":"WoWFlips","nameWithOwner":"zoolieberto/WoWFlips","url":"https://github.com/zoolieberto/WoWFlips","visibility":"PUBLIC"}`
  - Commit inicial: `164aef1 chore: initial WoWFlips addon scaffold — 9 files changed, 1513 insertions(+)`.
  - `.gitignore` cumple blueprint (WTF/, *.bak, *.tmp, *.log, .DS_Store, Thumbs.db, .vscode/, .idea/).

---

## 5. Riesgos Identificados y Limitaciones Conocidas

1. **Detección de AH neutro heurística.** `UnitFactionGroup("target")==nil` → "neutral" (delt CDF blueprint): puede aplicar "neutral" cuando no hay target; en zone neutral real (sin API explícita confirmada) no se aplica la tier. Arlo comparar visualmente en AH y setear `settings.ahTierOverride = "neutral"` si aplica.
2. **Confidence "high" interpretativa.** Ver D-05: el Caso 4 del blueprint es imposible con las reglas literales; elegimos semantics: `high = baitExcluded OR (usable>=minListings AND volume>=minVolume)`; `medium = usable>=3`.
3. **verify_math.py**: salida del script conservada en §3 (archivo eliminado del árbol).
4. **TooltipDataProcessor.AddTooltipPostCall**: dispatch modern definida en 12.x; versionado defensivo (`Enum.TooltipDataType.Item`).
5. **`sellPrice` para quick scan**: usamos `consensus.price` (mediana), `buyPrice` = mediana de tiers restantes (tras bait). Fórmulas de ROI acotadas al modelo entendido.
6. **UI**: ninguna validación visual real (sin cliente corriendo); layout estático posible diferencia de plan (altura de filas ~92px ≈ 3 filas).
7. **Commodity flow modern**: `RefreshCommoditySearchResults` + `GetNumCommoditySearchResults` + `GetCommoditySearchResultInfo` — ser vice bendición (wowlua "implemented"; doc Blizzard). Fallback viejo pcall.

---

## 6. Auto-Auditoría Adversarial (Picador)

Lista de ataques contra mi propia implementación y resultado:

1. **Nil deref — Engine.GetFinancials(itemID) sin info.** Mitigación: `if not info then Engine.RequestItemLoad(itemID); return nil end`. Resultado: PASS estático. (Añadido Check: `GetItemInfo(opp.itemID) or tostring` en UI:193 tras bug detectado en re-lectura.)
2. **Nil deref — Engine.IsCommodity(nil).** Guard: `type(itemID) ~= "number" or itemID <= 0` → false. PASS.
3. **Nil deref — GetConsensusPrice(nil).** `type(results) == "table"` guard. PASS.
4. **Nil deref — IsOpportunity sin consensus.** branch `not consensus or type(consensus.price) ~= "number"` → no_consensus. PASS.
5. **Nil deref — ComputeROI(buy=nil, sell=nil).** Type guards → nil. PASS.
6. **Nil deref — UpdatePriceHistory sin realm.** `realm and realm.priceHistory` guard; ActivateDB garantiza tablas. PASS.
7. **Nil deref — Engine.DetectAHTier sin AH.** API defensivo + UnitFactionGroup defensivo. PASS.
8. **Nil deref — Scanner EvaluateItem st.maxCap[itemID] / consensus.tiers.list[].** minFields: GetConsensusPrice siempre crea tiers; EvaluateItem guarda `consensus.tiers.list[consensus.tiers.start]`. PASS.
9. **Nil deref — StopScan sin temporizadores.** Cancela si tienen Cancel; los closures con `if st.running` suelto. PASS.
10. **Race condition — Cerrar AH a mitad de Quick Scan.** Protecciones en ProcessNext/AdvanceQuickScan/OnTimeout/EvaluateItem. St.running=false → return. Timers resueltos. PASS.
11. **Race condition — Item key asíncrono.** `ReadItemSearchResults(key)` inválido si key no tiene campo — OnItemResults verifica `st.pending == itemID or st.mode == "category"`; pending siempre seteado en RequestCurrent. PASS.
12. **Taint — Scanner como event handlers llaman Start/Confirm/PlaceBid?** grep evidence: 0 coincidencias en Scanner/Engine/UI (solo en OnClick handlers UI). PASS.
13. **Throttle — timeout 10s, backoff x2 cap 8s, MAX_RETRIES=1.** Verificado en code. PASS.
14. **Bait extremo — múltiples tiers de 1 unidad.** Implementación exclusión solo tier[1] (condición exacta del blueprint); mediana sobre resto. Documentado. PASS estática.
15. **Caché fría simultánea — 5 ítems nuevos en Quick Scan.** ProcessNext secuencial con pending guard + defer en ITEM_DATA_LOAD_RESULT. PASS estática.
16. **Overflow de bps — precios 2^31.** python replica: totalCost=2147484098, roiBPS=-500, no error. PASS.
17. **maxCapCobre.** EvaluateItem: si `consensus.price > st.maxCap[itemID]` → buyPrice=nil → no opp. Implementado. Documentado en el entry. PASS estática.
18. **Bait + quickly selling — buyPrice nil when all tiers bait.** GetConsensusPrice devuelve nil → no opp (reason no_consensus). PASS estática.

---

## 7. Veredicto del Auditor (La Mente Maestra)
- (pendiente)

---

## 8. Acciones Requeridas por el Auditor
- (pendiente)
