"""
Solana Triangular Arbitrage Scanner
Uses Jupiter API to check circular paths: USDC → A → B → USDC

Jupiter aggregates all DEXes (Raydium, Orca, Meteora, etc.)
so each quote already reflects the best available price.

If output USDC > input USDC after 3 hops → arbitrage exists.

Fees: ~0.3% per swap on most DEXes = ~0.9% total for 3 hops
So minimum gap needed: >0.9% to be profitable.
"""

import requests
import time
import itertools
from datetime import datetime

# --- Config ---
USDC_MINT  = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
JUPITER_API = "https://lite-api.jup.ag/swap/v1"

# Test amount: 100 USDC (in micro-units, 6 decimals)
TEST_AMOUNT_USDC = 100
TEST_AMOUNT_RAW  = TEST_AMOUNT_USDC * 1_000_000  # 100_000_000

# Minimum net profit to report (after ~0.9% fees)
MIN_PROFIT_PCT = 0.3   # 0.3% net = realistic floor

# Slippage tolerance
SLIPPAGE_BPS = 30  # 0.3%

# Tokens to include in triangular paths
# Only liquid, high-volume tokens
TOKENS = {
    "SOL":   "So11111111111111111111111111111111111111112",
    "ETH":   "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs",
    "BTC":   "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E",
    "BONK":  "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",
    "JUP":   "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN",
    "RAY":   "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R",
    "PYTH":  "HZ1JovNiVvGrGs4K4mFmDn53o9HbqKJR6vFAVFTLBjBN",
    "WIF":   "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm",
    "JITO":  "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn",
    "MSOL":  "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So",
}


def get_quote(input_mint: str, output_mint: str, amount: int) -> dict | None:
    """Get best swap quote from Jupiter."""
    try:
        r = requests.get(f"{JUPITER_API}/quote", params={
            "inputMint":   input_mint,
            "outputMint":  output_mint,
            "amount":      amount,
            "slippageBps": SLIPPAGE_BPS,
            "onlyDirectRoutes": "false",
        }, timeout=5)
        if r.status_code != 200:
            return None
        return r.json()
    except Exception:
        return None


def check_triangle(token_a: str, token_b: str) -> dict | None:
    """
    Check: USDC → token_a → token_b → USDC
    Returns arb info if profitable, else None.
    """
    mint_a = TOKENS[token_a]
    mint_b = TOKENS[token_b]

    # Leg 1: USDC → A
    q1 = get_quote(USDC_MINT, mint_a, TEST_AMOUNT_RAW)
    if not q1:
        return None
    out1 = int(q1["outAmount"])

    # Leg 2: A → B
    q2 = get_quote(mint_a, mint_b, out1)
    if not q2:
        return None
    out2 = int(q2["outAmount"])

    # Leg 3: B → USDC
    q3 = get_quote(mint_b, USDC_MINT, out2)
    if not q3:
        return None
    out3 = int(q3["outAmount"])

    # Calculate profit
    profit_raw = out3 - TEST_AMOUNT_RAW
    profit_usdc = profit_raw / 1_000_000
    profit_pct  = (profit_raw / TEST_AMOUNT_RAW) * 100

    if profit_pct < MIN_PROFIT_PCT:
        return None

    return {
        "path":       f"USDC → {token_a} → {token_b} → USDC",
        "input_usdc": TEST_AMOUNT_USDC,
        "output_usdc": out3 / 1_000_000,
        "profit_usdc": profit_usdc,
        "profit_pct":  profit_pct,
        "route1": q1.get("routePlan", [{}])[0].get("swapInfo", {}).get("ammKey", "?")[:8],
        "route2": q2.get("routePlan", [{}])[0].get("swapInfo", {}).get("ammKey", "?")[:8],
        "route3": q3.get("routePlan", [{}])[0].get("swapInfo", {}).get("ammKey", "?")[:8],
    }


def check_triangle_full(token_a: str, token_b: str) -> dict:
    """Like check_triangle but always returns result (even if negative profit)."""
    mint_a = TOKENS[token_a]
    mint_b = TOKENS[token_b]

    q1 = get_quote(USDC_MINT, mint_a, TEST_AMOUNT_RAW)
    if not q1:
        return None
    out1 = int(q1["outAmount"])

    q2 = get_quote(mint_a, mint_b, out1)
    if not q2:
        return None
    out2 = int(q2["outAmount"])

    q3 = get_quote(mint_b, USDC_MINT, out2)
    if not q3:
        return None
    out3 = int(q3["outAmount"])

    profit_raw  = out3 - TEST_AMOUNT_RAW
    profit_usdc = profit_raw / 1_000_000
    profit_pct  = (profit_raw / TEST_AMOUNT_RAW) * 100

    return {
        "path":        f"USDC → {token_a} → {token_b} → USDC",
        "input_usdc":  TEST_AMOUNT_USDC,
        "output_usdc": out3 / 1_000_000,
        "profit_usdc": profit_usdc,
        "profit_pct":  profit_pct,
    }


def scan_once():
    """Run one full scan of all triangular paths."""
    token_names = list(TOKENS.keys())
    pairs = list(itertools.permutations(token_names, 2))

    print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Scanning {len(pairs)} paths...")

    found = []
    all_results = []

    for i, (a, b) in enumerate(pairs):
        result = check_triangle_full(a, b)
        if result:
            all_results.append(result)
            if result["profit_pct"] >= MIN_PROFIT_PCT:
                found.append(result)

        time.sleep(0.1)

        if (i + 1) % 20 == 0:
            print(f"  [{i+1}/{len(pairs)}] checked...", flush=True)

    return found, all_results


def print_arb(arb: dict):
    print(f"\n{'='*60}")
    print(f"PATH: {arb['path']}")
    print(f"  Input:  ${arb['input_usdc']:.2f} USDC")
    print(f"  Output: ${arb['output_usdc']:.4f} USDC")
    print(f"  Profit: ${arb['profit_usdc']:.4f}  ({arb['profit_pct']:.3f}%)")


def run(loops: int = 1, delay_sec: int = 30):
    """
    Run scanner in a loop.
    loops=0 means infinite.
    """
    print("Solana Triangular Arb Scanner")
    print(f"Test amount: ${TEST_AMOUNT_USDC} USDC")
    print(f"Min profit threshold: {MIN_PROFIT_PCT}%")
    print(f"Tokens: {', '.join(TOKENS.keys())}")

    iteration = 0
    while loops == 0 or iteration < loops:
        iteration += 1
        arbs, all_results = scan_once()

        if not arbs:
            print("  No arb found this round.")
            if all_results:
                top5 = sorted(all_results, key=lambda x: x["profit_pct"], reverse=True)[:5]
                print("\nTop 5 najbliže profitabilnih putanja:")
                for r in top5:
                    print(f"  {r['profit_pct']:+.3f}%  ${r['output_usdc']:.4f} out  {r['path']}")
        else:
            arbs.sort(key=lambda x: x["profit_pct"], reverse=True)
            print(f"\n>>> FOUND {len(arbs)} ARB OPPORTUNITIES!")
            for arb in arbs:
                print_arb(arb)

        if loops == 0 or iteration < loops:
            print(f"\nWaiting {delay_sec}s before next scan...")
            time.sleep(delay_sec)

    print("\nDone.")


if __name__ == "__main__":
    # Single scan by default
    # For continuous: run(loops=0, delay_sec=30)
    run(loops=1)
