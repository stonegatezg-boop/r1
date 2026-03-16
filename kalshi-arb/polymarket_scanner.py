"""
Polymarket Arbitrage Scanner
Scans negRisk event groups for YES-sum < 1.00 (buy all YES for guaranteed profit).

In Polymarket negRisk groups:
  - Outcomes are mutually exclusive & exhaustive (e.g. "Who wins election?")
  - Exactly ONE YES pays out $1.00
  - If sum(YES_ask) < 1.00 - fees, buying all YES = guaranteed profit

Fees: 2% on profits (much lower than Kalshi's 7%)
No API key needed — Polymarket is public read.
"""

import requests
import json
from collections import defaultdict

FEE_PCT = 0.02          # Polymarket fee
MIN_NET_PROFIT = 0.005  # $0.005 minimum net profit to report
MIN_LIQ = 10.0          # minimum liquidity per market leg ($10)
MIN_ASK = 0.003         # exclude near-zero (already-resolved losers)
MAX_ASK = 0.997         # exclude near-certain winners (already-resolved)

BASE_URL = "https://gamma-api.polymarket.com"


def get_neg_risk_events(max_events=2000) -> list:
    """Fetch all active negRisk events (paginated)."""
    events = []
    offset = 0
    limit = 100
    while len(events) < max_events:
        r = requests.get(f"{BASE_URL}/events", params={
            "limit": limit,
            "active": "true",
            "closed": "false",
            "offset": offset,
        })
        if r.status_code != 200:
            print(f"Error {r.status_code}: {r.text[:200]}")
            break
        batch = r.json()
        if not batch:
            break
        # Keep only true negRisk multi-outcome events
        for e in batch:
            if (e.get("negRisk") or e.get("enableNegRisk")) and len(e.get("markets", [])) >= 3:
                events.append(e)
        offset += limit
        print(f"Fetched {offset} events, {len(events)} negRisk candidates...", flush=True)
        if len(batch) < limit:
            break
    return events


def check_event_arb(event: dict) -> dict | None:
    """
    Check if buying all YES positions in this negRisk event costs < $1.00.
    Filters: market must have liquidity >= MIN_LIQ and bestAsk < MAX_ASK.
    """
    markets = event.get("markets", [])
    title = event.get("title", "")

    valid_legs = []
    for m in markets:
        ask = m.get("bestAsk")
        liq = float(m.get("liquidity") or m.get("liquidityNum") or 0)
        if ask is None:
            continue
        try:
            ask_f = float(ask)
        except (ValueError, TypeError):
            continue
        # Exclude near-resolved markets (winner ~$1 or loser ~$0)
        if ask_f < MIN_ASK or ask_f > MAX_ASK:
            continue
        if liq < MIN_LIQ:
            continue
        valid_legs.append({
            "question": m.get("question", ""),
            "ask": ask_f,
            "bid": float(m.get("bestBid") or 0),
            "liquidity": liq,
            "slug": m.get("slug", ""),
        })

    if len(valid_legs) < 2:
        return None

    yes_sum = sum(leg["ask"] for leg in valid_legs)

    # TRUE ARB requires buying ALL outcomes. Only trust the sum if:
    # (a) All markets in the event are accounted for in valid_legs, OR
    # (b) There are exactly 2 total markets (binary: e.g. Rep vs Dem) and both are valid.
    total_markets = len(markets)
    if len(valid_legs) < total_markets:
        return None  # Can't buy all legs → not executable arb

    if yes_sum < 1.00:
        gross = 1.00 - yes_sum
        net = gross * (1 - FEE_PCT)
        if net >= MIN_NET_PROFIT:
            return {
                "title": title,
                "legs": valid_legs,
                "leg_count_valid": len(valid_legs),
                "leg_count_total": len(markets),
                "yes_sum": yes_sum,
                "gross": gross,
                "net": net,
                "event_liquidity": float(event.get("liquidity") or 0),
            }
    return None


def print_arb(arb: dict):
    print(f"\n{'='*70}")
    print(f"EVENT: {arb['title']}")
    print(f"  Legs: {arb['leg_count_valid']} liquid / {arb['leg_count_total']} total")
    print(f"  Sum YES asks: ${arb['yes_sum']:.4f}  (< $1.00)")
    print(f"  Gross profit: ${arb['gross']:.4f}  |  Net after 2% fee: ${arb['net']:.4f}")
    print(f"  Event liquidity: ${arb['event_liquidity']:,.0f}")
    print("  Buy YES on:")
    for leg in sorted(arb["legs"], key=lambda x: x["ask"], reverse=True):
        print(f"    ${leg['ask']:.4f}  (liq=${leg['liquidity']:,.0f})  {leg['question'][:65]}")


def scan():
    print("Fetching Polymarket negRisk events...")
    events = get_neg_risk_events()
    print(f"\nFound {len(events)} negRisk multi-outcome events\n")
    print("Scanning for arbitrage...\n")

    arbs = []
    for e in events:
        result = check_event_arb(e)
        if result:
            arbs.append(result)

    if not arbs:
        print("No arbitrage opportunities found.")
        print("\nTop 5 events closest to arb (lowest YES sum):")
        close = []
        for e in events:
            markets = e.get("markets", [])
            valid = []
            for m in markets:
                ask = m.get("bestAsk")
                liq = float(m.get("liquidity") or 0)
                if ask is None or liq < MIN_LIQ:
                    continue
                try:
                    ask_f = float(ask)
                    if 0 < ask_f < MAX_ASK:
                        valid.append(ask_f)
                except:
                    pass
            if len(valid) >= 2:
                s = sum(valid)
                close.append((s, e.get("title", ""), len(valid), float(e.get("liquidity") or 0)))
        close.sort()
        for s, title, n, liq in close[:5]:
            print(f"  sum={s:.4f}  legs={n}  liq=${liq:,.0f}  {title[:60]}")
    else:
        arbs.sort(key=lambda x: x["net"], reverse=True)
        print(f"Found {len(arbs)} arbitrage opportunities!")
        for arb in arbs:
            print_arb(arb)

    return arbs


if __name__ == "__main__":
    scan()
