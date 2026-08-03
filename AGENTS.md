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
the two overlap in four jobs, and there are eight things `yi26` can do that no
page can. When they overlap they speak the same language on purpose —
`console.html` takes the same `\xNN` escapes as `yi26 send` — so an
instruction written for one works in the other.

An agent that screenshots a browser window to find out what a firmware printed
has taken the thing under test and used it as a measuring instrument. It is
slower, it needs a human present to grant a permission and keep a window open,
and it produces a picture where a JSON document was available. Development here
is agent-driven and non-interactive by default; every step that needs a person
in the room is a step that stops overnight.

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
- **[Which layer of USB is this](./experiments/README.md#which-layer-of-usb-is-this)**
  — every experiment declares its interface, what travels on it, who claims it
  on the host, and whose firmware it runs against. Read the row before
  proposing anything that touches an endpoint: six experiments here have no
  firmware of their own, and one of them runs against exp118 and nothing else.
