# For AI agents working in this repository

Short on purpose. Everything here is a rule that only applies to an automated
agent; everything else lives in the documents this file points at, so there is
one copy of each rule and nothing to drift.

## Read the log with `yi26`, never with a browser

```sh
yi26 log --json --seconds 10     # what the firmware is printing
yi26 doctor --json               # host, toolchain, board state, problems[]
```

**The browser is never how you read the log. It is only ever the thing being
tested.**

- Finding out what the firmware printed → `yi26 log --json`. Always.
- Checking that a page claims its interfaces, streams, and renders → open the
  browser, because in that case the page *is* the subject.

This repository contains a whole track of experiments (exp115 onward) about
reading the log in a browser, and that is exactly why the rule needs writing
down. Those pages exist so that **a person** can see the log on a machine with
no toolchain — a phone with the board plugged into its only port, most
importantly. They are the product. `yi26` is the workshop tool.

The maintained pages live in [`tools/pages/`](./tools/pages/), and that
README has the table you want if you are ever unsure which side to reach for:
the two overlap in four jobs, and there are ten things `yi26` can do that no
page can. When they overlap they speak the same language on purpose —
`console.html` takes the same `\xNN` escapes as `yi26 send` — so an
instruction written for one works in the other.

An agent that screenshots a browser window to find out what a firmware printed
has taken the thing under test and used it as a measuring instrument. It is
slower, it needs a human present to grant a permission and keep a window open,
and it produces a picture where a JSON document was available. Development here
is agent-driven and non-interactive by default; every step that needs a person
in the room is a step that stops overnight.

## No board attached? Search before you change anything

Developing firmware from a machine with no board on it means every observation
costs somebody a walk to a bench. Two rules follow, and
[`docs/debugging-without-a-board.md`](./docs/debugging-without-a-board.md) is
what seven flash cycles of ignoring them cost:

1. **When something breaks, search prior work before forming a hypothesis.**
   Not after. A `grep` over `docs/` and `experiments/*/README.md`, and a read of
   the source of the function you are calling, cost nothing and have already
   answered most of it — this repository has written down the empty device
   chooser, the blocking call in an async task, and the fact printed once that
   nobody sees. Changing code first means going looking for confirmation instead
   of for the answer, at one attempt per human trip.

   And when a track of work is going to be several rounds long,
   [`docs/the-board-is-the-loop.md`](./docs/the-board-is-the-loop.md) is the
   arithmetic on why exp156 took seven of them and what to build so the next one
   takes two. Two of its levers need no hardware and no new firmware.

2. **The LED is the debug channel, so design it before you need it.** When
   firmware fails, USB is gone, the log is gone and the page cannot connect.
   Bring the LED up before anything that can hang, make a fault handler drive it
   by hand so *dark* and *died* are different signals, and make the pattern
   carry a step number — a pattern that means "died" is worth much less than one
   that means "died at step five".

## Ask before touching the user's screen or browser

Verifying a browser experiment means opening a page and looking at it. Ask
first, capture the browser window only — never the whole desktop — and say
what you are about to do. A screenshot of someone's screen is not a build
artifact.

## Find out what needs a person before planning a night's work

Development here is non-interactive by default, so the useful question is not
"what should I do next" but "what can I finish without waking anybody". The
index answers it: every experiment carries a **Needs** level, 0 to 3, and
`presence_check` in `lib.sh` fails if that number ever drifts from the one
declared in the experiment's own `check.sh`.

```sh
yi26 port --json     # which experiment is on the board right now
yi26 state           # bootsel | running | detached | absent
```

Those two are the other half, and the reason the level does not include them.
**Flashing cost is not a property of the experiment**: a board running exp105
or later reboots itself on the 1200-baud touch and needs nobody; a board
running exp101–exp104 needs a hand on BOOTSEL first, whatever comes next.

Read
**[Which of these can I do right now](./experiments/README.md#which-of-these-can-i-do-right-now)**
before proposing a plan that ends up parked until morning.

## Do not start a new experiment by copying the last one

From exp190 on, an experiment's `src/main.rs` is meant to hold **only what the
experiment is asking about**. Everything else comes from `crates/`.

The test is one question, and it has a checkable form:

> This code changed. Would this experiment's claim change?
> No -> it is not this experiment's. And in practice: an experiment's scope is
> what its `check.sh` and `verify.py` assert on.

This is not a style preference, it is what copying has already cost: exp174
shipped with exp173's USB serial because the string came across with the source;
exp160 lost the end of its report to a full log queue and exp162 lost it again
the same way. Today **22,629 of the 55,110 lines of firmware source here live
inside a function that some other experiment also defines** — `ctaphid_task`
exists in fourteen experiments as thirteen different functions, the longest 959
lines.

So there is a ratchet, and `docs-check.sh` runs it:

```sh
./duplication.sh            # what is duplicated, worst first
./duplication.sh --check    # fails if anything gained a copy
```

Existing copies are grandfathered in `duplication-baseline.txt`. The baseline
may only shrink. **The second copy is the moment to extract, not the fifth.**

[`docs/what-belongs-to-an-experiment.md`](./docs/what-belongs-to-an-experiment.md)
is the whole argument, the cost of extraction stated plainly, and the order to
extract in. Read it before proposing a new experiment's structure — including
the part that says not to extract ahead of a real caller.

## The rules that are not agent-specific

These apply to everyone and are documented where they belong. An agent should
read them before proposing work, not instead of them:

- **[Every new experiment starts with an interrogation](./experiments/README.md#how-this-repository-is-developed)**
  — no experiment and no idea goes straight to a plan or to code. Step 2 of
  that sequence is aimed squarely at an agent: **go and read the prior work you
  have access to before deriving anything.** If your notes record earlier
  private projects on this ground, open them. A finding presented as new when
  it was answered a year ago is not a small error — it spends somebody's
  attention on a question that was already closed. Their findings may be cited
  here as facts; their code, paths and identity must not appear.
- **[Nothing is pushed unverified](./experiments/README.md#nothing-is-pushed-unverified)**
  — a push means someone plugged a board in and watched it work. `Expected
  output` sections are pasted captures, never predictions.
- **[The tool explains itself](./tools/README.md)** — `--explain` on every
  subcommand prints the hand-typed equivalent. Use it when you need to know
  what a command actually does.
- **[Platform reality](./experiments/README.md#platform)** — verified on
  Ubuntu against one Pico 2, and nowhere else. Do not write claims this
  repository cannot check.
- **[Debugging on somebody else's phone](./docs/debugging-on-a-phone.md)** —
  read this *before* writing a page a person will run on hardware you cannot
  see. You will not get to iterate: they cannot screenshot a native dialog, a
  sleeping phone quietly takes a board out of BOOTSEL, and an error message
  that names the wrong cause costs a whole exchange. The page has to say what
  it received, before the call that fails, in quantities that separate
  hypotheses — and the offline test has to be fed exactly what the code asks
  for, not something adjacent to it.
- **[Which layer of USB is this](./experiments/README.md#which-layer-of-usb-is-this)**
  — every experiment declares its interface, what travels on it, who claims it
  on the host, and whose firmware it runs against. Read the row before
  proposing anything that touches an endpoint: six experiments here have no
  firmware of their own, and one of them runs against exp118 and nothing else.
