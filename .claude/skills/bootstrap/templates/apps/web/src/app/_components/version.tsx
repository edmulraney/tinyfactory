"use client";

import { useQuery } from "@tanstack/react-query";

import { healthQuery } from "./health-query";

/** The commit this deployment was built from, so the owner can see that a merge is live. */
export function Version() {
  const { data } = useQuery(healthQuery);

  if (!data || data.commit === "unknown") return null;
  return <p className="text-xs text-muted-foreground">{`Version ${data.commit.slice(0, 7)}`}</p>;
}
