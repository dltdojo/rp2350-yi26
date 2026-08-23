# Announcements

Posts written for social media about this project, kept in the repository so
that what was said publicly, and when, stays on the record next to the work it
describes.

## Conventions

One file per post, named `YYYY-MM-DD-short-slug.md`. The date is part of the
filename because these are time-bound: a post describes the project as it
stood on that day, and later posts do not correct earlier ones. Read them as
a log, not as documentation — the experiments' own READMEs are the
documentation, and they are kept current.

Every post opens with a short header block recording its date, the language it
was written in, and which experiments existed at the time. Filenames and this
page are in English, matching the rest of the repository; post bodies are in
whatever language they were published in.

Posts are written in flowing prose rather than bullet lists, and are not
edited after publication. If something in an old post is no longer true, that
is expected — write a new one.

## Index

| Date | Post | Covers |
| --- | --- | --- |
| 2026-08-01 | [六個實驗的段落](./2026-08-01-six-experiments-milestone.md) | exp101 – exp106, no release yet (正體中文) |
| 2026-08-02 | [把不可攜的部分收成一支工具](./2026-08-02-host-tool-transition.md) | exp101 – exp107 and tools/yi26 (正體中文) |
| 2026-08-02 | [接縫是一個檔案](./2026-08-02-the-seam-is-a-file.md) | exp101 – exp116 and docs/platforms.md — building in the cloud, reading the log in a browser (正體中文) |
| 2026-08-02 | [兩個看起來都很隨機的來源](./2026-08-02-two-sources-that-look-random.md) | exp108 – exp114 and crates/entropy-health (正體中文) |
| 2026-08-02 | [誰在讀那份日誌](./2026-08-02-the-agent-reads-the-log.md) | exp118, exp119 and AGENTS.md — how the project is developed (正體中文) |
| 2026-08-02 | [板子自己端出除錯介面](./2026-08-02-the-board-serves-its-own-page.md) | exp117 and exp120 – exp126 — the browser track reaching its destination (正體中文) |
| 2026-08-03 | [燒錄工具是檔案管理員](./2026-08-03-the-flashing-tool-is-a-file-manager.md) | exp101 – exp128 and docs/platforms.md — flashing a board from an Android phone, verified (正體中文) |
| 2026-08-03 | [一場抽獎,把設計改了四次](./2026-08-03-a-draw-that-changed-the-design.md) | exp127 – exp133 — the host takes control, a real use appears, and measurement keeps correcting the architecture (正體中文) |
| 2026-08-03 | [從來沒有人選過的預設值](./2026-08-03-a-default-nobody-chose.md) | exp134, exp135 and tools/pages — behaviour nobody decided, inherited from a container and shipped for thirty-three experiments (正體中文) |
| 2026-08-04 | [救不回來,就別做出來](./2026-08-04-if-you-cannot-recover-it.md) | exp139 redone, exp142, and pre-flight brick checks in partimg/yi26 — a board that could not be recovered, and the A/B choice that was in the ROM all along (正體中文) |
| 2026-08-05 | [來回才是最貴的東西](./2026-08-05-the-round-trip-is-the-cost.md) | exp143 – exp147 and docs/debugging-on-a-phone.md — the update road finished, and what it costs to debug on somebody else's phone (正體中文) |
| 2026-08-05 | [有線,但沒有位址](./2026-08-05-a-wire-with-no-address.md) | exp148, exp149 and crates/dhcp — a board with no network interface gets onto a network, and finds nobody willing to hand out an address (正體中文) |
| 2026-08-05 | [一個位址,三種到不了的方式](./2026-08-05-three-ways-not-to-arrive.md) | exp150 — the board serves a page, and a phone's browser reaches it only one way out of three (正體中文) |
| 2026-08-05 | [一個等到有話說才出現的磁碟](./2026-08-05-a-drive-that-waits.md) | exp151, exp152 and crates/log-ring, crates/mdns — reading this board's log without WebUSB, which had been assumed since the first experiment that printed anything (正體中文) |
| 2026-08-06 | [誰還能敲門](./2026-08-06-who-else-can-knock.md) | exp153, exp155, exp161 and crates/http-route — connection sharing via phone tethering, multi-route multiplexing, and origin preflight guards (正體中文) |
| 2026-08-21 | [這顆晶片能保守秘密嗎](./2026-08-21-can-this-chip-keep-a-secret.md) | exp154, exp156 – exp160, exp162, exp163 and docs/can-this-chip-keep-a-secret.md — OTP reads, ACCESSCTRL isolation, P-256 vs post-quantum ML-DSA stack leakage, and SRAM interleaving (正體中文) |
| 2026-08-22 | [誰在定義記憶體](./2026-08-22-who-gets-the-last-word.md) | exp164 – exp167 and crates/framing — Armv8-M SAU vs bus filters, verifying firmware signatures, and QMI aperture boundaries in dual-slot boot (正體中文) |
| 2026-08-23 | [一個沒人提過的期限](./2026-08-23-a-deadline-nobody-mentioned.md) | exp168 – exp174 and crates/cbor — handcrafted CTAPHID/WebAuthn authenticator, canonical CBOR, derived keys, and browser timeouts & keepalives (正體中文) |
| 2026-08-23 | [檔案即身分](./2026-08-23-the-secret-is-the-file.md) | exp175 – exp179 — forging assertions from UF2 images, comparing with YubiKey/pico-fido/OpenSK, and SRAM power-on characteristics for PUF (正體中文) |
