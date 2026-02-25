"use client";

import { Sidebar } from "@/components/layout/Sidebar";
import { Header } from "@/components/layout/Header";
import { SafeModeBanner } from "@/components/system/SafeModeBanner";
import { useRouterSafeMode } from "@/lib/hooks/useRouterData";

export function AppLayout({ children }: { children: React.ReactNode }) {
  const { data: isSafeMode } = useRouterSafeMode();

  return (
    <div className="flex h-screen bg-[#060810] text-white">
      <Sidebar />
      <div className="flex-1 flex flex-col min-w-0 overflow-auto">
        {isSafeMode && <SafeModeBanner />}
        <Header />
        <main className="flex-1 p-4 lg:p-6 max-w-screen-2xl mx-auto w-full">
          {children}
        </main>
      </div>
    </div>
  );
}
