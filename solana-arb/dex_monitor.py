"""
Solana DEX-to-DEX Price Monitor
Monitors the same token pairs across Raydium and Orca directly,
looking for price gaps that a flash loan arbitrage could exploit.

No Jupiter aggregation here — raw DEX prices only.
Uses DexScreener API (public, no key needed) to get per-DEX prices.

Gap needed to be profitable:
  Raydium fee: 0.25%
  Orca fee:    0.30%
  Marginfi flash loan fee: ~0.09%
  Total cost:  ~0.64%
  So gap must be > 0.7% after slippage to net profit.
"""

import requests
import time
from datetime import datetime

DEXSCREENER_API = "https://api.dexscreener.com/latest/dex/tokens"

# Token mint addresses on Solana
TOKENS = {
    "SOL":   "So11111111111111111111111111111111111111112",
    "ETH":   "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs",
    "BONK":  "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",
    "JUP":   "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN",
    "RAY":   "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R",
    "WIF":   "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm",
    "PYTH":  "HZ1JovNiVvGrGs4K4mFmDn53o9HbqKJR6vFAVFTLBjBN",
}

# DEX labels as reported by DexScreener for Solana
TARGET_DEXES = {"raydium", "orca", "meteora", "lifinity"}

MIN_LIQUIDITY_USD = 50_000   # ignore pools with low liquidity
MIN_GAP_PCT       = 0.70     # minimum gap to flag (after fees ~0.64%)
MIN_VOLUME_24H    = 10_000   # ignore low-volume pools


def fetch_pairs(token_mint: str) -> list[dict]:
    """Fetch all trading pairs for a token from DexScreener."""
    try:
        r = requests.get(f"{DEXSCREENER_API}/{token_mint}", timeout=8)
        if r.status_code != 200:
            return []
        data = r.json()
        return data.get("pairs") or []
    except Exception as e:
        print(f"  Error fetching {token_mint}: {e}")
        return []


def get_dex_prices(token_name: str, token_mint: str) -> dict[str, dict]:
    """
    Returns best price per DEX for this token (vs USDC or SOL).
    Format: { "raydium": {"price": 1.23, "liquidity": 500000, "volume24h": 1000000} }
    """
    pairs = fetch_pairs(token_mint)
    dex_prices = {}

    for pair in pairs:
        dex_id = (pair.get("dexId") or "").lower()
        if dex_id not in TARGET_DEXES:
            continue

        # Only pairs vs USDC or USDT (stable base)
        quote_symbol = (pair.get("quoteToken") or {}).get("symbol", "").upper()
        if quote_symbol not in {"USDC", "USDT"}:
            continue

        price = pair.get("priceUsd")
        if not price:
            continue
        try:
            price_f = float(price)
        except (ValueError, TypeError):
            continue

        liq = float((pair.get("liquidity") or {}).get("usd") or 0)
        vol = float((pair.get("volume") or {}).get("h24") or 0)

        if liq < MIN_LIQUIDITY_USD or vol < MIN_VOLUME_24H:
            continue

        # Keep highest-liquidity pool per DEX
        if dex_id not in dex_prices or liq > dex_prices[dex_id]["liquidity"]:
            dex_prices[dex_id] = {
                "price":     price_f,
                "liquidity": liq,
                "volume24h": vol,
                "pair_addr": pair.get("pairAddress", "")[:12],
            }

    return dex_prices


def find_gaps(token_name: str, dex_prices: dict) -> list[dict]:
    """Find price gaps between DEX pairs."""
    gaps = []
    dexes = list(dex_prices.items())

    for i in range(len(dexes)):
        for j in range(i + 1, len(dexes)):
            dex_a, info_a = dexes[i]
            dex_b, info_b = dexes[j]

            p_a = info_a["price"]
            p_b = info_b["price"]

            if p_a == 0 or p_b == 0:
                continue

            # Gap percentage
            gap_pct = abs(p_a - p_b) / min(p_a, p_b) * 100

            if gap_pct < 0.1:  # Skip tiny gaps even in reporting
                continue

            buy_dex  = dex_a if p_a < p_b else dex_b
            sell_dex = dex_b if p_a < p_b else dex_a
            buy_price  = min(p_a, p_b)
            sell_price = max(p_a, p_b)

            gaps.append({
                "token":      token_name,
                "buy_dex":    buy_dex,
                "sell_dex":   sell_dex,
                "buy_price":  buy_price,
                "sell_price": sell_price,
                "gap_pct":    gap_pct,
                "profitable": gap_pct >= MIN_GAP_PCT,
                "liq_buy":    dex_prices[buy_dex]["liquidity"],
                "liq_sell":   dex_prices[sell_dex]["liquidity"],
            })

    return sorted(gaps, key=lambda x: x["gap_pct"], reverse=True)


def print_gap(g: dict):
    flag = ">>> ARB!" if g["profitable"] else "     "
    print(f"  {flag} {g['token']:6s}  "
          f"buy {g['buy_dex']:10s} ${g['buy_price']:.6f}  "
          f"sell {g['sell_dex']:10s} ${g['sell_price']:.6f}  "
          f"gap={g['gap_pct']:.3f}%  "
          f"liq=${g['liq_buy']:,.0f}/${g['liq_sell']:,.0f}")


def scan():
    print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Scanning DEX prices...")
    print(f"  DEXes: {', '.join(TARGET_DEXES)}")
    print(f"  Tokens: {', '.join(TOKENS.keys())}")
    print(f"  Min liquidity: ${MIN_LIQUIDITY_USD:,}  |  Min gap to flag: {MIN_GAP_PCT}%\n")

    all_gaps = []

    for token_name, token_mint in TOKENS.items():
        dex_prices = get_dex_prices(token_name, token_mint)

        if len(dex_prices) < 2:
            print(f"  {token_name:6s}  only found on {len(dex_prices)} DEX(es), skipping")
            continue

        dex_summary = ", ".join(f"{d}=${info['price']:.5f}" for d, info in dex_prices.items())
        print(f"  {token_name:6s}  found on: {dex_summary}")

        gaps = find_gaps(token_name, dex_prices)
        for g in gaps:
            print_gap(g)
            all_gaps.append(g)

        time.sleep(0.3)  # be gentle with API

    profitable = [g for g in all_gaps if g["profitable"]]
    print(f"\n{'='*70}")
    if profitable:
        print(f"FOUND {len(profitable)} PROFITABLE GAP(S):")
        for g in profitable:
            est_profit_1k = 1000 * (g["gap_pct"] / 100 - 0.0064)
            print(f"  {g['token']}: {g['gap_pct']:.3f}% gap → "
                  f"~${est_profit_1k:.2f} profit per $1,000 flash loan")
    else:
        if all_gaps:
            best = max(all_gaps, key=lambda x: x["gap_pct"])
            print(f"No profitable gaps found. Best: {best['token']} {best['gap_pct']:.3f}% "
                  f"({best['buy_dex']} vs {best['sell_dex']})")
        else:
            print("No multi-DEX pairs found.")

    return profitable


def run(loops: int = 1, delay_sec: int = 60):
    """Continuous monitoring. loops=0 = infinite."""
    print("Solana DEX-to-DEX Gap Monitor")
    print(f"Watching for gaps > {MIN_GAP_PCT}% (profitable after ~0.64% fees)")

    iteration = 0
    while loops == 0 or iteration < loops:
        iteration += 1
        profitable = scan()

        if loops == 0 or iteration < loops:
            print(f"\nNext scan in {delay_sec}s...")
            time.sleep(delay_sec)


if __name__ == "__main__":
    run(loops=1)
