import { TrackedCta } from "@/components/tracked-cta";
import type { CtaLocation } from "@/lib/analytics";
import { APP_STORE_URL, RED } from "../_lib/constants";

const SIZE_CLASSES: Record<"sm" | "md" | "lg", string> = {
  sm: "gap-1.5 rounded-lg px-4 py-2 text-xs",
  md: "gap-2 rounded-xl px-6 py-3.5 text-sm",
  lg: "gap-2.5 rounded-xl px-8 py-4 text-base",
};

const ICON_SIZE: Record<"sm" | "md" | "lg", string> = {
  sm: "h-3.5 w-3.5",
  md: "h-5 w-5",
  lg: "h-6 w-6",
};

export function AppStoreCTA({
  size = "md",
  variant = "solid",
  label = "Download on the App Store",
  className = "",
  location,
}: {
  size?: "sm" | "md" | "lg";
  variant?: "solid" | "outline";
  label?: string;
  className?: string;
  location: CtaLocation;
}) {
  const base =
    "inline-flex items-center justify-center font-semibold transition-all whitespace-nowrap";
  const look =
    variant === "solid"
      ? "text-white shadow-lg hover:shadow-xl hover:-translate-y-0.5"
      : "border border-border text-foreground hover:border-border-hover hover:bg-card";

  return (
    <TrackedCta
      app="shrunk"
      location={location}
      href={APP_STORE_URL}
      className={`${base} ${SIZE_CLASSES[size]} ${look} ${className}`}
      style={variant === "solid" ? { backgroundColor: RED } : undefined}
    >
      <AppleLogo className={ICON_SIZE[size]} />
      {label}
    </TrackedCta>
  );
}

function AppleLogo({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M17.05 20.28c-.98.95-2.05.86-3.08.38-1.09-.5-2.08-.48-3.24 0-1.44.62-2.2.44-3.06-.38C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}
