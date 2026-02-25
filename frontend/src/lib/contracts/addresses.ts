// ─────────────────────────────────────────
//  Contract addresses — Starknet Sepolia
// ─────────────────────────────────────────

export const CONTRACTS = {
  BTCVault:          "0x0047970cfbf8de94f268f2416c9e5cbaef520dae7b5eae0fd6476a41b7266f08",
  BTCSecurityRouter: "0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639",
  YBTCToken:         "0x04ea131f51c071ce677482a4eeb1f9ac31e9188b2a92de13cb7043f9f21c8166",
  MockWBTC:          "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446",
  MockPragmaOracle:  "0x06d1c9aa3cb65003c51a4b360c8ac3a23a9724530246031ba92ff0b2461f7e74",
} as const;

export const EXPLORERS = {
  BTCVault:          "https://sepolia.starkscan.co/contract/0x0047970cfbf8de94f268f2416c9e5cbaef520dae7b5eae0fd6476a41b7266f08",
  BTCSecurityRouter: "https://sepolia.starkscan.co/contract/0x014c306f04fd602c1a06f61367de622af2558972c7eead39600b5d99fd1e2639",
  YBTCToken:         "https://sepolia.starkscan.co/contract/0x04ea131f51c071ce677482a4eeb1f9ac31e9188b2a92de13cb7043f9f21c8166",
  MockWBTC:          "https://sepolia.starkscan.co/contract/0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446",
} as const;

/** Minimum deposit: 0.01 BTC */
export const MINIMUM_DEPOSIT = BigInt(1_000_000);
/** First-deposit minimum: 0.1 BTC */
export const FIRST_DEPOSIT_MINIMUM = BigInt(10_000_000);
/** Share price scale factor */
export const SCALE = BigInt(1_000_000);
/** BTC decimals (satoshi) */
export const BTC_DECIMALS = 8;
/** Pragma oracle price decimals */
export const PRICE_DECIMALS = 8;
