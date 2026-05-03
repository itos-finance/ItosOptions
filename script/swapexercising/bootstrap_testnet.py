#!/usr/bin/env python3
"""bootstrap_testnet.py — single-shot orchestrator for the SwapExercising flow.

Pulls token + factory + vault addresses from
https://itos-finance.tome.center/reference/addresses, deploys (or reuses)
shared infra (V4 PoolManager, V3 factory, SwapExercisingFunder), seeds V4/V3
liquidity for each USDC-quoted pair at current Bybit spot, and funds the
deployer / MM / funder by calling `mint(address,uint256)` directly on each
token (token addresses come from the website parse, mints are verified via
balance delta to surface silent no-ops).

Idempotent: a small machine-managed state file at `cache/swapexercising-state.json`
records deployed contract addresses + per-pair init/seed flags so reruns skip
already-completed steps. Funding state is *not* persisted — bootstrap queries
on-chain `balanceOf` and tops up only when below a threshold.

Math note (sqrtPriceX96):
    For a Uniswap V3/V4 pool with token0 < token1 (raw address compare):
        raw_price = (price_token1_per_token0_human) * 10^(dec1 - dec0)
        sqrtPriceX96 = floor(sqrt(raw_price) * 2^96)
    USDC sorts numerically below WETH/WBTC/MON on Monad testnet, so for every
    pair here token0 = USDC; we invert the human price (1 / ETHUSDT, etc.).

Usage:
    bootstrap_testnet.py
        --mm 0x...                  # market-maker EOA (gets DEFAULT_ADMIN + SIGNER on funder)
        [--rpc-url URL]             # default: env RPC_URL
        [--private-key 0x...]       # default: env DEPLOYER_PRIVATE_KEY
        [--addresses-url URL]       # override the Itos page
        [--price-override 'ETH=2300,BTC=80000,MON=0.03']
        [--fresh]                   # ignore state file, redeploy everything
        [--state PATH]              # default: cache/swapexercising-state.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[2]  # contracts/
CACHE = ROOT / "cache"

DEFAULT_ADDRESSES_URL = "https://itos-finance.tome.center/reference/addresses"

# Per-token mint amounts (raw, including decimals). Threshold is half so reruns
# skip the mint when balances are healthy without forcing the user to keep state.
MINT_AMOUNTS_RAW = {
    "WETH": 1000 * 10**18,
    "USDC": 2_000_000 * 10**6,
    "WBTC": 10 * 10**8,
    "MON":  100_000 * 10**18,
}
BALANCE_THRESHOLDS_RAW = {sym: amt // 2 for sym, amt in MINT_AMOUNTS_RAW.items()}

# Per-pair Bybit symbol mapping. New pairs the page lists for which we have no
# entry here will be flagged but skipped.
BYBIT_SYMBOL = {"WETH": "ETHUSDT", "WBTC": "BTCUSDT", "MON": "MONUSDT"}

# Aliases — the page sometimes labels WBTC sections as "BTC".
PAGE_RISK_ALIASES = {"WBTC": ["WBTC", "BTC"]}

V3_HOOK_SENTINEL = "0x0000000000000000000000000000000000003333"

# Tick range half-width and target USD per side for LP seeding.
LP_TICK_SPAN = 20000
LP_USD_PER_SIDE = 10_000


# ---------------------------------------------------------------------------
# argparse + helpers
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mm", required=True, help="market-maker EOA address")
    p.add_argument("--rpc-url", default=os.environ.get("RPC_URL"))
    p.add_argument("--private-key", default=os.environ.get("DEPLOYER_PRIVATE_KEY"))
    p.add_argument("--addresses-url", default=DEFAULT_ADDRESSES_URL)
    p.add_argument("--price-override", default=None,
                   help="e.g. 'ETH=2300,BTC=80000,MON=0.03'")
    p.add_argument("--fresh", action="store_true",
                   help="ignore existing state and redeploy everything")
    p.add_argument("--state", default=str(CACHE / "swapexercising-state.json"))
    args = p.parse_args()
    if not args.rpc_url:
        p.error("--rpc-url or env RPC_URL required")
    if not args.private_key:
        p.error("--private-key or env DEPLOYER_PRIVATE_KEY required")
    if not re.match(r"^0x[0-9a-fA-F]{40}$", args.mm):
        p.error(f"invalid --mm address: {args.mm}")
    return args


def load_state(path: str, fresh: bool) -> dict:
    p = Path(path)
    if fresh or not p.exists():
        return {}
    return json.loads(p.read_text())


def save_state(path: str, state: dict) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, indent=2) + "\n")


def fetch(url: str, timeout: int = 5, retries: int = 1) -> str:
    last_err: Optional[Exception] = None
    for _ in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8")
        except Exception as e:
            last_err = e
    raise RuntimeError(f"fetch failed for {url}: {last_err}")


# ---------------------------------------------------------------------------
# Page parsing
# ---------------------------------------------------------------------------

# Page format (markdown tables embedded in HTML body):
#   | `OPairFactory` | `0x...` |
#   | `USDC` (cash)  | `0x...` | 6 decimals. |
#   ### WETH / USDC expiring YYYY-MM-DD
#   | Option | Strike | Address |
#   |--------|--------|---------|
#   | Put    | $1,500 | `0x...` |
FACTORY_RE = re.compile(r"\|\s*`OPairFactory`\s*\|\s*`(0x[0-9a-fA-F]{40})`")
TOKEN_ROW_RE = re.compile(
    r"\|\s*`([A-Z]+)`[^|]*\|\s*`(0x[0-9a-fA-F]{40})`\s*\|"
)
SECTION_RE = re.compile(
    r"###\s+(\w+)\s*/\s*(\w+)\s+expiring\s+(\d{4}-\d{2}-\d{2})\s*\n+"
    r"\|\s*Option\s*\|\s*Strike\s*\|\s*Address\s*\|\s*\n"
    r"\|[\s\-|]+\n"
    r"((?:\|.*\n)+)"
)
SECTION_ROW_RE = re.compile(
    r"\|\s*(Put|Call)\s*\|\s*\$?([\d,.]+)\s*\|\s*`(0x[0-9a-fA-F]{40})`\s*\|"
)


def parse_page(html: str) -> dict:
    fm = FACTORY_RE.search(html)
    if not fm:
        raise RuntimeError("OPairFactory address not found on page")
    factory = fm.group(1)

    tokens: dict[str, str] = {}
    for m in TOKEN_ROW_RE.finditer(html):
        symbol_field, addr = m.group(1), m.group(2)
        # symbol field can be "WBTC/BTC"; normalise to first half
        symbol = symbol_field.split("/")[0]
        tokens.setdefault(symbol, addr)

    vaults: dict[tuple[str, str], list[dict]] = {}
    for sec in SECTION_RE.finditer(html):
        risk, cash, expiry = sec.group(1), sec.group(2), sec.group(3)
        for row in SECTION_ROW_RE.finditer(sec.group(4)):
            kind, strike_str, addr = row.group(1), row.group(2), row.group(3)
            vaults.setdefault((risk, cash), []).append({
                "expiry": expiry,
                "strike": float(strike_str.replace(",", "")),
                "isCall": kind == "Call",
                "address": addr,
            })

    return {"factory": factory, "tokens": tokens, "vaults": vaults}


# ---------------------------------------------------------------------------
# cast / forge wrappers
# ---------------------------------------------------------------------------

def run(cmd: list[str], extra_env: Optional[dict] = None,
        check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        cmd, cwd=ROOT, env=env, check=check, text=True,
        capture_output=capture,
    )


def cast_wallet_address(private_key: str, rpc_url: str) -> str:
    out = run(["cast", "wallet", "address", "--private-key", private_key]).stdout
    return out.strip()


def cast_call_uint(rpc_url: str, target: str, sig: str, *args: str) -> int:
    cmd = ["cast", "call", "--rpc-url", rpc_url, target, sig, *args]
    out = run(cmd).stdout.strip()
    # cast appends a scientific-notation alias for big numbers, e.g.
    # "999992236816326196868746 [9.999e23]". Take the first token only.
    if out:
        out = out.split()[0]
    return int(out, 0) if out.startswith("0x") else int(out)


def token_decimals(rpc_url: str, addr: str) -> int:
    return cast_call_uint(rpc_url, addr, "decimals()(uint8)")


def token_balance(rpc_url: str, token: str, account: str) -> int:
    return cast_call_uint(rpc_url, token, "balanceOf(address)(uint256)", account)


def cast_code(rpc_url: str, addr: str) -> str:
    """Returns the deployed bytecode at `addr`, or empty string if none."""
    out = run(["cast", "code", "--rpc-url", rpc_url, addr]).stdout.strip()
    return "" if out in ("", "0x") else out


def cast_send(rpc_url: str, private_key: str, target: str, sig: str, *args: str) -> None:
    """Sends a tx and raises if cast reports a non-success receipt.

    Note: cast send exits 0 even when the target has no code (the EVM accepts
    such txs as no-ops). Callers that need to confirm the call did something
    (e.g. mint actually happened) must verify post-state separately.
    """
    cmd = ["cast", "send", "--rpc-url", rpc_url, "--private-key", private_key,
           target, sig, *args]
    run(cmd)


def fetch_spot(symbol_pair: str, override: Optional[float]) -> float:
    if override is not None:
        return override
    body = fetch(
        f"https://api.bybit.com/v5/market/tickers?category=spot&symbol={symbol_pair}",
        timeout=5, retries=1,
    )
    data = json.loads(body)
    return float(data["result"]["list"][0]["lastPrice"])


def parse_price_override(s: Optional[str]) -> dict[str, float]:
    if not s:
        return {}
    out: dict[str, float] = {}
    for part in s.split(","):
        k, v = part.split("=")
        out[k.strip().upper()] = float(v.strip())
    return out


# ---------------------------------------------------------------------------
# Math: tick range + sqrtPriceX96 + token amounts per liquidity
# ---------------------------------------------------------------------------

def compute_pool(human_token1_per_token0: float, dec0: int, dec1: int,
                 tick_spacing: int = 10, span: int = LP_TICK_SPAN,
                 usd_per_side: float = LP_USD_PER_SIDE) -> dict:
    raw = human_token1_per_token0 * (10 ** dec1) / (10 ** dec0)
    sqrtP = math.sqrt(raw)
    sqrtX96 = int(sqrtP * (1 << 96))
    cur_tick = round(math.log(raw) / math.log(1.0001))
    tl = ((cur_tick - span) // tick_spacing) * tick_spacing
    tu = ((cur_tick + span + (tick_spacing - 1)) // tick_spacing) * tick_spacing
    sqrtL = math.sqrt(1.0001) ** tl
    sqrtU = math.sqrt(1.0001) ** tu
    amt0_per_L = (sqrtU - sqrtP) / (sqrtP * sqrtU)
    # amt1_per_L = sqrtP - sqrtL  # not needed; sized off USDC side
    usd0_per_L = amt0_per_L * (10 ** -dec0)  # USDC at $1
    liquidity = int(usd_per_side / usd0_per_L)
    return {
        "sqrtPriceX96": sqrtX96,
        "tickLower": tl,
        "tickUpper": tu,
        "liquidity": liquidity,
        "currentTick": cur_tick,
    }


# ---------------------------------------------------------------------------
# Forge step runners
# ---------------------------------------------------------------------------

OUT_RE = re.compile(r"^\s*OUT:([A-Z0-9_]+)=\s*(.+?)\s*$", re.MULTILINE)


def run_forge(script_rel: str, env: dict, rpc_url: str, private_key: str) -> dict[str, str]:
    """Runs `forge script` with --broadcast, returns dict of OUT:KEY=VALUE pairs from stdout."""
    # Several helper scripts (Seed*, Swap*) declare an inline helper contract
    # alongside the entry-point contract; forge needs --tc to disambiguate.
    # Convention: contract name == file stem with the trailing ".s" stripped
    # (e.g. SeedV4Liquidity.s.sol → SeedV4Liquidity).
    contract = Path(script_rel).name.removesuffix(".sol").removesuffix(".s")
    cmd = [
        "forge", "script", script_rel,
        "--tc", contract,
        "--rpc-url", rpc_url,
        "--private-key", private_key,
        "--broadcast",
        "--slow",  # serializes broadcasts so nonces line up
    ]
    cp = run(cmd, extra_env=env)
    out = cp.stdout + "\n" + cp.stderr
    matches = {}
    for m in OUT_RE.finditer(out):
        matches[m.group(1)] = m.group(2).strip()
    return matches


# ---------------------------------------------------------------------------
# Bootstrap pipeline
# ---------------------------------------------------------------------------

def ensure_funded(rpc_url: str, private_key: str, account: str, label: str,
                  tokens: dict[str, str], fresh: bool) -> None:
    """Mints any token below threshold to `account`, verifying each mint actually landed.

    Token addresses come from `tokens` (the website-parsed map) so we mint the same
    tokens the deployed contracts use. Each mint is verified by reading balance
    before/after — protects against silent no-ops (e.g. wrong RPC where the token
    address has no code, or a token without a public mint() function).
    """
    for sym, mint_amount in MINT_AMOUNTS_RAW.items():
        if sym not in tokens:
            continue
        token_addr = tokens[sym]
        threshold = BALANCE_THRESHOLDS_RAW[sym]

        bal_before = token_balance(rpc_url, token_addr, account)
        if not fresh and bal_before >= threshold:
            print(f"  {label} {sym} ({account}): {bal_before} >= {threshold}, skip")
            continue

        if not cast_code(rpc_url, token_addr):
            raise RuntimeError(
                f"{sym} address {token_addr} has no code on this RPC. "
                f"Wrong network? (rpc_url={rpc_url})"
            )

        print(f"  minting {sym} to {label} ({account})")
        cast_send(rpc_url, private_key, token_addr,
                  "mint(address,uint256)", account, str(mint_amount))

        bal_after = token_balance(rpc_url, token_addr, account)
        if bal_after < bal_before + mint_amount:
            raise RuntimeError(
                f"{sym} mint to {account} did not increase balance as expected: "
                f"before={bal_before} after={bal_after} expected_delta={mint_amount}"
            )
        print(f"    {sym}: {bal_before} -> {bal_after}")


def main() -> int:
    args = parse_args()
    state = load_state(args.state, args.fresh)
    overrides = parse_price_override(args.price_override)
    chain_id = "10143"  # bootstrap is monad-testnet-only for now

    # 1. Page fetch + parse
    print(f"== Fetching {args.addresses_url}")
    page = fetch(args.addresses_url, timeout=10, retries=1)
    parsed = parse_page(page)
    factory = parsed["factory"]
    tokens = parsed["tokens"]
    vaults = parsed["vaults"]
    print(f"   OPairFactory: {factory}")
    print(f"   Tokens:       {', '.join(sorted(tokens.keys()))}")
    if not vaults:
        print("WARN: no vaults parsed from page")

    # 2. Decimals via cast
    print("== Querying token decimals on-chain")
    decimals = {sym: token_decimals(args.rpc_url, addr) for sym, addr in tokens.items()}
    for sym, d in decimals.items():
        print(f"   {sym}: {d}")

    # 3. Deployer address + funding
    deployer = cast_wallet_address(args.private_key, args.rpc_url)
    print(f"== Deployer: {deployer}")
    ensure_funded(args.rpc_url, args.private_key, deployer, "deployer", tokens, args.fresh)

    # 4. Bybit spot per known pair → price plan
    print("== Computing pool plans (sqrtPriceX96 + LP range + liquidity)")
    cash_sym = "USDC"
    pair_plans: dict[str, dict] = {}
    for risk_sym in BYBIT_SYMBOL:
        if risk_sym not in tokens or cash_sym not in tokens:
            print(f"   skip {risk_sym}/{cash_sym}: token address missing")
            continue
        spot = fetch_spot(BYBIT_SYMBOL[risk_sym], overrides.get(_short(risk_sym)))
        risk_addr = tokens[risk_sym]
        cash_addr = tokens[cash_sym]
        # Token0 is the lower-address token. price is token1_human per token0_human.
        if risk_addr.lower() < cash_addr.lower():
            t0_addr, t1_addr = risk_addr, cash_addr
            d0, d1 = decimals[risk_sym], decimals[cash_sym]
            human_t1_per_t0 = spot          # 1 risk → spot cash
        else:
            t0_addr, t1_addr = cash_addr, risk_addr
            d0, d1 = decimals[cash_sym], decimals[risk_sym]
            human_t1_per_t0 = 1.0 / spot    # 1 cash → 1/spot risk
        plan = compute_pool(human_t1_per_t0, d0, d1)
        pair_plans[risk_sym] = {
            "risk_addr": risk_addr, "cash_addr": cash_addr,
            "t0": t0_addr, "t1": t1_addr,
            "spot": spot, **plan,
        }
        print(
            f"   {risk_sym}/{cash_sym}: spot=${spot:g} sqrtX96={plan['sqrtPriceX96']} "
            f"ticks=[{plan['tickLower']},{plan['tickUpper']}] L={plan['liquidity']}"
        )
    if not pair_plans:
        print("ERROR: no pair plans computed (page tokens don't include any known risk symbols)")
        return 1

    # 5. V4 PoolManager (deploy once) + per-pair init
    if "v4PoolManager" not in state:
        first = next(iter(pair_plans.values()))
        outs = run_forge(
            "script/swapexercising/helpers/DeployV4Pool.s.sol",
            env={
                "RISK_TOKEN": first["risk_addr"], "CASH_TOKEN": first["cash_addr"],
                "V4_FEE": "500", "V4_TICK_SPACING": "10",
                "V4_SQRT_PRICE": str(first["sqrtPriceX96"]),
            },
            rpc_url=args.rpc_url, private_key=args.private_key,
        )
        state["v4PoolManager"] = outs["V4_POOL_MANAGER"]
        state.setdefault("v4Initialized", []).append(_first_pair_label(pair_plans))
        save_state(args.state, state)
        print(f"== V4 PoolManager: {state['v4PoolManager']}")
    else:
        print(f"== V4 PoolManager (cached): {state['v4PoolManager']}")

    for sym, plan in pair_plans.items():
        label = f"{sym}-{cash_sym}"
        if label in state.get("v4Initialized", []):
            print(f"   v4 pool {label} already initialized")
            continue
        run_forge(
            "script/swapexercising/helpers/DeployV4Pool.s.sol",
            env={
                "RISK_TOKEN": plan["risk_addr"], "CASH_TOKEN": plan["cash_addr"],
                "V4_FEE": "500", "V4_TICK_SPACING": "10",
                "V4_SQRT_PRICE": str(plan["sqrtPriceX96"]),
                "V4_POOL_MANAGER": state["v4PoolManager"],
            },
            rpc_url=args.rpc_url, private_key=args.private_key,
        )
        state.setdefault("v4Initialized", []).append(label)
        save_state(args.state, state)

    # 6. V3 factory (deploy once) + per-pair init
    if "v3Factory" not in state:
        first = next(iter(pair_plans.values()))
        outs = run_forge(
            "script/swapexercising/helpers/DeployV3Pool.s.sol",
            env={
                "RISK_TOKEN": first["risk_addr"], "CASH_TOKEN": first["cash_addr"],
                "V3_FEE": "500",
                "V3_SQRT_PRICE": str(first["sqrtPriceX96"]),
            },
            rpc_url=args.rpc_url, private_key=args.private_key,
        )
        state["v3Factory"] = outs["V3_FACTORY"]
        state.setdefault("v3Initialized", []).append(_first_pair_label(pair_plans))
        save_state(args.state, state)
        print(f"== V3 Factory: {state['v3Factory']}")
    else:
        print(f"== V3 Factory (cached): {state['v3Factory']}")

    for sym, plan in pair_plans.items():
        label = f"{sym}-{cash_sym}"
        if label in state.get("v3Initialized", []):
            print(f"   v3 pool {label} already initialized")
            continue
        run_forge(
            "script/swapexercising/helpers/DeployV3Pool.s.sol",
            env={
                "RISK_TOKEN": plan["risk_addr"], "CASH_TOKEN": plan["cash_addr"],
                "V3_FEE": "500",
                "V3_SQRT_PRICE": str(plan["sqrtPriceX96"]),
                "V3_FACTORY": state["v3Factory"],
            },
            rpc_url=args.rpc_url, private_key=args.private_key,
        )
        state.setdefault("v3Initialized", []).append(label)
        save_state(args.state, state)

    # 7. SwapExercisingFunder (deploy once)
    if "swapFunder" not in state:
        outs = run_forge(
            "script/swapexercising/helpers/DeploySwapExercisingFunder.s.sol",
            env={
                "OPAIR_FACTORY": factory,
                "V4_POOL_MANAGER": state["v4PoolManager"],
                "V3_FACTORY": state["v3Factory"],
                "SWAP_FUNDER_NEW_OWNER": args.mm,
            },
            rpc_url=args.rpc_url, private_key=args.private_key,
        )
        state["swapFunder"] = outs["SWAP_FUNDER"]
        save_state(args.state, state)
        print(f"== SwapExercisingFunder: {state['swapFunder']}")
    else:
        print(f"== SwapExercisingFunder (cached): {state['swapFunder']}")

    # 8. Seed V4 + V3 LP per pair
    for sym, plan in pair_plans.items():
        label = f"{sym}-{cash_sym}"
        if label not in state.get("v4Seeded", []):
            run_forge(
                "script/swapexercising/helpers/SeedV4Liquidity.s.sol",
                env={
                    "V4_POOL_MANAGER": state["v4PoolManager"],
                    "RISK_TOKEN": plan["risk_addr"], "CASH_TOKEN": plan["cash_addr"],
                    "V4_FEE": "500", "V4_TICK_SPACING": "10",
                    "TICK_LOWER": str(plan["tickLower"]),
                    "TICK_UPPER": str(plan["tickUpper"]),
                    "LIQUIDITY": str(plan["liquidity"]),
                },
                rpc_url=args.rpc_url, private_key=args.private_key,
            )
            state.setdefault("v4Seeded", []).append(label)
            save_state(args.state, state)
        if label not in state.get("v3Seeded", []):
            run_forge(
                "script/swapexercising/helpers/SeedV3Liquidity.s.sol",
                env={
                    "V3_FACTORY": state["v3Factory"],
                    "RISK_TOKEN": plan["risk_addr"], "CASH_TOKEN": plan["cash_addr"],
                    "V3_FEE": "500",
                    "TICK_LOWER": str(plan["tickLower"]),
                    "TICK_UPPER": str(plan["tickUpper"]),
                    "LIQUIDITY": str(plan["liquidity"]),
                },
                rpc_url=args.rpc_url, private_key=args.private_key,
            )
            state.setdefault("v3Seeded", []).append(label)
            save_state(args.state, state)

    # 9. Fund MM and funder
    print("== Funding MM and funder")
    ensure_funded(args.rpc_url, args.private_key, args.mm, "MM", tokens, args.fresh)
    ensure_funded(args.rpc_url, args.private_key, state["swapFunder"], "funder", tokens, args.fresh)

    # 10. Summary
    print()
    print("==== Summary ====")
    print(f"  Chain ID:             {chain_id}")
    print(f"  Deployer:             {deployer}")
    print(f"  MM:                   {args.mm}")
    print(f"  OPair factory:        {factory}")
    print(f"  V4 PoolManager:       {state['v4PoolManager']}")
    print(f"  V3 factory:           {state['v3Factory']}")
    print(f"  SwapExercisingFunder: {state['swapFunder']}")
    print()
    print("Available OPair vaults (from page):")
    for (risk, cash), vs in sorted(vaults.items()):
        print(f"  {risk}/{cash}:")
        for v in sorted(vs, key=lambda x: (x["expiry"], x["strike"])):
            kind = "C" if v["isCall"] else "P"
            print(f"    {v['expiry']}  {kind} ${v['strike']:g}  {v['address']}")
    print()
    print("Next: sign Quote(funder=" + state["swapFunder"] + ", vault=<vault>, …) as MM,")
    print("      then call:")
    print("        SIGNER_PRIVATE_KEY=<MM key>     \\")
    print(f"        PAIR=<vault>  FUNDER={state['swapFunder']}  \\")
    print("        SIZE=...  AMOUNT_IN=...  AMOUNT_OUT_MIN=...  POOL_FEE=500  \\")
    print(f"        HOOKS=0x0000000000000000000000000000000000000000  \\")
    print(f"        forge script script/swapexercising/ExerciseWithSwapFunder.s.sol \\")
    print(f"          --rpc-url {args.rpc_url} --broadcast --private-key <buyer-key>")

    return 0


def _first_pair_label(plans: dict) -> str:
    sym = next(iter(plans.keys()))
    return f"{sym}-USDC"


def _short(sym: str) -> str:
    """Maps risk symbol to the abbreviation used by --price-override (ETH/BTC/MON)."""
    return {"WETH": "ETH", "WBTC": "BTC"}.get(sym, sym)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        print(f"ERROR: subprocess failed: {e.cmd}", file=sys.stderr)
        if e.stdout:
            print("--- stdout ---\n" + e.stdout, file=sys.stderr)
        if e.stderr:
            print("--- stderr ---\n" + e.stderr, file=sys.stderr)
        sys.exit(1)
