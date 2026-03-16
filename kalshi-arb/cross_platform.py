"""
Cross-Platform Arbitrage Scanner: Kalshi ↔ Polymarket
Matches equivalent markets and flags price differences.

Strategy: Find same event on both platforms, buy YES on the cheaper one.
This is NOT risk-free arb (both legs must resolve YES/NO the same way),
but it captures the price divergence between the two platforms.

Fees: Kalshi ~7%, Polymarket ~2%
Min gap needed: ~9% total to profit after both fees.
"""

import requests
import time
import base64
import json
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

# --- Kalshi Auth ---
KEY_ID = "b127c02b-7ec2-49c4-95ef-c845fb566ee1"
KALSHI_BASE = "https://api.elections.kalshi.com/trade-api/v2"
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

POLY_BASE = "https://gamma-api.polymarket.com"

# Min price gap (after both fees) to flag as opportunity
# Kalshi fee: 7%, Polymarket fee: 2% → need > 9% gap to profit
MIN_GAP = 0.09

_pk = serialization.load_pem_private_key(PRIVATE_KEY_PEM.strip().encode(), password=None)


def kalshi_headers(method: str, path: str) -> dict:
    ts = str(int(time.time() * 1000))
    msg = (ts + method.upper() + "/trade-api/v2" + path).encode()
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


def kalshi_get(path: str, params: dict = None):
    r = requests.get(f"{KALSHI_BASE}{path}", headers=kalshi_headers("GET", path), params=params)
    return r.json() if r.status_code == 200 else None


def poly_get(path: str, params: dict = None):
    r = requests.get(f"{POLY_BASE}{path}", params=params)
    return r.json() if r.status_code == 200 else None


# ---------------------------------------------------------------------------
# Kalshi data fetchers
# ---------------------------------------------------------------------------

def get_kalshi_btc_markets():
    """Fetch Kalshi BTC daily/monthly price bracket markets."""
    data = kalshi_get("/markets", {"series_ticker": "KXBTCD", "status": "open", "limit": 200})
    return data.get("markets", []) if data else []


def get_kalshi_eth_markets():
    data = kalshi_get("/markets", {"series_ticker": "KXETH", "status": "open", "limit": 200})
    return data.get("markets", []) if data else []


def get_kalshi_fed_markets():
    data = kalshi_get("/markets", {"series_ticker": "KXFEDDECISION", "status": "open", "limit": 200})
    return data.get("markets", []) if data else []


def get_kalshi_cpi_markets():
    data = kalshi_get("/markets", {"series_ticker": "KXCPI", "status": "open", "limit": 200})
    return data.get("markets", []) if data else []


# ---------------------------------------------------------------------------
# Polymarket data fetchers
# ---------------------------------------------------------------------------

def get_poly_events_by_keyword(keyword: str, limit: int = 50) -> list:
    """Fetch Polymarket events matching a keyword in the title."""
    results = []
    offset = 0
    while len(results) < limit:
        batch = poly_get("/events", {
            "limit": 100, "active": "true", "closed": "false", "offset": offset
        })
        if not batch:
            break
        for e in batch:
            if keyword.lower() in e.get("title", "").lower():
                results.append(e)
        offset += 100
        if len(batch) < 100:
            break
    return results[:limit]


# ---------------------------------------------------------------------------
# Cross-platform comparison
# ---------------------------------------------------------------------------

def compare_btc(kalshi_markets: list, poly_events: list):
    """
    Match Kalshi BTC bracket markets with Polymarket 'Bitcoin above X?' markets.
    Both platforms have markets like 'Will BTC be above $80k?' — compare prices.
    """
    matches = []

    # Extract Polymarket BTC bracket markets
    poly_btc = []
    for e in poly_events:
        for m in e.get("markets", []):
            q = m.get("question", "").lower()
            ask = m.get("bestAsk")
            liq = float(m.get("liquidity") or 0)
            if ask and liq > 100 and ("bitcoin" in q or "btc" in q) and ("above" in q or "reach" in q or "hit" in q):
                # Extract threshold from question
                import re
                nums = re.findall(r'\$?([\d,]+)k?', q)
                if nums:
                    threshold_str = nums[-1].replace(',', '')
                    try:
                        threshold = int(threshold_str)
                        if "k" in q[q.find(threshold_str):q.find(threshold_str)+5]:
                            threshold *= 1000
                        if threshold > 1000:  # valid BTC price range
                            poly_btc.append({
                                "question": m.get("question", ""),
                                "threshold": threshold,
                                "ask": float(ask),
                                "bid": float(m.get("bestBid") or 0),
                                "liquidity": liq,
                                "platform": "Polymarket",
                            })
                    except (ValueError, IndexError):
                        pass

    # Extract Kalshi BTC bracket markets
    kalshi_btc = []
    for m in kalshi_markets:
        title = m.get("title", "").lower()
        ask = m.get("yes_ask_dollars")
        liq = float(m.get("liquidity_dollars") or 0)
        if ask and liq > 10:
            import re
            nums = re.findall(r'\$?([\d,]+)', title)
            if nums:
                threshold_str = nums[-1].replace(',', '')
                try:
                    threshold = int(threshold_str)
                    if threshold > 1000:
                        kalshi_btc.append({
                            "question": m.get("title", ""),
                            "threshold": threshold,
                            "ask": float(ask),
                            "bid": float(m.get("yes_bid_dollars") or 0),
                            "liquidity": liq,
                            "platform": "Kalshi",
                        })
                except ValueError:
                    pass

    # Match by threshold
    for k in kalshi_btc:
        for p in poly_btc:
            if abs(k["threshold"] - p["threshold"]) < 500:  # within $500
                gap = abs(k["ask"] - p["ask"])
                if gap >= MIN_GAP:
                    cheaper = k if k["ask"] < p["ask"] else p
                    dearer = p if k["ask"] < p["ask"] else k
                    matches.append({
                        "type": "BTC_BRACKET",
                        "threshold": k["threshold"],
                        "cheaper_platform": cheaper["platform"],
                        "cheaper_ask": cheaper["ask"],
                        "dearer_platform": dearer["platform"],
                        "dearer_ask": dearer["ask"],
                        "gap": gap,
                        "gap_after_fees": gap - 0.09,
                        "kalshi_q": k["question"][:60],
                        "poly_q": p["question"][:60],
                        "kalshi_liq": k["liquidity"],
                        "poly_liq": p["liquidity"],
                    })

    return sorted(matches, key=lambda x: x["gap"], reverse=True)


