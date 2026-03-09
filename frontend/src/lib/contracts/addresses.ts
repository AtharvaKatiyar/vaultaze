// ─────────────────────────────────────────
//  Contract addresses — Starknet Sepolia
// ─────────────────────────────────────────

export const CONTRACTS = {
  BTCVault:          "0x06e3335034d25a8de764c0415fc0a6181c6878ee46b2817aec74a9fc1bcb4166",
  BTCSecurityRouter: "0x06e077f2b7e5de828c8f43939fddea20937ba01eb95a066ca90c992a094ef8a5",
  YBTCToken:         "0x03100f429e329e8db8a21d603222459c29326c808a6e4c3ec1dd9003e6854b8a",
  MockWBTC:          "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446",
} as const;

export const EXPLORERS = {
  BTCVault:          "https://sepolia.voyager.online/contract/0x06e3335034d25a8de764c0415fc0a6181c6878ee46b2817aec74a9fc1bcb4166",
  BTCSecurityRouter: "https://sepolia.voyager.online/contract/0x06e077f2b7e5de828c8f43939fddea20937ba01eb95a066ca90c992a094ef8a5",
  YBTCToken:         "https://sepolia.voyager.online/contract/0x03100f429e329e8db8a21d603222459c29326c808a6e4c3ec1dd9003e6854b8a",
  MockWBTC:          "https://sepolia.voyager.online/contract/0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446",
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
