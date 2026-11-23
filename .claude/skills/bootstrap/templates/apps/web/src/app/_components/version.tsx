"use client";

import { catchError } from "next/error";

import { Commit } from "./commit";

// A visitor has no use for the version, so a health that cannot be read shows nothing (decisions S692a).
const NothingOnError = catchError(() => null);

/** The commit this deployment was built from, so the owner can see that a merge is live. */
export function Version() {
  return (
    <NothingOnError>
      <Commit />
    </NothingOnError>
  );
}
