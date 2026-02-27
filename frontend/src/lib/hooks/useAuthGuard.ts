import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAccount } from "@starknet-react/core";

/**
 * Redirects to the landing page whenever the wallet is disconnected.
 * Drop this into any page that requires a connected wallet.
 */
export function useAuthGuard() {
  const { isConnected } = useAccount();
  const router = useRouter();

  useEffect(() => {
    if (!isConnected) {
      router.push("/");
    }
  }, [isConnected, router]);
}
