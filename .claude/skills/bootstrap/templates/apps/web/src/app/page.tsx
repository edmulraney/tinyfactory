import { WaitlistForm } from "./_components/waitlist-form";

export default function Home() {
  return (
    <div className="flex flex-1 flex-col items-center justify-center font-sans">
      <main className="flex w-full flex-col items-center gap-6 px-6 py-32 text-center">
        <h1 className="text-3xl leading-10 font-semibold tracking-tight">{{name}}</h1>
        <p className="max-w-md text-lg leading-8 text-muted-foreground">
          Something new is taking shape here. Leave your email address and we will tell you when it opens.
        </p>
        <WaitlistForm />
      </main>
    </div>
  );
}
