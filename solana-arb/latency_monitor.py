"""
Binance vs Polymarket Latency Monitor
======================================
Tracks BTC price on Binance (WebSocket, real-time) and compares with
Polymarket "Bitcoin Up or Down - 5 Minutes" current odds.

Logic:
  - Each 5-min market has a "price to beat" (opening BTC price)
  - If BTC moved +$200 from open with 1 min left → Up should be ~90%
  - If Polymarket still shows Up=55¢ → LAG DETECTED → edge to buy Up

Usage: python3 latency_monitor.py
"""

import asyncio
import websockets
import requests
import json
import time
import math
from datetime import datetime, timezone

GAMMA_API = "https://gamma-api.polymarket.com"
BINANCE_WS = "wss://stream.binance.com:9443/ws/btcusdt@aggTrade"

# BTC 5-min volatility (annualized ~70% → per-minute ~0.097%)
BTC_VOL_PER_MIN = 0.00097  # 0.097% per minute standard deviation

# Minimum edge to flag (Polymarket fair value vs actual price)
MIN_EDGE_PCT = 5.0  # 5 cents on a $1 contract

# ─── State ────────────────────────────────────────────────────────────────────
btc_price = {"price": None, "ts": None}


# ─── Polymarket ───────────────────────────────────────────────────────────────

def fetch_active_btc_5min_markets() -> list[dict]:
    """Find active BTC Up/Down 5-minute markets on Polymarket."""
    try:
        r = requests.get(f"{GAMMA_API}/markets", params={
            "tag": "bitcoin",
            "active": "true",
            "closed": "false",
            "limit": 50,
        }, timeout=5)
        if r.status_code != 200:
            return []
        markets = r.json()
        # Filter to 5-min up/down markets
        result = []
        for m in markets:
            q = (m.get("question") or "").lower()
            if ("up or down" in q or "higher or lower" in q) and "5" in q:
                result.append(m)
        return result
    except Exception as e:
        print(f"  [Polymarket error] {e}")
        return []


def fetch_btc_updown_markets_by_slug() -> list[dict]:
    """Search by event slug pattern for BTC 5-min markets."""
    try:
        r = requests.get(f"{GAMMA_API}/events", params={
            "slug": "btc-updown-5m",
            "active": "true",
            "limit": 5,
        }, timeout=5)
        if r.status_code != 200:
            return []
        events = r.json()
        markets = []
        for e in events:
            for m in e.get("markets", []):
                markets.append(m)
        return markets
    except Exception as e:
        print(f"  [Polymarket slug error] {e}")
        return []


def get_market_odds(market: dict) -> dict | None:
    """Extract current yes/no odds from a market dict."""
    outcomes = market.get("outcomePrices") or market.get("outcomes")
    if not outcomes:
        return None

    # outcomePrices is often a JSON string like '["0.75", "0.25"]'
    if isinstance(outcomes, str):
        try:
            outcomes = json.loads(outcomes)
        except Exception:
            return None

    if len(outcomes) < 2:
        return None

    try:
        up_price   = float(outcomes[0])
        down_price = float(outcomes[1])
    except (ValueError, TypeError):
        return None

    return {"up": up_price, "down": down_price}


# ─── Fair value model ─────────────────────────────────────────────────────────

def fair_value_up(current_btc: float, price_to_beat: float,
                  minutes_remaining: float) -> float:
    """
    Calculate fair probability that BTC ends ABOVE price_to_beat.
    Uses log-normal random walk (Black-Scholes style, simplified).

    P(Up) = N(d) where d = ln(S/K) / (vol * sqrt(T))
    S = current price, K = price to beat, T = time in minutes
    """
    if minutes_remaining <= 0:
        return 1.0 if current_btc > price_to_beat else 0.0

    if current_btc <= 0 or price_to_beat <= 0:
        return 0.5

    vol_sqrt_t = BTC_VOL_PER_MIN * math.sqrt(minutes_remaining)
    if vol_sqrt_t == 0:
        return 1.0 if current_btc > price_to_beat else 0.0

    d = math.log(current_btc / price_to_beat) / vol_sqrt_t

    # Standard normal CDF approximation
    return _norm_cdf(d)


def _norm_cdf(x: float) -> float:
    """Standard normal CDF via error function."""
    import math
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


# ─── Analysis ─────────────────────────────────────────────────────────────────