def compare_generic(topic: str, kalshi_markets: list, poly_events: list):
    """
    Generic comparison: show Kalshi and Polymarket markets on same topic side by side.
    Flags where price difference > MIN_GAP.
    """
    results = []

    poly_markets = []
    for e in poly_events:
        for m in e.get("markets", []):
            ask = m.get("bestAsk")
            liq = float(m.get("liquidity") or 0)
            if ask and liq > 100:
                poly_markets.append({
                    "question": m.get("question", ""),
                    "ask": float(ask),
                    "liquidity": liq,
                    "platform": "Polymarket",
                })

    kalshi_filtered = []
    for m in kalshi_markets:
        ask = m.get("yes_ask_dollars")
        liq = float(m.get("liquidity_dollars") or 0)
        if ask and liq > 10:
            kalshi_filtered.append({
                "question": m.get("title", ""),
                "ask": float(ask),
                "liquidity": liq,
                "platform": "Kalshi",
            })

    return {
        "topic": topic,
        "kalshi_count": len(kalshi_filtered),
        "poly_count": len(poly_markets),
        "kalshi_sample": kalshi_filtered[:5],
        "poly_sample": poly_markets[:5],
    }


def print_match(m: dict):
    print(f"\n{'='*65}")
    print(f"[{m['type']}]  Threshold: ${m['threshold']:,}")
    print(f"  BUY on {m['cheaper_platform']:10s} → {m['cheaper_ask']:.3f}")
    print(f"  SELL on {m['dearer_platform']:10s} → {m['dearer_ask']:.3f}")
    print(f"  Raw gap: {m['gap']:.3f}  |  After fees (~9%): {m['gap_after_fees']:.3f}")
    print(f"  Kalshi liq: ${m['kalshi_liq']:,.0f}  |  Poly liq: ${m['poly_liq']:,.0f}")
    print(f"  Kalshi: {m['kalshi_q']}")
    print(f"  Poly:   {m['poly_q']}")


def scan():
    print("=" * 65)
    print("CROSS-PLATFORM SCANNER: Kalshi ↔ Polymarket")
    print("=" * 65)

    # --- BTC ---
    print("\n[1/4] Fetching BTC markets...")
    kalshi_btc = get_kalshi_btc_markets()
    poly_btc_events = get_poly_events_by_keyword("Bitcoin")
    print(f"  Kalshi BTC: {len(kalshi_btc)} markets")
    print(f"  Polymarket BTC events: {len(poly_btc_events)}")

    btc_matches = compare_btc(kalshi_btc, poly_btc_events)
    if btc_matches:
        print(f"\n  >>> {len(btc_matches)} BTC cross-platform opportunities:")
        for m in btc_matches[:5]:
            print_match(m)
    else:
        print("  No BTC gap > 9% found")

    # --- ETH ---
    print("\n[2/4] Fetching ETH markets...")
    kalshi_eth = get_kalshi_eth_markets()
    poly_eth_events = get_poly_events_by_keyword("Ethereum")
    print(f"  Kalshi ETH: {len(kalshi_eth)} markets")
    print(f"  Polymarket ETH events: {len(poly_eth_events)}")

    # --- FED ---
    print("\n[3/4] Fetching Fed rate markets...")
    kalshi_fed = get_kalshi_fed_markets()
    poly_fed_events = get_poly_events_by_keyword("Fed rate")
    fed_info = compare_generic("Fed Rate", kalshi_fed, poly_fed_events)
    print(f"  Kalshi: {fed_info['kalshi_count']} liquid markets")
    print(f"  Polymarket: {fed_info['poly_count']} liquid markets")
    print("\n  Kalshi Fed samples:")
    for m in fed_info['kalshi_sample']:
        print(f"    ask={m['ask']:.3f}  {m['question'][:65]}")
    print("\n  Polymarket Fed samples:")
    for m in fed_info['poly_sample']:
        print(f"    ask={m['ask']:.3f}  {m['question'][:65]}")

    # --- CPI ---
    print("\n[4/4] Fetching CPI/Inflation markets...")
    kalshi_cpi = get_kalshi_cpi_markets()
    poly_cpi_events = get_poly_events_by_keyword("Inflation")
    cpi_info = compare_generic("CPI", kalshi_cpi, poly_cpi_events)
    print(f"  Kalshi: {cpi_info['kalshi_count']} liquid markets")
    print(f"  Polymarket: {cpi_info['poly_count']} liquid markets")
    print("\n  Kalshi CPI samples:")
    for m in cpi_info['kalshi_sample']:
        print(f"    ask={m['ask']:.3f}  {m['question'][:65]}")
    print("\n  Polymarket CPI samples:")
    for m in cpi_info['poly_sample']:
        print(f"    ask={m['ask']:.3f}  {m['question'][:65]}")

    print("\n\nDone.")


if __name__ == "__main__":
    scan()
