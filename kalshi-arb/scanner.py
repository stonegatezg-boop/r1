"""
Kalshi Arbitrage Scanner
Scans Financial, Economic, Crypto, and Political markets for mispricings.

For mutually exclusive & exhaustive outcomes within an event:
  sum(YES_ask) should be ~$1.00.
  If sum(YES_ask) < $1.00, buying all YES costs less than the guaranteed $1 payout → arbitrage.
  Similarly for NO side: if sum(NO_ask) < (n-1) * $1.00, same logic.

Prices are in USD (0.0 – 1.0). Kalshi fee: ~7% of profit.
"""

import requests
import time
import base64
import json
from collections import defaultdict
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

# --- Config ---
KEY_ID = "b127c02b-7ec2-49c4-95ef-c845fb566ee1"
BASE_URL = "https://api.elections.kalshi.com/trade-api/v2"
PRIVATE_KEY_PEM = """-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEAw4rsMVYtMbt8tApfy/Nw14BF2hzMyueEFqHV9TX0iNjZy+it
U/6cjMpLyQ9elwOKyHHyfoWNF/4dUZjMZ2hS+XSiUJedEUNH7F3v+j1OV3Y17COh
Jpimp/TILxazRaqCji+3F9v12yGKNPhzbpkwJ6bpjjXLF+GbRS+yJOae2vV3oADz
aIezWjsd0zJwr0rW8OH+ZuQvLOiv29tC756W3eHdqmtsShv94df1UmCDcK1V7Fe6
j7YykarsQMn2YWp8AUtv2mTW0VbD7+PBvUtJ5bUY6E26k5M2wnaatVcwVGc90fgj
1xQ4M9NFuX5x5gotWlLaSfS+lSZImgvNB8l0WQIDAQABAoIBACKFST7JfaeIt5Jq
PXC6PKrSwqInkPDmL8+2CNlmCdJJ5CNHI6hPK/B/+yKW48ZJsgvCcAKtjZPVgPQJ
g1ZjGLjgwhHzvh8Qz2b3S3kULxsqK4lRXe78JnnCsT985K+xEyTKYCqmYpApquZA
kVJOWW26ngNE1GKWKczsR2kTzKoPOYTDMJVqP/d4VOBdh2+oiyhGzbFdHiddtR1R
a9+vqjlGJzonZBAzh1sTsMokartSIElkEC460V1l2smi2dTLwbI1e124n09rjMAT
8pgURNP3G+LgZXtM8Rcoca2DWCMumn0ISKuCrmMuLUzR5Z4nnNJw6u1q7FxBLs44
qfoF1h0CgYEAxLhWrGy5b7f3jUExDIimr4yV+sLQpJF7kXcScU+CdUCcmQOt27Ht
EIg0A1uxacdjhK5H0268Vbfg236F+MUEXl31KVsm0t8RXNaHaZ6zah4x+EVDkkg/
Dy1Gk0Y4ZGn6Xw3Y1N77/Evd40PnRWk1bgVcLO1a5V0tRIOnzCUR4pUCgYEA/nfB
QlzDTv8eDtIbxUWUjZlNXsKnb4kXgtZN9M9a4QW9I60BWFXbSX6L8juanog9YqRU
USGVpLXqyWUgN9WBgNO9ncbWv+OrrIebpRHmr5OmEZuPZXFFqgArVhb72Bn1hrcu
6KjzbEttcypAGefWBpWHiEaJ2ENlCA+yr+Gb/bUCgYAtsPtAtUgk8L/o6TlxRdQh
di/nvJQlhT0EPnnkI6mTflxhFf+txZfgfSJHnWaJwSwWRzybmV7ZMgpiMPMBIxGu
sXgeEPPlirZHr/RnzdqyTS0iE0Rsl6c96TA5SNgUSqFCrr6sQtaYdS6meMEg2Bz2
3vvX25F/MLMw9LtmqT2MOQKBgE3tkqumCNHaYvQa+BIzusiaWA1bAzeu/ho9UuZT
0frzbPbN9ol80YjyTh1Cj5lZE6Nvu7qU1GT6qQpAA9vVcLFpJrp4uC9Po7VUWh/1
GXZPex4NS56/T5w+LQdSRpHpcT1uP9lUVCen+b65A6RrUSn3BOiA4ZnvGbOcSxZ9
uu25AoGACN8NE3Yr36MzcAevDVbCWpWxn0RfCPv291kxHYbSjo4/YJdhISo47xgN
pHplryaLWSKzrqBWM+CyAv4amPxZyFKWxHZV4YuMMd+Vol1VMChcrUIw2ybQl3o4
vy6SnjbkbqXLA/z+BubVsh2FhyuBywbpMlSIA2F2HvIHjOco0R8=
-----END RSA PRIVATE KEY-----"""

TARGET_CATEGORIES = {"Financials", "Economics", "Crypto", "Politics", "Elections"}
FEE_PCT = 0.07         # Kalshi fee on profit
MIN_NET_PROFIT = 0.01  # minimum net profit in dollars to report ($0.01)
MIN_LIQUIDITY = 0.0    # skip markets with zero dollar liquidity

_pk = serialization.load_pem_private_key(PRIVATE_KEY_PEM.strip().encode(), password=None)


