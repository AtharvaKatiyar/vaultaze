// ─────────────────────────────────────────
//  Contract addresses — Starknet Sepolia
// ─────────────────────────────────────────

export const CONTRACTS = {
  BTCVault:          "0x04f3f2276f3c8e1d20296c0cf95329211fd22caa58898caf298c79160c281cdc",
  BTCSecurityRouter: "0x079c852ec6c79d011a42eba2b0de16f13b9e35bdc42facf073ea2f7ffc579fc0",
  YBTCToken:         "0x03100f429e329e8db8a21d603222459c29326c808a6e4c3ec1dd9003e6854b8a",
  MockWBTC:          "0x0129f01b63b9eb403e07c9da8e69e2bed648a5fbc81fddb0b27768ee323bf446",
} as const;

export const EXPLORERS = {
  BTCVault:          "https://sepolia.voyager.online/contract/0x04f3f2276f3c8e1d20296c0cf95329211fd22caa58898caf298c79160c281cdc",
  BTCSecurityRouter: "https://sepolia.voyager.online/contract/0x079c852ec6c79d011a42eba2b0de16f13b9e35bdc42facf073ea2f7ffc579fc0",
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
