"use client";

import { useActionState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { JoinResult } from "@/domain/waitlist";

import { join } from "../actions";

const REFUSED: Record<Exclude<JoinResult["status"], "joined">, string> = {
  "invalid email": "Enter an email address, such as name@example.com.",
  unavailable: "We could not save your address just now. Try again in a moment.",
};

export function WaitlistForm() {
  const [result, submit, pending] = useActionState(join, null);

  if (result?.status === "joined") {
    return <p role="status">You are on the list. We will email you when it opens.</p>;
  }

  return (
    // noValidate: the module decides what an email address is, and the browser's own check would answer first.
    <form action={submit} noValidate className="flex w-full max-w-sm flex-col gap-3 text-left">
      <Label htmlFor="email">Email</Label>
      <Input
        id="email"
        name="email"
        type="email"
        autoComplete="email"
        aria-invalid={result?.status === "invalid email" ? true : undefined}
        aria-describedby={result ? "email-refused" : undefined}
      />
      {result && (
        <p id="email-refused" role="alert" className="text-sm text-destructive">
          {REFUSED[result.status]}
        </p>
      )}
      <Button type="submit" disabled={pending}>
        Tell me when it opens
      </Button>
    </form>
  );
}
