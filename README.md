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
`rating_value`, `rating_date`, `rating_method`, `rating_source`,
`rating_confidence` and — for local measurements — `rating_suite`, the version
of the suite that produced the number. These are a different kind of claim,
cannot be confirmed the same way, and so are kept somewhere else entirely.

**Five ratings are measured; the other eleven read `unknown`, and that is
the honest answer.** Publishers report different benchmarks, public leaderboards
disagree and are not reproducible here, and sorting one vendor's SWE-bench
figure against another's HumanEval figure produces an ordering that means
nothing. The validator enforces the consequence in both directions: a value
cannot be recorded without a method and a source behind it, and a method
claiming evidence cannot be recorded without a value.

The exceptions are `laguna-xs-2.1` (100), `qwen3.8-27b` (100),
`qwen3-coder-30b` (93) and `devstral-small-2` (80), measured here with
[`./61-rate-models.sh`](61-rate-models.sh) under suite v3 on 2026-08-14 and
2026-08-15 — three repeats each, no disagreement between them, each against a
named artifact. That is the only kind of number this table accepts. Note the
tie: on measured coding quality Laguna XS 2.1 and Qwen3.8 are
indistinguishable — both hit the suite's ceiling.

Two small models have been run without becoming measured, and both stay
`unknown`. `qwen3-1.7b` hit the boundary first: suite v3 rejected its run as
incomplete — 10 of 12 tasks answered, the other two truncated at the fixed
1024-token budget before this small reasoner finished thinking
([#63](https://github.com/rammsguns/llm-rig/issues/63) tracks the gap). Its
weights are preserved outside the scanned models directory, but it is
no longer served: `qwen3.5-2b` replaced it as the served small default — and
proved non-recordable under the same terms, harder. 7 of 12 tasks answered,
five truncated in every one of three repeats, one genuine graded failure
([#79](https://github.com/rammsguns/llm-rig/issues/79) records the
evidence). Each run's artifact records a diagnostic value — 80 and 60
respectively — computed the way every run is computed: earned weight over
the suite's full 15 points, with truncated tasks contributing zero. The
arithmetic is not the problem — the evidence is. A truncated task is
neither a pass nor a failure, so a value that had to score them as zero is
not a rating, and this table carries neither. What the rows show instead is
an explicit coverage gap the
[completeness gate](#a-truncated-response-is-not-a-wrong-answer)
refuses to disguise.

Filling in the rest is what [`./61-rate-models.sh`](61-rate-models.sh) is for —
it measures the models **you** serve and prints rows you can paste in. Rows for
models you do not serve stay `unknown`, because the shipped table cannot
contain your measurements. See
[Rating the models you serve](#rating-the-models-you-serve).

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

**The vendor number never became a rating, even after one of them was
measured.** Poolside ships `.eval_results/swe-bench_verified.yaml` in its
model repos. No other row here has a SWE-bench figure, so recording one would
not rank Laguna against the catalog — it would rank *published a number*
against *did not*, and the result would look like a quality judgement while
measuring disclosure practice. XS 2.1's rating row was instead filled the
same way as every other measured row — by the local suite — and S 2.1 stays
`unknown` until the same suite runs it.

One consequence to be aware of: with eleven of sixteen coding ratings
still `unknown`, the quality term barely discriminates among the unmeasured,
so their ordering runs mostly on freshness, hardware fit, speed and features.
On a 31 GB machine that once made Laguna XS 2.1 the top `medium` pick ahead
of `qwen3-coder-30b` on metadata alone — an ordering the first measurements
reversed (84 against its placeholder-fed 81) precisely because it was
metadata, not evidence. The suite-v3 measurement of Laguna itself closed that
loop on 2026-08-15: a perfect 100, twelve tasks over three repeats without a
flip. Its composite lands at 94, back on top of the class it once led by
default — but this time the comparison is like for like. The measured five —
94, `qwen3.8-27b`'s 85, `qwen3-coder-30b`'s 84, `devstral-small-2`'s 77 and
`qwen3-coder-next`'s 71 — share one suite and one machine, and three of them
are **tied at 100 on measured coding quality**: Laguna's composite lead over
Qwen3.8 and Coder-Next is speed and fit (2.7B active parameters against a
27.8B dense forward pass, and against experts that partly run from system
RAM), not a coding-quality verdict. Running the benchmark is what fixes the
remaining eleven rows too.

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
| Coding / agent | 25% | Coding quality, from the ratings table — measured for `laguna-xs-2.1`, `qwen3.8-27b`, `qwen3-coder-30b` and `devstral-small-2`, **neutral 50 for every other row**, because no comparable evidence exists yet. |
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
  coding / agent            93  x 25%  =    23
  tools / context          100  x 15%  =    15
  speed                     80  x 15%  =    12
  freshness                 50  x 10%  =     5
  repository trust         100  x  5%  =     5
  TOTAL                     81
  confidence              high   (facts: hf-api, checked 2026-08-11; live data: fresh)
  rating basis           medium   (local-benchmark, 2026-08-13)
  popularity             412300   (tie-breaker only, no weight)
```

The printed contributions are the ones actually summed, so the breakdown always
reconciles with the total. The two provenance lines are separate because the
claims are: the facts behind the size and the context are confirmed against the
publisher, and the rating behind a quarter of the weight is confirmed — or, for
every other row, is not.

Confidence counts three independent kinds of evidence — verified facts, a
sourced rating, and current live data. Three of three is `high`, two is
`medium`, fewer is `low`. **Only the five measured rows can reach `high`**,
because they are the only ones with ratings; every other row is capped at
`medium` until you record one with
[`./61-rate-models.sh`](61-rate-models.sh).

The rating counts only when the rating itself is `medium` or better, and that
qualifier is load-bearing: a single unrepeated benchmark pass is recorded as
`low`, and a hurried run must not be able to raise the confidence of the
ranking it feeds.

Note what the neutral rating does to the ranking: with the quality term equal
across eleven of the sixteen rows, the total is driven mostly by fit and
speed, so the smallest model that fits tends to win outright. That is why the
default recommendation leads with a **Medium** model rather than the top of the
list — scoring alone would point a 48 GB workstation at a 4B.

It also means the measured rows have to be read for what they are.
`laguna-xs-2.1` leads the `medium` class on this rig at 94, with
`qwen3.8-27b` at 85 and `qwen3-coder-30b` at 84 — the top three measured, on
the same suite, on the same machine. Directly behind them the table shows the
trap this section exists for: the unmeasured `qwen3.6-35b-a3b` at 79 sits
above the measured `devstral-small-2` at 77, entirely on card-claimed
capabilities and fit — that gap is not a quality verdict, because one side of
it has never run the suite. Another reading trap sits at the top: Laguna, Qwen3.8 and Coder-Next are
**tied at 100 on measured coding quality** — suite v3 cannot separate them —
so the composite points between them are speed and fit, not a verdict on who
writes better code. The rest of the ordering only becomes a quality judgement
when the rows being compared are measured too.

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
./61-rate-models.sh --model qwen3.5-4b # one model
./61-rate-models.sh --dry-run          # show the plan, call nothing
```

`--model` accepts an **advertised** served name or a catalog id — exactly, no
prefixes — where advertised means listed by the endpoint's `/v1/models`. A
config alias is selectable only when the endpoint actually advertises it
(issue #81: llama-swap does not necessarily list aliases there, so the script
never recommends one it has not seen advertised). When an argument matches
more than one served model, the refusal names each candidate with the
advertised identifiers that select only it; if no identifier disambiguates,
the serving identity itself has to change before that model can be rated.

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

#### A truncated response is not a wrong answer

The budget is **1024 tokens of total completion output — reasoning plus
answer**. Total, because `max_tokens` is the only budget the API enforces
deterministically and it counts every generated token; the *grade* still reads
only the answer (see below). Suites v1 and v2 ran at 256, calibrated for
models that answer directly. A reasoning model spends most of its completion
on hidden thinking before the answer — the first one measured needed 380
tokens for the simplest possible one-hunk diff — so 256 starved it on a task
it could do, and 512 would merely wait for a slightly more verbose reasoner to
starve the same way. 1024 leaves headroom while staying small enough that a
degenerate reasoning loop still fails visibly as truncation. What the old
small budget used to measure — output discipline — is carried entirely by the
strict format kinds, which grade the whole response and are indifferent to
budget.

Even at a budget that fits, a model can still run out. Graded as an ordinary
failure that produces a low number which looks *stable* across repeats —
stable because the cap is deterministic, not because the model is reliably
wrong — and in the catalog it is indistinguishable from a model that genuinely
cannot do the task. So a response whose `stop_reason` is `max_tokens` (or
`length`, the spelling llama.cpp's OpenAI-compatible path uses) is classified
as **incomplete**, not failed:

```
  task comprehension-loop   incomplete: max_tokens (stop_reason=max_tokens, max_tokens=1024)
```

The rule runs in one direction only. It can turn a failure into an incomplete;
it can never touch a pass. A truncated response that still emitted the right
tool call, or the bare word, passes — the model did the thing before the cap
cut off whatever came next. Only the *failing* truncated case is ambiguous:
it might be a wrong answer or an unfinished one, and nothing in the response
tells them apart, so it is recorded as neither. A response that does not say
why it stopped is graded normally; guessing truncation from a missing field
would make every server that omits it unratable.

Hidden reasoning is never graded as the answer. Only `text` blocks reach the
grader — `thinking` blocks and `reasoning_content` fields are ignored — so a
model that reasons its way to `6` without ever saying `6` has not answered.

An incomplete task does not count as answered, so it blocks the pasteable row
through the same gate an HTTP error goes through, and the `RESULT` line carries
`incomplete=<n>`. **Raising the budget is a diagnostic, not a fix:**

```bash
RATE_MAX_TOKENS=4096 ./61-rate-models.sh --model qwen3.8-27b
```

Those numbers are not comparable with the default ones and cannot be recorded
as a rating. Under v2 that was a convention; under v3 it is a gate — the
default lives in `RATE_MAX_TOKENS_DEFAULT`, separate from the override, and a
run at any other budget is measured, written to the artifact with the value it
used, and refused a row with the reason named (`non-default sampling`).

#### One leaderboard, one suite version

Two ratings from different suite versions are not comparable — v2 changed what
`answered` means, v3 changed the budget — so the version is recorded wherever
a number travels: the artifact header says `suite: v3`, the machine-readable
`RESULT` line carries `suite=v3`, and the catalog row carries it as
`rating_suite`. One token, derived in one place (`lib/rate.sh`), so the three
cannot disagree.

The catalog enforces comparability structurally: the validator rejects any
table in which two `local-benchmark` rows carry different suite versions.
Upgrading the suite therefore means re-rating **every** measured model and
landing the replacement rows together — a partial submission fails CI instead
of waiting for a reviewer to notice a mixed leaderboard. That path has been
walked once already: when the `rating_suite` column arrived, the existing
`qwen3-coder-30b` row was annotated `v2` and otherwise left untouched, and it
stayed that way until the v3 re-rating replaced the whole row — landed in the
same change as `qwen3.8-27b`'s first measurement, because the validator would
have refused them apart.

A direct (non-reasoning) model re-rated under v3 is expected to reproduce its
v2 result — identical task outcomes and identical normalized graded answers —
because at temperature 0 a bigger cap only matters to responses that
previously hit it. Artifacts and raw generation are not guaranteed
byte-identical; the claim is about what the grader sees. A divergence in task
outcomes on the re-rating is a finding about the serving stack, to be
investigated before either row is recorded. The coder re-rating bore this
out: the same eleven tasks passed, the same one (`format-diff`) failed, and
the value came out at 93 both times.

The suite history, so far: **v2** reclassified truncation — the arithmetic was
untouched, but the same responses could yield a different `answered`, and
therefore a different confidence, which is part of the row. **v3** raised the
budget from 256 to 1024 and made the version itself part of every artifact and
catalog row.

#### The artifact records what was running

A served alias does not identify a runtime. `qwen3.5-4b` fronts whatever GGUF
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
and `qwen3.5-4b;93;…` with an unidentified runtime is a number attached to an
alias, which the next re-run of `30-models.sh` silently invalidates. So a run
is offered as a catalog row only when **all four required fields above** were
established. Otherwise the artifact is written in full, the `RESULT` line
carries `provenance=missing:<fields>`, and the script names the gaps instead of
printing a row:

```
!! qwen3.5-4b: no catalog row -- incomplete runtime provenance: weights,quant,live-n_ctx
```

The requirement is written into the artifact's own header, so a file read a
year later explains on its own terms why it did or did not produce a row. This
is not a hypothetical: the first real run of this suite completed 12/12 on
three models with `etc/llama-swap.yaml` missing, and every field of its
runtime identity reads `unavailable`.

The script **does not edit the catalog**. It prints rows to paste:

```
qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium
```

The source is the artifact's **basename**, not a URL. There is no https address
for a file in your `$HOME`, and the validator refuses an invented one —
`local-benchmark` must cite `file:<artifact>.txt`, `vendor-benchmark` must cite
https. A table that is curated by hand is not improved by a script that
rewrites its own evidence base, so the paste is manual and the run that
produced it is a file you can open.

A run where any task errored or came back incomplete is written down but
**not** offered as a row: a partial run is a report, not evidence. The same
applies to a complete run whose runtime could not be identified, and to a model
that is not in the catalog — each prints its own reason rather than a shared
"nothing to record".

### The llama-swap binary is pinned and verified

`40-serve.sh` installs executable code into `/usr/local/bin` as root, so it
installs a **named version whose SHA-256 matches**, or it installs nothing.

```bash
./40-serve.sh                                        # fresh machine: installs the pinned default
LLAMA_SWAP_VERSION=v248 ./40-serve.sh --reconcile-swap  # a different version, doubly explicit
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

Re-running with the same version does nothing and says so. **Changing an
installed version requires `--reconcile-swap`**: a full run that finds the
installed binary differing from the pin refuses before anything changes — the
service is not stopped, nothing is downloaded, no config is written — and
prints the exact re-run command, original arguments preserved, with the flag
appended. Serving models and replacing the runtime are separate decisions, and
a run asked to do the first does not silently perform the second (#46). A
genuinely absent binary still bootstraps without the flag — a first-time
install has nothing to preserve — but an executable that *exists* and will not
report a version fails closed, flag or no flag: "replace it" would be a guess
about what is being replaced. Inspect it; if replacing is right, move it aside
and re-run.

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

Or reinstall a known version, verified the same way as any other — the flag is
required because the installed binary differs from the version being asked for:

```bash
LLAMA_SWAP_VERSION=v248 ./40-serve.sh --reconcile-swap
```

A source-built binary records `built from source at <tag> (digest recorded, not
verified)`. Go builds are not bit-identical across toolchains, so its digest is
a record of what was produced, not evidence that it matches anything.

### Two quants in one directory is a question, not a default

`40-serve.sh` names a served model after the **directory** its weights sit in —
`Qwen3-Coder-30B-A3B-Instruct-GGUF/` becomes `qwen3-coder-30b-a3b-instruct`.
The key has to be stable, because `catalog_ratings()` joins to it by name.

Put two quantisations in that one directory and both files derive the same key.
The generated YAML would then declare one model twice, and a parser either
rejects it or silently keeps the last one — which is the worse outcome, because
the stack comes back up serving a different quant under a name whose every
recorded measurement was taken at the old one.

Note what that does *not* trip: the provenance gate would report `complete`,
because every required field is populated — just populated with a model nobody
chose. **Completeness and correctness are different properties.**

So generation refuses, and says what it found:

```
  XX qwen3-coder-30b-a3b-instruct: 2 candidates, and no selection says which one:
        <models-dir>/Qwen3-Coder-30B-A3B-Instruct-GGUF/…-Q4_K_M.gguf
        <models-dir>/Qwen3-Coder-30B-A3B-Instruct-GGUF/…-UD-Q5_K_XL.gguf
      settle it with:  --select qwen3-coder-30b-a3b-instruct=<exact path above>
```

Name the exact file to settle it:

```bash
./40-serve.sh --select qwen3-coder-30b-a3b-instruct=<models-dir>/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
```

`--select` may be repeated, and it takes a **path, not a preference**. Nothing
picks by sort order, mtime, size, or what the catalog would rather have: those
all silently produce an answer, and a silent answer is what caused this. A
selection naming an unknown key, a file that does not exist, a file belonging
to another key, or a later shard of a split model is refused with the reason,
and every bad selection in one invocation is reported together rather than one
per run.

Three properties worth knowing:

- **It fails before anything changes.** The check runs above `ensure_gpus_idle`,
  because unloading resident models is already a change to what the machine is
  serving. An ambiguous directory aborts while the running stack is still
  intact — not after the GPUs are freed and the config is half-replaced.
- **The config is replaced atomically.** It is generated beside the real file,
  read back and checked against the resolved plan — every key declared once,
  every `-m` path the one that was chosen — and only then renamed over the
  canonical path. A verification failure leaves the existing config in place.
- **Split models are unaffected.** A `-00001-of-00003` set is one candidate;
  llama.cpp opens the rest itself, and counting the other shards would make
  every split model collide with itself.

### Regenerating the config without replacing the runtime

A full `40-serve.sh` run does five things: installs the pinned llama-swap
binary, generates the config, writes the systemd unit, restarts the service,
and applies firewall rules. Sometimes you only want the second one.

```bash
./40-serve.sh --config-only
```

That writes `etc/llama-swap.yaml` and stops — no binary install, no unit
rewrite, no restart, no firewall change — then tells you the config is not live
yet and prints the restart command. On the common path it needs no root at all:
the config lives in a user-owned directory.

It exists because **"make the config say something different" and "replace the
runtime" are separate decisions**, and a run that only needed the first should
not silently perform the second. The sharp case: `40-serve.sh` skips the
install when the installed version already matches the pin, but when they
*disagree*, a full run used to upgrade the binary — potentially underneath a
stack whose measurements were taken against the old one. Since #46 that run
**refuses instead**, before the service is stopped or anything is written, and
upgrading requires saying so:

```bash
./40-serve.sh --reconcile-swap
```

`--config-only` sits on the other side of the same line: it does not compare
against the pin at all, because the situation where you most need the runtime
left alone is exactly the situation where the versions differ. The two flags
together are a contradiction and are refused as one.

It composes with `--select`, and an ambiguous serving key still fails closed
before anything is written.

**It will not free the GPUs for you.** Generating a config means sizing against
free VRAM, and a full run gets that by stopping llama-swap. Config-only will
not: stopping the daemon *is* the change the mode promises not to make, and it
is the worst one available, because a running llama-swap holds the only copy of
the config it was started with. Replace the file while it is stopped and the
previous configuration is simply gone. So if `llama-server` or `llama-swap` is
holding any VRAM at all, the run refuses before writing anything and hands you
the sequence:

```bash
sudo systemctl stop llama-swap
./40-serve.sh --config-only --select …
sudo systemctl start llama-swap
```

Same flags echoed back, because a `--select` path retyped by hand is how the
wrong quant ends up being served.

Anything *else* holding VRAM is judged by amount rather than refused outright.
`nvidia-smi` enumerates graphics contexts alongside compute ones, so on a
machine with a display attached the list is never empty — a compositor, a
browser and a couple of terminals came to ~620 MiB on the rig this was written
for, against a smallest served model of ~13.7 GB. Up to **2048 MiB** in total
is reported and tolerated; above that the run refuses, because sizing against
what is left would produce bogus `--n-cpu-moe` values. That refusal does *not*
suggest stopping llama-swap — doing so would not release a byte of someone
else's job. A usage figure `nvidia-smi` cannot report is read as the worst case
and refused.

Nothing else creates `logs/` in this mode either — it belongs to the service,
which config-only does not install.

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

# Per-model context override (issue #65): the entry named by KEY alone gets
# `-c N` after the shared macro, so its config stops claiming a context the
# runtime silently re-derives. Useful when a model's native maximum sits below
# the shared default. Validated against the serving plan; advisory-checked
# against the catalog; with no --ctx the config is byte-for-byte unchanged.
./40-serve.sh --ctx KEY=N
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

### The compute pool

By default every detected GPU is eligible for inference, which is right for
machines whose cards are identical. It is wrong the moment a display-only card
joins them: the budgets would key to the smallest card, the tensor split would
put weights on silicon the pinned build was never compiled for, and the idle
check would wait forever on the desktop's own GPU contexts.

Declare the pool in `etc/inference-gpus` — one GPU UUID per line, `#` comments
allowed, UUIDs from `nvidia-smi --query-gpu=uuid,name --format=csv`. The file
is machine-local and gitignored, like the generated `etc/llama-swap.yaml`: it
names this host's silicon and must never be committed.

With a declaration, every figure the scripts derive — counts, budgets, best-GPU
choice, tensor split, compute arch — is computed over pool members only;
`40-serve.sh` writes `CUDA_VISIBLE_DEVICES` with those UUIDs into the systemd
unit so the servers are confined to the same set the sizing assumed, and
single-model pins name a pool member's UUID rather than an index. UUIDs, not
indexes, because indexes follow PCI enumeration and a firmware update can
renumber the display card into the pool.

The declaration **fails closed**: an unknown UUID, a duplicate, or a file that
matches nothing refuses to proceed rather than silently widening the pool back
to "all cards". A machine whose GPUs differ in compute capability with *no*
declaration is refused the same way — one binary serves one capability, so the
operator must say which cards count. `00-specs.sh` still prints its report in
these states; sizing and generation stop.

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

The revision to build is **committed** as [`llamacpp.ref`](llamacpp.ref) — a full hash,
not a branch — so a fresh clone builds the revision this repo was verified against
rather than whatever `master` is that day. There is nothing to create by hand: bump the
pin deliberately, in a commit that says why. A one-off build of something else is
`LLAMA_REF=<rev> ./20-build-llamacpp.sh`, and the verifier will then report that the
installed binary no longer matches the pin. What actually got built is recorded in
`.llamacpp-rev`; if the pin file is ever removed, the build tracks `master` and says so
rather than letting the next run silently produce something different.

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
| `[runtime]` | Which `llama-swap` and `llama-server` binaries are installed, read off the binaries themselves. |

If no benchmark artifact exists it reports **"not measured"** rather than substituting a
figure from anywhere else, and a `--flash-attn` line in the config never on its own
establishes that flash attention is active.

```bash
./71-verify-runtime.sh --measure               # take a bounded measurement now
./71-verify-runtime.sh --require props         # exit non-zero unless established
./71-verify-runtime.sh --require swap-pin      # ... unless llama-swap matches its pin
./71-verify-runtime.sh --require llamacpp-pin  # ... unless llama-server matches llamacpp.ref
./71-verify-runtime.sh --require flash-attn --require props
```

`--require pin` is the older name from when there was only one pin; it stays as an alias
for `swap-pin`, so existing callers keep gating exactly what they always gated.

**Runtime drift.** The rig pins both runtime binaries — `lib/swap.sh` pins `llama-swap`,
and the committed [`llamacpp.ref`](llamacpp.ref) pins the llama.cpp revision behind
`llama-server` — and the `[runtime]` section verifies each against its pin, separately.
For a while the swap pin was enforced only by running the full
[`./40-serve.sh`](40-serve.sh) — the thing that also stops the service and replaces the
binary. That is the wrong tool when a measurement is in flight, and it is how this machine
ended up sitting two releases behind its own pin for three days without anything noticing.
The report compares installed version and pinned version, and — for the swap pin only —
where that pin came from (an `LLAMA_SWAP_VERSION` override or the repo default; the
llama.cpp pin has no origin to attribute, since it is always the committed
`llamacpp.ref`), plus the install record as a **separate** line, because matching the pin
says nothing about who put the binary there or whether its bytes were ever verified. It reads, and changes
nothing — on drift it names the command that reconciles it (`./40-serve.sh
--reconcile-swap`, since a serve run without the flag refuses on drift) rather than
running it.

The llama.cpp side keeps three sources of identity separate, because they make separate
claims: **installed** is what `llama-server --version` reports, **pinned** is what the
committed `llamacpp.ref` says it should be — always the committed file: `LLAMA_REF`
steers builds, never the verifier's comparison — and **record** is what llm-rig last built
(`.llamacpp-rev`) — provenance, not identity, so it never feeds the verdict. A binary
built elsewhere and copied over the install target would satisfy a record comparison
while being exactly the drift the pin exists to catch. On drift the reconciling command
is `./20-build-llamacpp.sh`, which rebuilds at the pin; the verifier never runs it.

Each pin assertion fails on drift, on a binary that will not report its identity, *and*
(for `llamacpp-pin`) on a missing pin file. Those are different problems — "rebuild it",
"find out what this is", "commit a pin" — and `swap_pin_drift` / `llama_pin_drift`
distinguish them by exit status for callers that need to.

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
