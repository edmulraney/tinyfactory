"use client";

import { useSuspenseQuery } from "@tanstack/react-query";

import { healthQuery } from "./health-query";

/** Reads the health and shows the commit this deployment was built from. `Version` catches its failure. */
export function Commit() {
  const { data } = useSuspenseQuery(healthQuery);

  if (data.commit === "unknown") return null;
  return <p className="text-xs text-muted-foreground">{`Version ${data.commit.slice(0, 7)}`}</p>;
}
