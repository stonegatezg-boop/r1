import requests
import time
import base64
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

# Load private key
_private_key = serialization.load_pem_private_key(
    PRIVATE_KEY_PEM.strip().encode(), password=None
)

def make_headers(method: str, path: str) -> dict:
    timestamp = str(int(time.time() * 1000))
    full_path = f"/trade-api/v2{path}"
    message = (timestamp + method.upper() + full_path).encode()
    signature = _private_key.sign(
        message,
        padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=padding.PSS.DIGEST_LENGTH),
        hashes.SHA256()
    )
    return {
        "KALSHI-ACCESS-KEY": KEY_ID,
        "KALSHI-ACCESS-TIMESTAMP": timestamp,
        "KALSHI-ACCESS-SIGNATURE": base64.b64encode(signature).decode(),
        "Content-Type": "application/json"
    }

def get(path: str, params: dict = None) -> tuple:
    headers = make_headers("GET", path)
    r = requests.get(f"{BASE_URL}{path}", headers=headers, params=params)
    return r.status_code, r.json() if r.text else {}

def get_markets(limit=200, cursor=None, status="open") -> list:
    """Dohvati sve aktivne markete (paginirano)."""
    all_markets = []
    while True:
        params = {"limit": limit, "status": status}
        if cursor:
            params["cursor"] = cursor
        code, data = get("/markets", params=params)
        if code != 200:
            print(f"Error {code}: {data}")
            break
        markets = data.get("markets", [])
        all_markets.extend(markets)
        cursor = data.get("cursor")
        if not cursor or len(markets) < limit:
            break
    return all_markets

if __name__ == "__main__":
    print("Dohvaćam markete...")
    markets = get_markets()
    print(f"Ukupno aktivnih marketa: {len(markets)}\n")

    # Prikaži primjer jednog marketa
    if markets:
        m = markets[0]
        print("Primjer marketa:")
        print(f"  ticker:      {m.get('ticker')}")
        print(f"  title:       {m.get('title')}")
        print(f"  yes_bid:     {m.get('yes_bid')}")
        print(f"  yes_ask:     {m.get('yes_ask')}")
        print(f"  no_bid:      {m.get('no_bid')}")
        print(f"  no_ask:      {m.get('no_ask')}")
        print(f"  event_ticker:{m.get('event_ticker')}")
        print(f"  close_time:  {m.get('close_time')}")
