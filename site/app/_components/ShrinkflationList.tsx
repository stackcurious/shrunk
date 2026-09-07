"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import type { Case } from "../_lib/cases";
import { formatQuantity } from "../_lib/cases";

type SortMode = "category" | "biggest" | "az";

const SORT_LABELS: Record<SortMode, string> = {
  category: "Grouped by category",
  biggest: "Biggest shrink first",
  az: "A–Z",
};

export function ShrinkflationList({ cases, categories }: { cases: Case[]; categories: string[] }) {
  const [sort, setSort] = useState<SortMode>("category");

  const groups = useMemo(() => {
    if (sort === "biggest") {
      return [{ category: null, cases: [...cases].sort((a, b) => b.percentSmaller - a.percentSmaller) }];
    }
    if (sort === "az") {
      return [{ category: null, cases: [...cases].sort((a, b) => a.name.localeCompare(b.name)) }];
    }
    return categories.map((category) => ({
      category,
      cases: cases
        .filter((c) => c.category === category)
        .sort((a, b) => b.percentSmaller - a.percentSmaller),
    }));
  }, [cases, categories, sort]);

  return (
    <div>
      <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Sort cases">
        {(Object.keys(SORT_LABELS) as SortMode[]).map((mode) => (
          <button
            key={mode}
            type="button"
            onClick={() => setSort(mode)}
            aria-pressed={sort === mode}
            className={`rounded-full border px-4 py-1.5 text-xs font-semibold transition-colors ${
              sort === mode
                ? "border-rose-400/40 bg-rose-400/10 text-rose-400"
                : "border-border text-muted hover:border-border-hover hover:text-foreground"
            }`}
          >
            {SORT_LABELS[mode]}
          </button>
        ))}
      </div>

      <div className="mt-8 space-y-10">
        {groups.map((group) => (
          <section key={group.category ?? sort} id={group.category ? slugForId(group.category) : undefined}>
            {group.category && (
              <h2 className="mb-4 text-lg font-bold tracking-tight text-foreground">
                {group.category}
                <span className="ml-2 text-sm font-normal text-muted">
                  {group.cases.length} case{group.cases.length === 1 ? "" : "s"}
                </span>
              </h2>
            )}
            <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card">
              {group.cases.map((c) => (
                <li key={c.slug}>
                  <Link
                    href={`/shrinkflation/${c.slug}`}
                    className="flex flex-col gap-1 px-5 py-4 transition-colors hover:bg-card-hover sm:flex-row sm:items-center sm:justify-between sm:gap-4"
                  >
                    <div className="min-w-0">
                      <p className="truncate font-semibold text-foreground">{c.name}</p>
                      <p className="text-xs text-muted">
                        {c.brand} · {c.category}
                      </p>
                    </div>
                    <div className="flex shrink-0 items-center gap-4 text-sm">
                      <span className="text-muted">
                        {formatQuantity(c.before)} <span aria-hidden="true">&rarr;</span>{" "}
                        {formatQuantity(c.after)}
                      </span>
                      <span className="rounded-full bg-rose-400/10 px-2.5 py-1 text-xs font-bold text-rose-400">
                        -{Math.round(c.percentSmaller)}%
                      </span>
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  );
}

function slugForId(category: string): string {
  return `cat-${category.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")}`;
}