def analyze(market: dict, current_btc: float):
    """Compare Polymarket odds vs fair value given current BTC price."""
    odds = get_market_odds(market)
    if not odds:
        return

    # Get price to beat (start-of-window price)
    price_to_beat = market.get("startPrice") or market.get("priceToBeat")
    if not price_to_beat:
        # Fallback: parse from question text
        price_to_beat = None

    # Get time remaining
    end_dt_str = market.get("endDate") or market.get("endDateIso")
    minutes_remaining = None
    if end_dt_str:
        try:
            from datetime import datetime, timezone
            end_dt = datetime.fromisoformat(end_dt_str.replace("Z", "+00:00"))
            now = datetime.now(timezone.utc)
            minutes_remaining = max(0, (end_dt - now).total_seconds() / 60)
        except Exception:
            pass

    question = market.get("question", "")[:60]
    up_price  = odds["up"]
    down_price = odds["down"]

    print(f"\n  Market: {question}")
    print(f"  BTC now: ${current_btc:,.2f}", end="")

    if price_to_beat:
        diff = current_btc - float(price_to_beat)
        print(f"  |  Price to beat: ${float(price_to_beat):,.2f}  |  Diff: {diff:+.2f}", end="")

    if minutes_remaining is not None:
        print(f"  |  {minutes_remaining:.1f} min left", end="")
    print()

    print(f"  Polymarket: Up={up_price:.2f}¢  Down={down_price:.2f}¢")

    # Fair value if we have price_to_beat and time
    if price_to_beat and minutes_remaining is not None:
        fair = fair_value_up(current_btc, float(price_to_beat), minutes_remaining)
        edge_up   = fair - up_price
        edge_down = (1 - fair) - down_price

        print(f"  Fair value: Up={fair:.2f}  Down={1-fair:.2f}")

        if abs(edge_up) * 100 >= MIN_EDGE_PCT:
            direction = "UP" if edge_up > 0 else "DOWN"
            edge_val  = edge_up if edge_up > 0 else edge_down
            print(f"  *** EDGE DETECTED: Buy {direction} | edge={edge_val*100:.1f}¢ per $1 ***")
        else:
            print(f"  Edge: Up={edge_up*100:+.1f}¢  Down={edge_down*100:+.1f}¢  (below threshold)")
    else:
        print(f"  (No price-to-beat data for fair value calculation)")


# ─── Binance WebSocket ────────────────────────────────────────────────────────

async def binance_feed():
    """Maintain real-time BTC price from Binance aggTrade stream."""
    print("Connecting to Binance WebSocket...")
    async for ws in websockets.connect(BINANCE_WS, ping_interval=20):
        try:
            async for msg in ws:
                data = json.loads(msg)
                price = float(data["p"])
                btc_price["price"] = price
                btc_price["ts"]    = time.time()
        except websockets.ConnectionClosed:
            print("  Binance WS disconnected, reconnecting...")
            continue


# ─── Main polling loop ────────────────────────────────────────────────────────

async def polling_loop(interval_sec: int = 10):
    """Every N seconds, check Polymarket odds vs current BTC price."""
    print("Starting Polymarket polling loop...")
    await asyncio.sleep(2)  # let Binance feed warm up

    while True:
        now = datetime.now().strftime("%H:%M:%S")
        current = btc_price["price"]

        if current is None:
            print(f"[{now}] Waiting for Binance price...")
            await asyncio.sleep(interval_sec)
            continue

        print(f"\n{'='*65}")
        print(f"[{now}]  BTC = ${current:,.2f}  (Binance real-time)")

        # Try slug-based search first, then tag-based
        markets = fetch_btc_updown_markets_by_slug()
        if not markets:
            markets = fetch_active_btc_5min_markets()

        if not markets:
            print("  No active BTC 5-min markets found on Polymarket.")
        else:
            print(f"  Found {len(markets)} active market(s)")
            for m in markets[:3]:  # show max 3
                analyze(m, current)

        await asyncio.sleep(interval_sec)


# ─── Entry point ─────────────────────────────────────────────────────────────

async def main():
    print("Binance ↔ Polymarket Latency Monitor")
    print(f"BTC vol assumption: {BTC_VOL_PER_MIN*100:.3f}%/min")
    print(f"Min edge to flag: {MIN_EDGE_PCT:.0f}¢ per $1 contract")
    print()
    await asyncio.gather(
        binance_feed(),
        polling_loop(interval_sec=8),
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
