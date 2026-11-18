export type Health = {
  status: "ok";
  commit: string;
};

const GIT_SHA = /^[0-9a-f]{40}$/;

// Async because the factory's route awaits it: a project adds what it checks (its database) here.
export async function getHealth(): Promise<Health> {
  const sha = process.env.VERCEL_GIT_COMMIT_SHA;
  return { status: "ok", commit: sha && GIT_SHA.test(sha) ? sha : "unknown" };
}
