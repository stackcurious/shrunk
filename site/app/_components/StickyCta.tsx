import { AppStoreCTA } from "./AppStoreCTA";

/**
 * Mobile-only bottom CTA bar. Renders a spacer of the same height in normal
 * flow so fixed positioning never covers the last section of content.
 */
export function StickyCta({ label = "Free to scan. No account needed." }: { label?: string }) {
  return (
    <>
      <div className="h-20 sm:hidden" aria-hidden="true" />
      <div className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-background/95 px-4 py-3 backdrop-blur-xl sm:hidden">
        <div className="flex items-center justify-between gap-3">
          <p className="text-xs font-medium text-muted">{label}</p>
          <AppStoreCTA size="sm" label="Get Shrunk" location="sticky" />
        </div>
      </div>
    </>
  );
}
