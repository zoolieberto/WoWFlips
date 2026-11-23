# WoWFlips

Addon para World of Warcraft que detecta oportunidades de compra rápida y reventa inmediata ("flips") dentro de la Casa de Subastas moderna (`C_AuctionHouse`).

## Características

- 100% local, sin dependencias web ni bases de datos externas.
- Motor financiero en cobre entero (sin floats en dinero): depósito, comisión AH (faccion 5% / neutral 15%), riesgo de republicación (intentos fallidos de re-lote).
- ROI neto real (`Engine.ComputeROI`): `floor((sell*(100-commission) - totalCost*100)*100 / totalCost)` en bps.
- Consenso anti-bait: mediana ponderada por volumen, excluyendo tiers de 1 unidad en sorda.
- Two modos: Quick Scan (wishlist) y Category Scan (browse paginado).
- Interfaz integrada en `AuctionHouseFrame` sin taint: frames propios y botones de compra manuales.
- Compras 100% manuales por hardware events: commodity → StartCommoditiesPurchase + Confirm (2 clics); ítem → PlaceBid.
- Enriquecimiento de tooltips con histórico local (mediana) y margen sugerido de reventa.
- Detección de AH neutro: settings (`ahTierOverride`) → API defensiva → heurística.

## Instalación

1. Copia la carpeta `WoWFlips` en `World of Warcraft/_retail_/Interface/AddOns/`.
2. Activa el addon en la pantalla de selección de personaje.
3. Entra al juego y abre la Casa de Subastas.

## Uso

- Pestaña "WoWFlips" en la AH: escaneo rápido de wishlist o por categoría.
- Wishlist: `WoWFlipsDB.wishlist = { { itemID = <id>, maxCapCobre = <cobre opcional> } }` (SavedVariables).
- Los oportunidades se colorean por rareza según ROI neto: verde/azul/morado/naranja (>= 1500/2500/4500/7500 bps).
- Compra manual mediante los botones de la interfaz (Comprar / Confirmar / Puja).

## Configuración (WoWFlipsDB.settings)

- `minROI` (15) — umbral ROI neto en % (porcentaje).
- `maxBaitQty` (2), `baitPriceRatio` (50) — detección anti-bait.
- `minListings` (5), `minVolume` (10) — umbrales de confianza.
- `historyCap` (50) — muestras de priceHistory por ítem.
- `timeoutSec` (10), `scanDelay` (0.7).

## Desarrollo

- Flujo de eventos documentado en `review.md`.
- `review.md` es el canal comunicación Picador ↔ Auditor: cambios, decisiones y verificación.

## Licencia

MIT (opcional).