def make_headers(method: str, path: str) -> dict:
    ts = str(int(time.time() * 1000))
    msg = (ts + method.upper() + f"/trade-api/v2{path}").encode()
    sig = _pk.sign(
        msg,
        padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=padding.PSS.DIGEST_LENGTH),
        hashes.SHA256(),
    )
    return {
        "KALSHI-ACCESS-KEY": KEY_ID,
        "KALSHI-ACCESS-TIMESTAMP": ts,
        "KALSHI-ACCESS-SIGNATURE": base64.b64encode(sig).decode(),
        "Content-Type": "application/json",
    }


def api_get(path: str, params: dict = None):
    r = requests.get(f"{BASE_URL}{path}", headers=make_headers("GET", path), params=params)
    if r.status_code != 200:
        return None
    return r.json()


def get_target_series():
    """Return tickers of all series in target categories."""
    data = api_get("/series")
    if not data:
        return []
    return [s["ticker"] for s in data.get("series", []) if s.get("category") in TARGET_CATEGORIES]


def get_markets_for_series(series_ticker: str) -> list:
    """Fetch all open markets for a given series."""
    markets = []
    cursor = None
    while True:
        params = {"series_ticker": series_ticker, "status": "open", "limit": 200}
        if cursor:
            params["cursor"] = cursor
        data = api_get("/markets", params=params)
        if not data:
            break
        batch = data.get("markets", [])
        markets.extend(batch)
        cursor = data.get("cursor")
        if not cursor or len(batch) < 200:
            break
    return markets


def price(m: dict, side: str) -> float | None:
    """Get ask price for YES or NO side as float, or None if unavailable."""
    key = f"{side}_ask_dollars"
    v = m.get(key)
    if v is None:
        return None
    try:
        f = float(v)
        return f if f > 0 else None
    except (ValueError, TypeError):
        return None


def check_event_arb(event_ticker: str, markets: list) -> list:
    """Check YES-sum and NO-sum arbitrage for mutually exclusive markets in this event."""
    results = []

    # Only markets with valid YES and NO asks and non-zero liquidity
    valid = []
    for m in markets:
        ya = price(m, "yes")
        na = price(m, "no")
        if ya is None or na is None:
            continue
        liq = float(m.get("liquidity_dollars") or 0)
        if liq <= MIN_LIQUIDITY:
            continue
        valid.append(m)

    if len(valid) < 2:
        return results

    yes_sum = sum(price(m, "yes") for m in valid)
    n = len(valid)

    # Buy-all-YES arb: payout = $1.00, cost = yes_sum
    if yes_sum < 1.00:
        gross = 1.00 - yes_sum
        net = gross * (1 - FEE_PCT)
        if net >= MIN_NET_PROFIT:
            results.append({
                "type": "BUY_ALL_YES",
                "event": event_ticker,
                "legs": [(m["ticker"], price(m, "yes"), m.get("title", "")[:70]) for m in valid],
                "yes_sum": yes_sum,
                "gross": gross,
                "net": net,
            })

    # Buy-all-NO arb: payout = (n-1) * $1.00, cost = no_sum
    no_valid = [m for m in valid if price(m, "no") is not None]
    if len(no_valid) == n:
        no_sum = sum(price(m, "no") for m in no_valid)
        expected = (n - 1) * 1.00
        if no_sum < expected:
            gross = expected - no_sum
            net = gross * (1 - FEE_PCT)
            if net >= MIN_NET_PROFIT:
                results.append({
                    "type": "BUY_ALL_NO",
                    "event": event_ticker,
                    "legs": [(m["ticker"], price(m, "no"), m.get("title", "")[:70]) for m in no_valid],
                    "no_sum": no_sum,
                    "expected": expected,
                    "gross": gross,
                    "net": net,
                })

    return results


def print_arb(arb: dict):
    print(f"\n{'='*65}")
    print(f"[{arb['type']}]  Event: {arb['event']}")
    print(f"  Gross: ${arb['gross']:.4f}  |  Net after ~7% fee: ${arb['net']:.4f}")
    if arb["type"] == "BUY_ALL_YES":
        print(f"  Sum YES asks: ${arb['yes_sum']:.4f}  (< $1.00)")
    else:
        print(f"  Sum NO asks: ${arb['no_sum']:.4f}  (< ${arb['expected']:.2f} expected)")
    print("  Legs:")
    for ticker, ask, title in arb["legs"]:
        print(f"    {ticker:45s}  ${ask:.4f}  {title}")


def scan():
    print("Fetching target series (Financials, Economics, Crypto, Politics, Elections)...")
    series_tickers = get_target_series()
    print(f"Found {len(series_tickers)} target series\n")

    all_markets_by_event = defaultdict(list)
    total_markets = 0

    for i, st in enumerate(series_tickers):
        markets = get_markets_for_series(st)
        if markets:
            print(f"[{i+1}/{len(series_tickers)}] {st}: {len(markets)} markets", flush=True)
            total_markets += len(markets)
            for m in markets:
                et = m.get("event_ticker")
                if et:
                    all_markets_by_event[et].append(m)

    print(f"\nTotal: {total_markets} markets across {len(all_markets_by_event)} events")
    print("Scanning for arbitrage...\n")

    all_arbs = []
    for et, mlist in all_markets_by_event.items():
        arbs = check_event_arb(et, mlist)
        all_arbs.extend(arbs)

    if not all_arbs:
        print("No arbitrage opportunities found.")
    else:
        all_arbs.sort(key=lambda x: x["net"], reverse=True)
        print(f"Found {len(all_arbs)} potential arbitrage opportunities:")
        for arb in all_arbs:
            print_arb(arb)

    return all_arbs


if __name__ == "__main__":
    scan()
