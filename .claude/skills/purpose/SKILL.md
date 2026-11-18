---
name: purpose
description: Interview the human and write PURPOSE.md, the mission and the one-page statement every ticket and review is judged against. Use during bootstrap, when PURPOSE.md is missing, or when the purpose or mission has changed.
---

# Purpose

## The questions

1. In one sentence, what is it?
2. Who is it for? Name one kind of person, not a market.
3. What problem do they have, and how do they cope with it today?
4. Suppose it worked perfectly for everyone it could ever reach. What is different about their world?
5. How will you know it is working three months from now? Give a number if you can.
6. What will it deliberately not do?
7. Will people sign in to it? Yes, unless you say it has no accounts.

## Steps

1. **Read what exists:** `PURPOSE.md`, `product/`, open issues, this conversation. State what you already know and ask the human to confirm or correct it.
2. **Ask the remaining questions in one message.**
3. **Push back once on a weak answer, then accept it:** "everyone" as the audience, a problem nobody copes with today, a success measure that cannot be observed, an empty "will not do". Offer a sharper version.
4. **Draft at least ten missions** from answers 2, 3 and 4, in different shapes. Throw out each that explains, hedges, or could sit in another company's deck, and offer the best three or four as a choice (the question tool if you have one), with room for the human's own. If none has an edge, say so and ask how they would put it to a friend. Their line beats yours.
5. **Write `PURPOSE.md`** in the shape of `template.md` in this folder, in the human's words, tightened. One page: no features, roadmap or technology. "I don't know yet" is written as an open question in its section; invent nothing. For a product with no accounts, "What it will not do" holds the bullet `- **Have accounts.**` in exactly those words, then the reason: setup reads it (`factory/decisions.md` S287d).
6. **Show it.** In a repo with a remote, commit it straight to `main` as `docs: add PURPOSE.md` (or `docs: revise PURPOSE.md`). During bootstrap, leave it for the first commit.

## What makes a mission

A direction never reached, not a goal with an end ("launch in ten countries"); a claim, not an explanation.

- **Short.** Eight words or fewer. A phrase beats a sentence.
- **A prize the customer would name:** energy, time and money. Not "potential", "motivation" or "empowerment".
- **A "who" with a point of view:** "every athlete", "the rest of us". The best say who has been left out.
- **One idea.** "And how" or "and why" is explaining.
- **Bigger than the product.** True in twenty years, and if everything were rebuilt.
- **Sayable** by the founder to a stranger, and repeatable by a customer.

Shapes: *[prize] for [who]* · *[strong verb] [something big]* · *to [verb] [who] [prize]*.

- Strong: "Peak performance for the rest of us." A prize, and a who that takes a side.
- Weak: "Show everyone what they're capable of, and how to get there." It explains the product, its second half hedges, and a careers site could say it.
