CREATE TABLE "usage_events" (
	"account_id" text,
	"event" text NOT NULL,
	"occurred_at" timestamp with time zone DEFAULT now() NOT NULL
);
