// ─────────────────────────────────────────────
//  Shared TypeScript types for BTC Vault UI
// ─────────────────────────────────────────────

export type HealthStatus = "healthy" | "moderate" | "warning" | "critical";

export interface SystemMetrics {
  btcHealth: number;        // × 100, e.g. 142 = 1.42x
  healthStatus: HealthStatus;
  isSafeMode: boolean;
  btcUsdPrice: number;      // 8-decimal Pragma price
  totalAssets: bigint;      // satoshi
  sharePrice: bigint;       // SCALE = 1_000_000
  apy: number;              // basis points
  maxLeverage: number;      // × 100
  maxLtv: number;           // × 100
  btcBacking: bigint;
  btcExposure: bigint;
  isPriceFresh: boolean;
}

export interface UserPosition {
  ybtcBalance: bigint;      // satoshi
  collateral: bigint;       // satoshi
  debt: bigint;             // 8-dec USD
  leverage: number;         // × 100
  healthFactor: number;     // × 100
  liquidationPrice: number; // 8-dec USD
  claimableYield: bigint;
}

export interface UserDashboard {
  ybtcBalance: bigint;
  collateralValue: bigint;
  debtValue: bigint;
  currentLeverage: number;
  userHealthFactor: number;
  estimatedApy: number;
  pendingYield: bigint;
  liquidationPrice: number;
  isLiquidatable: boolean;
}

export type StrategyMode = "conservative" | "balanced" | "aggressive";

export interface StrategyOption {
  id: StrategyMode;
  label: string;
  description: string;
  leverageMin: number;
  leverageMax: number;
  apyRange: [number, number];
  riskLevel: number; // 1-5
}

export type TxStatus = "idle" | "approving" | "pending" | "success" | "error";

export interface TxState {
  status: TxStatus;
  hash?: string;
  error?: string;
}
