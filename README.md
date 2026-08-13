# llm-rig — local LLM stack for Claude Code on Pop!_OS

Self-detecting scripts that build a tuned local inference stack for running Claude Code
against a local model. Nothing is hardcoded to specific hardware — each script reads
your GPU, VRAM, RAM, and core count and configures itself.

**This file is how to run it. [TUNING.md](TUNING.md) is what the measurements said and
why every setting is what it is.** Numbers live there, not here, so they only have to be
correct in one place.

## The stack

```
Claude Code
    │  Anthropic Messages API (/v1/messages) — native, no proxy
    ▼
llama-swap  :8081     ← hot-swaps models on demand, LAN-exposed
    │  spawns/kills
    ▼
llama-server :9100+   ← compiled for your exact GPU arch, localhost only
```

Recent llama-server builds implement `/v1/messages` themselves, so Claude Code talks to
llama-swap directly and there is no translation layer. `50-claude-code.sh` probes for
that endpoint and **only** falls back to installing LiteLLM (:4000) if the probe fails.
If you see LiteLLM in your service list, the probe failed — see
[Troubleshooting](#troubleshooting).

Ollama was evaluated and rejected; the reasoning is in
[TUNING.md § Rejected](TUNING.md#rejected-with-reasons).

vLLM was too, and `00-specs.sh` re-decides it for **your** GPU rather than repeating
the verdict for this one. Whether vLLM is worth your time turns on compute capability
— loading an FP8 checkpoint weight-only starts at Turing, computing in FP8 starts at
Ada, NVFP4 at Blackwell — and on the fact that it keeps the whole model in VRAM, with
no `--n-cpu-moe` equivalent, so a machine with far more RAM than VRAM gives up its
largest models by switching. Capacity gates the enthusiastic verdict too: even NVFP4
is not a reason to switch on a card that cannot hold the model you want. The report
names the capability it read, so you can check the claim instead of believing it.

## Run order

```bash
chmod +x *.sh
./05-path-fix.sh         # puts ~/.local/bin on PATH permanently. do this FIRST
source ~/.bashrc
./00-specs.sh            # read-only. writes ~/llm-specs.txt, prints the tier plan
./10-os-tune.sh          # sudo. GPU persistence, power, governor, THP, sysctls
                         #   --dry-run first if you want to see the plan
./20-build-llamacpp.sh   # compiles for your compute capability. 5–20 min. out-of-tree
./30-models.sh           # resolves + downloads 3 GGUFs matched to your budget
./40-serve.sh            # llama-swap config + systemd + firewall
./50-claude-code.sh      # env file + TOOL CALLING SMOKE TEST (LiteLLM only if needed)
./60-bench.sh            # writes ~/llm-bench-<date>.txt
./90-remove-ollama.sh    # LAST. runs a full tool-calling preflight; fails closed
```

Then:

```bash
source ~/llm-rig/claude-code-local.env
claude
```

### Optional / as-needed

| Script | Purpose |
|---|---|
| `./71-verify-runtime.sh` | Query the **running** server's `/props` — confirms live `n_ctx`, flash-attn, KV cache types. Trust this over the config file. Grades its evidence; see below. |
| `./61-rate-models.sh` | Rate the models you serve on a fixed coding suite, and print rows for `catalog_ratings()`. Nothing it grades is executed; see [Rating the models you serve](#rating-the-models-you-serve). |
| `./70-thermal-sweep.sh` | Re-derive the best power limit for your chassis under a heat-soaked load. |
| `./80-try-bigger.sh <hf-repo> [quant]` | Assess, download, auto-tune `--n-cpu-moe` and benchmark a model **larger than VRAM**. Empirically finds the lowest working offload level. `--list` sizes it without downloading. |
| `./19-os-revert.sh` | Undo `10-os-tune.sh`, restoring the values captured before it ran — not assumed defaults. See [Rollback](#what-reversible-means). |

`80-try-bigger.sh` exists because with lots of system RAM, an MoE far larger than VRAM is
viable — attention stays on the GPU, expert tensors go to CPU, and only a few billion
params are active per token. A *dense* model of the same size would be unusable.

## The model catalog

Model metadata lives in one place, [`lib/catalog.sh`](lib/catalog.sh), and both
`00-specs.sh` and `30-models.sh` read it. They used to hold separate hardcoded
lists, which drifted: the report recommended models the downloader never
fetched, and in two cases models that did not exist.

There are **two tables**, and the split is the point.

`catalog_rows()` holds *facts*: canonical repository, release date, total and
active parameters, architecture, native context, licence, capabilities and
quant preferences. Every row was checked against the publisher's own repository
or model card, and carries the `fact_method` used, a `fact_source` URL you can
open, and the `verified_at` date. The catalog is capped at 17 rows — it is
curated by hand, and a longer list cannot be kept honest. The cap can be
raised, but not quietly: `CATALOG_MAX_ROWS` carries the date and reason for
every change, and past roughly twenty the answer is to retire rows instead.

`catalog_ratings()` holds *judgements*: how good a model is at coding, with a
`rating_value`, `rating_date`, `rating_method`, `rating_source` and
`rating_confidence`. These are a different kind of claim, cannot be confirmed
the same way, and so are kept somewhere else entirely.

**Every rating currently reads `unknown`, and that is the honest answer.**
Publishers report different benchmarks, public leaderboards disagree and are
not reproducible here, and sorting one vendor's SWE-bench figure against
another's HumanEval figure produces an ordering that means nothing. The
validator enforces the consequence in both directions: a value cannot be
recorded without a method and a source behind it, and a method claiming
evidence cannot be recorded without a value.

Filling them in is what [`./61-rate-models.sh`](61-rate-models.sh) is for — it
measures the models **you** serve and prints rows you can paste in. The shipped
table stays `unknown` because the shipped table cannot contain your
measurements. See [Rating the models you serve](#rating-the-models-you-serve).

This replaced a single `coding_score` column carrying values from 42 to 88 with
no source, no date and no method — weighted at 25% of the recommendation.

Three distinctions the schema enforces, because all three have bitten this
project:

- **`release_date` is the model's, not the GGUF repository's.** A quantizer
  re-uploads whenever they rebuild, so the repo's `lastModified` can be months
  newer than the model. Using one for the other makes an old model look fresh.
  GGUF repository dates are live data and are kept under different names.
- **Sizes are estimates**, derived from parameter count and bits-per-weight,
  and are labelled as such everywhere they surface. They answer "will this
  fit", not "how many bytes will I download". They are *derived* from
  `params_b` rather than stored, so the table cannot assert a size that
  contradicts its own parameter count.
- **Capabilities are only what a primary source states.** `tools` means the
  chat template implements tool calls or the card says so — not that the model
  is probably fine at it. `-` is a legitimate answer.

Verifying the table against the publishers corrected four classes of error, all
of which had been feeding the recommendation:

| What was wrong | Rows affected | Effect |
|---|---|---|
| Context length | 8 of 15 | Qwen3 dense models claimed 131072; `config.json` says 40960. Qwen2.5-Coder claimed 131072; it is 32768. Both inflated the feature score, which bands on exactly those numbers. |
| Tool support | 2 | Gemma 3 was credited with tool calling. Its chat template has no tool branch — 40 points of feature score for a capability it does not have. |
| Parameter counts | 15 | Marketing numbers rather than loaded weights. Qwen3-1.7B totals 2.0B once embeddings are counted. |
| Licence identifiers | 1 | `llama-3.3` where Meta declares `llama3.3`. |

Validate the table at any time:

```bash
bash -c 'source lib/models.sh; catalog_validate || printf "%s" "$CATALOG_ERRORS"'
```

### Laguna, and what a mirror is not

Two rows were added on 2026-08-12: **Laguna XS 2.1** (33.4B total, 2.7B active,
262k context) and **Laguna S 2.1** (117.6B total, 7.8B active, 1M context),
both MoE, both `openmdw-1.1`. Four things about them are worth stating, because
each is a place the table's assumptions had not been tested.

**They are Poolside's, not Unsloth's.** Unsloth mirrors S 2.1 as GGUF and is
where most people meet the model, but `canonical_repo` names the original
publisher — and Unsloth does not mirror XS 2.1 at all, so the mirror is not
even a consistent answer. Poolside publishes GGUFs for both itself.

**The active parameter counts are computed, not copied.** The names say A3B and
A8B; `config.json` says 2.7B and 7.8B. The formula is written above
`catalog_rows()` so you can repeat it. This matters because the speed score is
built on the active count, and rounding it up claims the model is slower than
it is.

**Unsloth's `UD-` quants are not the plain quants they are named after.** They
allocate bits per tensor, so `UD-Q2_K_XL` measures 2.70 bits per weight where
plain `Q2_K` is 3.35 — a 75 GB difference on a 118B model, in the direction
that says it fits. Only the four this repo references have bits-per-weight
entries, each measured from the published files rather than estimated; an
unlisted one fails loudly instead of guessing.

**Their ratings are `unknown` even though a vendor number exists.** Poolside
ships `.eval_results/swe-bench_verified.yaml` in the model repo claiming 70.9%
resolved for XS 2.1. No other row here has a SWE-bench figure, so recording it
would not rank Laguna against the catalog — it would rank *published a number*
against *did not*, and the result would look like a quality judgement while
measuring disclosure practice.

One consequence to be aware of: with every coding rating still `unknown`, the
quality term does no discriminating work, so the ranking runs on freshness,
hardware fit, speed and features. On a 31 GB machine that makes Laguna XS 2.1
the top `medium` pick ahead of `qwen3-coder-30b`, on metadata alone. That is
the existing design behaving as designed, and it is an argument for running
the local benchmark, not for hand-weighting the table.

Running them here: XS 2.1 at `Q4_K_M` is 18.9 GiB and needs both cards
(`-sm layer`); S 2.1 at `UD-Q4_K_XL` is 68.4 GiB and runs with the experts in
system RAM via `-ncmoe`, which is cheap precisely because only 7.8B parameters
are active per token. Support for the architecture reached mainline llama.cpp
in [PR #25165](https://github.com/ggml-org/llama.cpp/pull/25165), merged
2026-07-22 — a build older than that will not load either model. Poolside's
DFlash speculative decoding is *not* upstream and lives only on their fork.

### Live repository metadata

[`lib/hfmeta.sh`](lib/hfmeta.sh) fetches the things that actually change —
downloads, likes, when the GGUF repository was last touched, and the real file
inventory with per-shard sizes. Results are cached under `HF_HOME` for 24
hours, so a normal session makes no repeated API calls.

Every load reports where its data came from, because a download count from
last month should not be presented as current:

| `HFMETA_SOURCE` | Meaning |
| --- | --- |
| `fresh` | Just fetched from the API. |
| `cached` | From the cache, inside the 24-hour TTL. |
| `stale` | The network was unreachable, so an **expired** entry was used. |
| `missing` | Nothing cached and no network — no figures are reported at all. |

Offline, the rig degrades to `stale` and keeps working. With nothing cached it
reports no numbers rather than inventing them.

Note the naming: everything here is `gguf_repo_created` / `gguf_repo_last_modified`.
Those are the **quantizer's** dates, not the model's. Quantizers re-upload
whenever they rebuild, so a GGUF repo's `lastModified` routinely runs a year
ahead of the model inside it — for the fixture in the test suite, 14 months.
Model age comes from the catalog's `release_date` and from nowhere else.

```bash
# Inspect what the rig knows about a repo
bash -c 'source lib/hfmeta.sh; hfmeta_summary unsloth/Qwen3-4B-GGUF; echo'

# Force a refresh
bash -c 'source lib/hfmeta.sh; hfmeta_cache_clear'
```

### How models are ranked

[`lib/score.sh`](lib/score.sh) scores every catalog model 0–100 against your
actual budget, and ranks them **within** each size class rather than in one
global list — on a small card a 4B genuinely outscores a 70B, and you still
want to see them in separate groups.

The classes are **relative to your hardware**, measured as estimated weights
against your usable weight budget:

| Class | Share of budget | Meaning |
| --- | --- | --- |
| Small | ≤ 40% | Fastest, leaves room for a long context and a second model. |
| Medium | 41–80% | **Recommended.** The balance this rig is tuned for. |
| Large | > 80% | Fits tightly, or runs by offloading and is slower. |
| Unsupported | — | Will not run here at any quant, even with RAM to offload into. Shown, but never offered. |

The same model therefore moves between classes on different machines, which is
the entire point: Devstral Small is `large` on a 14 GB budget and `small` on a
40 GB one. Fixed parameter-count bands could not express that — they gave an
8 GB laptop and a 64 GB workstation the same three groups, with every "medium"
model unrunnable on the laptop.

| Component | Weight | What it measures |
| --- | --- | --- |
| Hardware fit | 30% | Does it run here, and with how much headroom. |
| Coding / agent | 25% | Coding quality, from the ratings table — **neutral 50 for every model today**, because no comparable evidence exists. |
| Tools / context | 15% | Tool use, agentic capability, usable context length. |
| Speed | 15% | Driven by **active** parameters, plus an offload penalty. |
| Freshness | 10% | Age of the **model** — never the GGUF repo's timestamp. |
| Repository trust | 5% | Reputation of the account publishing the GGUF. |

**Popularity carries no weight.** Download counts reward whatever has been
popular longest, which is mostly a measure of age and of being the default in
someone's tutorial. It is used only to break an exact tie.

Every score is explainable and every score states its own confidence:

```bash
bash -c 'source lib/score.sh; score_explain qwen3-coder-30b 20000 Q4_K_M unsloth 412300 fresh'
```

```
qwen3-coder-30b  (large, Q4_K_M, moe)
  hardware fit              70  x 30%  =    21
  coding / agent            50  x 25%  =    12
  tools / context          100  x 15%  =    15
  speed                     80  x 15%  =    12
  freshness                 50  x 10%  =     5
  repository trust         100  x  5%  =     5
  TOTAL                     70
  confidence             medium   (facts: hf-api, checked 2026-08-11; live data: fresh)
  rating basis            none   (no comparable evidence; scored at the neutral 50)
  popularity             412300   (tie-breaker only, no weight)
```

The printed contributions are the ones actually summed, so the breakdown always
reconciles with the total. The two provenance lines are separate because the
claims are: the facts behind the size and the context are confirmed against the
publisher, the rating behind a quarter of the weight is not.

Confidence counts three independent kinds of evidence — verified facts, a
sourced rating, and current live data. Three of three is `high`, two is
`medium`, fewer is `low`. **Nothing reaches `high` on the shipped table**,
because no model has a rating; that ceiling lifts on its own once you record
one with [`./61-rate-models.sh`](61-rate-models.sh).

The rating counts only when the rating itself is `medium` or better, and that
qualifier is load-bearing: a single unrepeated benchmark pass is recorded as
`low`, and a hurried run must not be able to raise the confidence of the
ranking it feeds.

Note what the neutral rating does to the ranking: with the quality term equal
for every model, the total is driven by fit and speed, so the smallest model
that fits tends to win outright. That is why the default recommendation leads
with a **Medium** model rather than the top of the list — scoring alone would
point a 48 GB workstation at a 4B.

```bash
# The whole shortlist for a 20 GB usable budget
bash -c 'source lib/score.sh; score_rank 20000'

# Just the best in each size class
bash -c 'source lib/score.sh; score_best_per_class 20000'
```

### Choosing models

`30-models.sh` shows the ranked list and asks for **one to three** models by
number. [`lib/select.sh`](lib/select.sh) builds and parses that menu; it is a
library rather than inline script because the menu and the answer-parsing are
where a selector goes wrong, and none of that is testable from inside a script
whose next step downloads tens of gigabytes.

```
  Medium: RECOMMENDED -- 40-80% of the budget, the balance this rig is tuned for
  6.  Devstral-Small-2507                IQ4_XS      12537  67    confidence: low
  7.  Mistral-Small-3.2-24B-Instruct-2506 IQ4_XS     12750  62    confidence: low
  8.  Qwen3-14B                          Q4_K_M       8935  62    confidence: low

  Small: under 40% of the budget -- fastest, leaves room for a long context
  11. Qwen3-1.7B                         Q8_0         2125  71    confidence: low
```

- MoEs are labelled with their **activated** parameter count, because that is
  what governs generation speed and the cost of offloading.
- Models that cannot run here are listed **without a number**, so the menu
  cannot offer something that will not download.
- The default press-return answer takes one model from each class, Medium
  first.
- `MODEL_SELECTION=1,6` runs the whole thing without prompting, and is exported
  afterwards so a run can be reproduced exactly. Duplicate, out-of-range and
  non-numeric answers are refused by name rather than with "invalid input".

### Rating the models you serve

`./61-rate-models.sh` is the answer to "a quarter of the score is a neutral
placeholder". It runs a fixed suite against the models **this machine actually
serves**, at the quant they are actually served at, and writes the evidence to
`~/llm-rating-<date>.txt`.

```bash
./61-rate-models.sh                    # every served model, one pass each
./61-rate-models.sh --repeats 3        # three passes; any disagreement -> low
./61-rate-models.sh --model qwen3-4b   # one model
./61-rate-models.sh --dry-run          # show the plan, call nothing
```

Read [`lib/rate.sh`](lib/rate.sh) before trusting a number out of it. These
things about it are deliberate and constrain what it can claim:

- **Nothing the model produces is executed.** The obvious way to grade
  generated code is to run it; that means running text from a model on your
  machine, as you, for a score. Every task is graded by reading the response —
  an exact answer, a `tool_use` block, a parse. The task set is written around
  that constraint rather than pretending it is not there.
- **It measures agent-shaped competence, not SWE-bench.** Read a snippet and
  say what it does, pick the right tool with the right arguments, obey an
  output format. Those are the failures that make a local model useless as a
  Claude Code backend. Tool tasks carry double weight, and all three tools are
  offered on every one of them, so a model that always calls the first tool
  fails two of the three.
- **Format tasks are graded strictly; comprehension tasks are not.** The
  distinction is deliberate and is what makes "obey an output format" a claim
  the score actually measures — see the table below.
- **It is comparable across models on your machine and nowhere else.** That is
  the comparison the ranking needs, and it is why the method is called
  `local-benchmark` rather than `benchmark`.
- **The confidence ceiling is `medium`.** Twelve text-graded tasks at one quant
  on one machine does not settle how good a model is at coding. A single pass
  is `low`; two clean repeats are `medium`; `high` is not reachable from here.
- **Completing every task does not earn a catalog row.** A run that cannot say
  which weights, quant, build and live context produced it is written down as a
  diagnostic and refused as evidence — see
  [below](#completing-the-suite-is-not-the-same-as-earning-a-row).

#### Two grading regimes, on purpose

| Kind | Tasks | Graded on |
| --- | --- | --- |
| `answer` | 6 | The last non-empty line, normalised. Fences, quotes, trailing punctuation and preceding prose are stripped: the question is whether the model knows the answer. |
| `tool` | 3 | A `tool_use` block satisfying a jq filter. Wrapping text is irrelevant — the block either exists with the right arguments or it does not. |
| `oneword` | 1 | **The whole response.** Trimmed of surrounding whitespace, it must be exactly the word. A fence, a full stop or a sentence around it is the failure being measured. |
| `json-only` | 1 | **The whole response.** It must parse as a JSON object on its own — no fence, no prose — and satisfy a jq filter. |
| `diff-only` | 1 | **The whole response.** At least one `@@` hunk header, every non-empty line valid diff syntax, and the required line present. A preamble fails. |

The lenient normaliser would otherwise turn `Let me think.\n\nbash.` into
`bash` and pass a task whose entire subject is formatting. A strict kind may
not call it at all, and a test enforces that structurally, so the bug cannot
come back quietly. A model that cannot suppress its preamble cannot be trusted
to emit a patch a tool will apply — that is the thing `diff-only` measures.

Sampling is pinned — temperature 0, fixed seed — and `--repeats` is what checks
that the pinning held. A task that does not give the same verdict every time
counts as unstable, and one unstable task drops the whole run to `low`: a model
that answers differently at temperature 0 is telling you the measurement is
not stable.

#### The artifact records what was running

A served alias does not identify a runtime. `qwen3-4b` fronts whatever GGUF
`30-models.sh` last downloaded, built by whatever `20-build-llamacpp.sh` last
compiled, at whatever context `40-serve.sh` last configured — so two runs that
disagree could otherwise produce the same catalog row. Each run therefore
records:

| Field | Read from | Required |
| --- | --- | --- |
| llama.cpp revision | `.llamacpp-rev`, written by the build | yes |
| weights | the `-m` path in the generated `llama-swap.yaml`, per model | yes |
| quant | the filename **on disk**, not the catalog's preference — the reason to record it is that the two can differ | yes |
| live `n_ctx` | `/props` on the upstream serving *those* weights | yes |
| serving flags | the per-model flags in the same config, including `CUDA_VISIBLE_DEVICES` | no — a model can legitimately have none |

Anything that cannot be read is written as `unavailable`. The live context is
matched by model path rather than taken from the first server that answers:
with several models loaded, the first answer is some other model's context,
and recording that is worse than recording nothing. The quant also appears on
the `RESULT` line, so two ratings taken at different quants cannot be compared
by accident.

`unavailable` and `none` are different answers and the distinction decides
whether a row can be written. `none` means the field was read and there was
nothing there — a model served on every GPU with no overrides genuinely has no
per-model flags. `unavailable` means the field could not be read at all.
Writing `unavailable` for both would make a config nobody could open look like
a deliberately plain one.

#### Completing the suite is not the same as earning a row

Twelve passing tasks say the suite ran. They do not say what it ran against —
and `qwen3-4b;93;…` with an unidentified runtime is a number attached to an
alias, which the next re-run of `30-models.sh` silently invalidates. So a run
is offered as a catalog row only when **all four required fields above** were
established. Otherwise the artifact is written in full, the `RESULT` line
carries `provenance=missing:<fields>`, and the script names the gaps instead of
printing a row:

```
!! qwen3-4b: no catalog row -- incomplete runtime provenance: weights,quant,live-n_ctx
```

The requirement is written into the artifact's own header, so a file read a
year later explains on its own terms why it did or did not produce a row. This
is not a hypothetical: the first real run of this suite completed 12/12 on
three models with `etc/llama-swap.yaml` missing, and every field of its
runtime identity reads `unavailable`.

The script **does not edit the catalog**. It prints rows to paste:

```
qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium
```

The source is the artifact's **basename**, not a URL. There is no https address
for a file in your `$HOME`, and the validator refuses an invented one —
`local-benchmark` must cite `file:<artifact>.txt`, `vendor-benchmark` must cite
https. A table that is curated by hand is not improved by a script that
rewrites its own evidence base, so the paste is manual and the run that
produced it is a file you can open.

A run where any task errored is written down but **not** offered as a row: a
partial run is a report, not evidence. The same applies to a complete run whose
runtime could not be identified, and to a model that is not in the catalog —
each of the three prints its own reason rather than a shared "nothing to
record".

### The llama-swap binary is pinned and verified

`40-serve.sh` installs executable code into `/usr/local/bin` as root, so it
installs a **named version whose SHA-256 matches**, or it installs nothing.

```bash
./40-serve.sh                              # installs the pinned default
LLAMA_SWAP_VERSION=v248 ./40-serve.sh      # a different version, explicitly
```

The pinned default lives in [`lib/swap.sh`](lib/swap.sh) (`SWAP_VERSION`),
alongside the SHA-256 of that version's `linux_amd64` tarball. Two runs of the
same llm-rig revision therefore install the same bytes. Previously this fetched
`releases/latest` — a moving target — with no checksum at all, and fell back to
`go install ...@latest`, so two runs a week apart could differ and nothing would
say so.

| Rule | Why |
| --- | --- |
| A digest pinned in llm-rig is the authority; upstream's `checksums.txt` is used only for versions not pinned here | A release asset can be replaced under the same tag, and its checksums file re-uploaded with it |
| No checksum from either source ⇒ **refuse** | "Could not check" is not "checked" |
| A mismatch ⇒ **stop**, and do not try another route | The bytes are not what this version should be. Quietly acquiring it another way buries the one signal worth looking at |
| Exactly one asset may match, or refuse | The old broad pattern took the first match of a list that includes `linux_arm64` |
| The existing binary is replaced by a rename, only after verification | No window where `/usr/local/bin/llama-swap` is half-written, and a failed install leaves the working binary exactly where it was |
| The source fallback builds the **same tag** | `@latest` meant the machine whose download failed silently ran a different version from every other machine |

What was installed is recorded in `~/llm-rig/etc/llama-swap.installed` and
printed on every run:

```
version       v249
sha256        3a7f59d5dcbc518f4513f23522cea7d0848c2cec4d24a5e164ce5055d228dbb9
source        release tarball, verified pinned in llm-rig
installed_at  2026-08-12T09:14:22Z
```

Re-running with the same version does nothing and says so. Changing version is
stated explicitly (`llama-swap v248 installed; this llm-rig revision pins v249`).

**Upgrading.** Bump `SWAP_VERSION` in `lib/swap.sh` and add the new version's
digest to `swap_pinned_digests()` in the same commit — the digest is the point
of the pin, and a version without one silently downgrades to trusting upstream:

```bash
V=250
curl -sfL https://github.com/mostlygeek/llama-swap/releases/download/v$V/llama-swap_${V}_checksums.txt \
  | grep linux_amd64
```

**Rolling back.** The binary that was replaced is kept next to the new one, so
the fastest path needs no network:

```bash
sudo mv /usr/local/bin/llama-swap.previous /usr/local/bin/llama-swap
```

Or reinstall a known version, verified the same way as any other:

```bash
LLAMA_SWAP_VERSION=v248 ./40-serve.sh
```

A source-built binary records `built from source at <tag> (digest recorded, not
verified)`. Go builds are not bit-identical across toolchains, so its digest is
a record of what was produced, not evidence that it matches anything.

## Configuration

Everything is derived from detected hardware, and everything is overridable by
environment variable.

```bash
# Choose from the ranked menu without being prompted, by menu position
MODEL_SELECTION=1,6 ./30-models.sh

# Pin exact model repos, skipping the live HuggingFace resolver
PICK_1=unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
PICK_2=unsloth/Devstral-Small-2507-GGUF \
  ./30-models.sh

# Override the quant preference for any pick
Q1_OVERRIDE='Q6_K|Q5_K_M' ./30-models.sh

# Build a specific llama.cpp revision, or point at your own checkout
LLAMA_REF=b4585 ./20-build-llamacpp.sh
LLAMA_DIR=~/src/my-llama.cpp ./20-build-llamacpp.sh

CTX=65536 ./40-serve.sh       # override context length (see the caveat below)
POWER_PCT=85 ./10-os-tune.sh  # cap power, if your chassis has thermal headroom
```

A quant preference is an **ordered alternation**, not a regular expression:
`'IQ4_XS|Q4_K_S'` means "take IQ4_XS if the repo has it, otherwise Q4_K_S". Alternatives
are tried strictly left to right, so preference order always wins over filename order.
Each individual alternative is matched as a case-insensitive extended regex, so
character classes work if you want them. Invalid expressions are rejected before any
network or download work happens.

`CTX` is **authoritative**. If you set it, that is the context you get — model selection
sizes against it, and `40-serve.sh` serves it. If it genuinely cannot fit, you get an
error naming the context and what it costs, not a silent downgrade. Left unset, the
default is tier-aware: 32k under 11 GB, 64k under 24 GB, 128k above.

The KV reserve follows from the context rather than being a constant, so asking for more
context correctly buys you a *smaller model* instead of an OOM at load time:

```bash
CTX=262144 ./30-models.sh    # reserves ~14 GB for KV, shortlists smaller models
```

The default geometry is the 30B-A3B class this stack is tuned for — 48 layers, 4 KV
heads, head dim 128, 1 byte/element at q8_0, i.e. 48 KiB/token, plus 15% headroom.
Override it with `KV_LAYERS` / `KV_HEADS` / `KV_HEAD_DIM` / `KV_BYTES` for a model with
different geometry, or set `KV_RESERVE_MB` to bypass the derivation entirely. Both the
effective context and the reserve (with where each came from) are printed by
`00-specs.sh`, `30-models.sh`, and `40-serve.sh`.

### Your llama.cpp checkout is safe

`20-build-llamacpp.sh` never rewrites a checkout it did not create. If `LLAMA_DIR` points
at your own clone, it is treated as **read-only**: the script builds exactly the revision
you have checked out — uncommitted changes included — and never fetches, checks out, or
resets. A clone the script made itself is marked, and only those are updated to
`LLAMA_REF` (and even then it refuses if you have uncommitted work).

Builds are **out-of-tree**, in `~/llm-rig/build/llamacpp`, so compiling cannot touch your
source tree at all and your own `build/` directory is left alone.

A rebuild deletes the build directory first, so it is only ever allowed to run against a
directory llm-rig positively owns — being "not obviously dangerous" is not enough. A
build directory qualifies when it is under `~/llm-rig/build`, or when it does not exist
yet, or when it carries the `.llm-rig-build` marker we wrote on a previous run. Anything
else is refused untouched, including `$HOME`, system paths, the checkout, and any
existing directory of your own:

```bash
LLAMA_BUILD_DIR=~/Documents ./20-build-llamacpp.sh   # refused, nothing deleted
LLAMA_BUILD_DIR=~/scratch/llama-build ./20-build-llamacpp.sh   # fine: created and marked
touch ~/existing-build/.llm-rig-build                # deliberately hand one over
```

Symlinks and `..` are resolved before any of that is decided, so neither can be used to
launder a path into looking owned.

The built commit is recorded in `.llamacpp-rev`. Pin it for reproducible rebuilds:

```bash
echo <commit> > ~/llm-rig/llamacpp.ref
```

Without a pin the build tracks `master`, and the script says so rather than letting the
next run silently produce something different.

Generated artifacts — regenerate rather than hand-edit, they get overwritten:

- `etc/llama-swap.yaml` — model definitions and serving flags (`40-serve.sh`)
- `claude-code-local.env` — Claude Code environment (`50-claude-code.sh`)

## Using it

```bash
cd ~/llm-rig
source claude-code-local.env && claude
```

The env file maps Claude Code's opus/sonnet/haiku requests onto the models you actually
serve, caps output tokens, and sets `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` — that last one
is a deliberate prefix-cache decision, not just token thrift; see
[TUNING.md § Serving configuration](TUNING.md#serving-configuration).

From another machine on the LAN, point `ANTHROPIC_BASE_URL` at this host's address
instead of `127.0.0.1` (ufw restricts :8081 to the local subnet).

### What `71-verify-runtime.sh` will and won't claim

It grades every claim by how it was established, and never conflates the grades:

| Grade | Means |
|---|---|
| `[configured]` | The flag is in the generated config. Says what was *asked for*. |
| `[live]` | The running server reported it via `/props`. Strongest. |
| `[benchmark]` | Inferred from timings measured **on this machine**. |

If no benchmark artifact exists it reports **"not measured"** rather than substituting a
figure from anywhere else, and a `--flash-attn` line in the config never on its own
establishes that flash attention is active.

```bash
./71-verify-runtime.sh --measure              # take a bounded measurement now
./71-verify-runtime.sh --require props        # exit non-zero unless established
./71-verify-runtime.sh --require flash-attn --require props
```

`--require` turns it into a gate: non-zero when the assertion cannot be **established**,
which is not the same as it being false. Upstream ports are derived from the generated
`startPort` and model count, so a non-default `startPort` is probed correctly.

## Tests

```bash
./tests/run.sh
```

That runs `bash -n` on every script, ShellCheck, and the fixture suites. It needs
**no GPU, no sudo, no network, and no model downloads** — hardware and every external
command are replaced by mocks under `tests/mocks/bin`, and GPU profiles are TSV fixtures
in `tests/fixtures/gpu`.

```bash
./tests/run.sh detect      # only suites matching "detect"
./tests/run.sh --no-lint   # skip syntax + ShellCheck
```

ShellCheck is skipped with a notice if it isn't installed locally; CI always enforces it
at `--severity=warning`. Install it with `sudo apt-get install -y shellcheck`.

The "no network" claim is enforced rather than asserted:

```bash
./tests/isolated.sh              # re-run the suites inside a network namespace
./tests/isolated.sh --check-only # just prove the isolation, run nothing
```

It enters a namespace with no interface but loopback, proves from inside that outbound
connections fail, and **exits non-zero if it cannot establish or prove that** — a check
that skips itself is not a check. CI runs it after the normal pass.

The runner also fails closed on discovering nothing to do: a broken `find`, an
unrecognisable tree, an empty `cases/`, a suite with no `test_*` functions, or a filter
that matches no suite all exit non-zero. Reporting `ALL PASSED` after running zero tests
is the one failure mode a test runner must never have.

Adding hardware to test against is a data file, not a code change — drop a new TSV in
`tests/fixtures/gpu/`, or call `synth_gpu <free_mb> [count]` for an exact boundary value.

## Troubleshooting

```bash
systemctl status llama-swap
journalctl -u llama-swap -n 50
curl -s http://127.0.0.1:8081/v1/models | jq -r '.data[].id'
./71-verify-runtime.sh
```

| Symptom | Likely cause |
|---|---|
| Tool calls silently do nothing | `--jinja` missing. Tool calling does not work without it. |
| LiteLLM got installed | The `/v1/messages` probe failed — usually an llama-server build predating native Anthropic support. Rebuild with `20-build-llamacpp.sh`, then re-run `50-claude-code.sh`. |
| Context overflow errors | Intended. `--no-context-shift` fails loudly rather than silently dropping your oldest tokens. |
| Model OOMs on load | Check `KV_RESERVE_MB` vs your `CTX` (see caveat above). |
| Benchmarks look slow | Something else is holding VRAM — `60-bench.sh` frees the GPUs first, but a stray `llama-server` will skew results. |
| `90-remove-ollama.sh` refuses to run | Working as intended. It now proves the replacement stack end to end before touching anything — see below. |

### The Ollama removal preflight

`90-remove-ollama.sh` removes your only other working runtime, so it fails **closed**. It
resolves the endpoint Claude Code is actually configured against (parsed out of
`claude-code-local.env`, falling back to native mode), then requires all three of:

1. `/v1/models` returns at least one model;
2. that model answers a `/v1/messages` request;
3. the response to a tool-calling probe contains a `tool_use` block.

Only then does it prompt. Nothing is stopped, removed, or moved until every check has
passed — a failed preflight leaves Ollama completely untouched.

The third check is the one that matters: an active `llama-swap` unit proves only that a
router is listening, not that it can do the one thing Claude Code needs. A stack that
fails it is almost always missing `--jinja`.

`FORCE=1` overrides a failed preflight, after a warning and a five-second pause. Use it
only if you know why the check is wrong.

## Rollback

- OS tuning: `./19-os-revert.sh` — see [what "reversible" means](#what-reversible-means) below
- Services: `sudo systemctl disable --now llama-swap` (and `litellm`, if present)
- Ollama: weights were moved to `~/.ollama.removed-<date>` and
  `~/ollama-models.removed-<date>`, not deleted

### What "reversible" means

`10-os-tune.sh` captures the **effective prior value of every setting it
changes**, one at a time, immediately before changing it. The capture goes to
`/var/lib/llm-rig/os-tune.state`, root-owned and `0600`. `19-os-revert.sh`
restores from that file and from nothing else.

This is a stronger claim than the one this README used to make. The old revert
wrote fixed defaults — `THP=madvise`, `governor=schedutil`, power at maximum,
persistence off — and `rm -f`'d three paths under `/etc` it had never proven it
owned. On a machine that already had a governor policy, a THP setting, or its
own `99-llm-inference.conf`, that was not a rollback. It was a second round of
configuration, and in the file case a deletion of somebody else's work.

| Rule | What it prevents |
| --- | --- |
| Capture happens before the first mutation, per setting | A crash halfway through still leaves an exact record of what changed |
| Capture is append-once | A second tune re-recording *llm-rig's own* values as the ones to restore — which turns the rollback into a no-op |
| A pre-existing file is backed up byte for byte before being overwritten, and restored byte for byte | Losing configuration that was there first |
| A file that cannot be backed up is not overwritten at all | Overwriting something we could not preserve |
| A file we wrote is deleted only if it still holds what we wrote | Deleting your edits — an edit is a claim of ownership |
| Per-CPU governors are captured and restored individually | Flattening a machine that deliberately ran different governors on different cores |
| An unreadable prior value is recorded as `unknown` and never "restored" | Substituting a guess for a value nobody read |

Both scripts take `--dry-run`, which prints every intended mutation with its
current value and needs no `sudo`:

```bash
./10-os-tune.sh --dry-run
./19-os-revert.sh --dry-run
```

```
  THP enabled                        madvise -> always
  governor cpu0                      schedutil -> performance
  GPU 0 power limit (W)              140 (already set)
  /etc/sysctl.d/99-llm-inference.conf  YOURS -> backed up, then overwritten
```

Reverting twice is a no-op rather than an error, and a revert that could not
finish keeps the state file so a later run can complete it. If a setting cannot
be restored, that is reported and the exit status is non-zero — the one thing
this must never do is report success for a rollback that did not happen.

## License

[MIT](LICENSE).

Note that `10-os-tune.sh` takes `sudo` and changes system state — GPU power and
persistence, CPU governor, transparent hugepages, and sysctls. Read it before running
it, as you should with any script that asks for root. `./10-os-tune.sh --dry-run` prints
everything it would change without using `sudo` at all, and `19-os-revert.sh` puts back the
values it captured — see [what that guarantees](#what-reversible-means).
