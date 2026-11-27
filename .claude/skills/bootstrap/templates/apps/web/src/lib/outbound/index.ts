// A database or service that accepts a request and never answers must not hang the page waiting on
// it. 5 seconds leaves room for a suspended database to wake, and is inside the 10 seconds the
// factory waits for the health check before taking an outage for a missing deployment.
const ANSWER_WITHIN_MS = 5_000;

export class OutboundError extends Error {}

/**
 * `fetch` for every request to an outside service: the whole answer, body included, arrives within
 * the time limit, or the call fails with an `OutboundError`. An answer with an error status is
 * still an answer, and is the caller's to read.
 */
export async function outboundFetch(
  url: string | URL,
  init: Omit<RequestInit, "signal"> = {},
): Promise<Response> {
  const giveUp = new AbortController();
  const timer = setTimeout(() => giveUp.abort(), ANSWER_WITHIN_MS);
  try {
    const response = await fetch(url, { ...init, signal: giveUp.signal });
    // Read here, because headers can arrive in time and the body still stall.
    const body = await response.arrayBuffer();
    return new Response(body.byteLength ? body : null, response);
  } catch (cause) {
    // A relative URL has no host to name, and naming it must not throw in place of the failure.
    const host = URL.canParse(url) ? new URL(url).host : String(url);
    throw new OutboundError(giveUp.signal.aborted ? `No answer from ${host} within ${ANSWER_WITHIN_MS} ms` : `The request to ${host} failed`, {
      cause,
    });
  } finally {
    clearTimeout(timer);
  }
}
