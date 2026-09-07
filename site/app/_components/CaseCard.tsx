import Link from "next/link";
import type { Case } from "../_lib/cases";
import { formatQuantity } from "../_lib/cases";

export function CaseCard({ c }: { c: Case }) {
  return (
    <Link
      href={`/shrinkflation/${c.slug}`}
      className="group flex flex-col rounded-2xl border border-border bg-card p-5 transition-all hover:border-border-hover hover:bg-card-hover"
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="text-xs font-medium uppercase tracking-wider text-muted">{c.category}</p>
          <h3 className="mt-1 text-base font-semibold leading-snug text-foreground">
            {c.name}
          </h3>
        </div>
        <span className="shrink-0 rounded-full bg-rose-400/10 px-2.5 py-1 text-xs font-bold text-rose-400">
          -{Math.round(c.percentSmaller)}%
        </span>
      </div>
      <p className="mt-3 text-sm text-muted">
        {formatQuantity(c.before)}{" "}
        <span aria-hidden="true">&rarr;</span> {formatQuantity(c.after)}
      </p>
      <span className="mt-4 inline-flex items-center gap-1 text-xs font-semibold text-foreground/70 transition-colors group-hover:text-rose-400">
        See the case
        <svg className="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
        </svg>
      </span>
    </Link>
  );
}
