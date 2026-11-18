export default function Home() {
  return (
    <div className="flex flex-1 flex-col items-center justify-center font-sans">
      <main className="flex flex-col items-center gap-6 px-16 py-32 text-center">
        <h1 className="text-3xl leading-10 font-semibold tracking-tight">{{name}}</h1>
        <p className="max-w-md text-lg leading-8 text-muted-foreground">
          Something new is taking shape here.
        </p>
      </main>
    </div>
  );
}
