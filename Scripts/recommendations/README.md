# Tuning For You offline

The ranking (`MatineeKit/Recommendations/Recommender.swift`) is tuned against your own history, offline.
The scripts here use the app's own methods; the data they make stays in a scratch folder and never enters the repo.

1. In a scratch folder, export the history and subscriptions from the app's database, read-only:
   `sqlite3 -readonly -json "file:<db>?mode=ro" "SELECT video_id, title, channel_id, channel_name, watched_at, length_seconds, position FROM history ORDER BY watched_at DESC" > history.json`
   and `SELECT id FROM channel` into `subs.json`.
2. `python3 -I collect.py <Runtime.bundle> <site-packages> history.json related.json` fetches the related lists of
   the 400 most recent watches through the worker. This is the only step that uses the network.
3. Write `titles.tsv` (id, title) for every history and candidate title, then
   `swiftc -O vec.swift -o vec && ./vec` writes the on-device title vectors (`ids.tsv`, `vectors.f32`).
4. `evaluate.py` has the evaluation. At each cutoff, the ranking sees only the history before it and is scored on the
   next 7 days' watches from channels you aren't subscribed to (NDCG@50, recall@20). Cutoffs are split by time:
   - the oldest half tunes;
   - the next quarter validates;
   - the newest quarter is scored once at the end.

   A change counts only if it wins the paired bootstrap on the tuning cutoffs and on the validation cutoffs.

## Results on 2026-11-05 (1,522 watches, 97 daily cutoffs)

The baseline was recency 0.85, 1/(1+position), subscribed × 0.4, spreading 0.6 and title affinity 0.6.

| Change | Discovery NDCG@50, tune / val | Kept? |
|---|---|---|
| Baseline | 0.281 / 0.319 | |
| No title affinity | 0.186 / 0.220 | No: the model is the biggest single signal |
| Watched-not-subscribed channel boost × (1 + ln(1 + n)) and spreading 0.9 | 0.382 / 0.419 | **Yes** |
| Same, without spreading | 0.406 / 0.467 | No: the top 20 drops to about 13 channels |
| Profile from 50 or 100 watches; best 1 or 5 matches; popularity penalty; recency 0.7 or 1.0; 10 seeds | mixed | No: not reliable on both sets |
| Seeds weighted by how much was watched | 0.419 / 0.411 | No: wins on tune only (val P = 0.42) |

The held-out quarter had only 2 cutoffs with a discovery target, so its 0.19 → 0.49 is weak evidence.

## Local models, 2026-11-05 (the "Local AI ranking" setting)

Descriptions were fetched once for the 5,373 videos in the history and its related lists (serially, through a VPN),
cleaned with the worker's `clean_description` rules; 5,100 kept some text.

| Affinity model (weight) | Discovery NDCG@50, tune / val | P(better), tune / val |
|---|---|---|
| Apple NLContextualEmbedding, titles (1.0): the default | 0.289 / 0.333 | |
| Apple, descriptions or title + description | lower | No |
| bge-m3, title + description | below e5 | No |
| **multilingual-e5-large, title + description (1.5)** | **0.297 / 0.442** | **0.88 / 0.95** |

The judge was chosen by blind A/B tests of the top 20 on the live history (order randomised), since NDCG can't see
junk: JevK5-4B (option logits A/B, prompt in `JudgePrompt.swift`) over Qwen3-8B with a numeric score, the
Qwen3-Reranker-0.6B (let music in) and no judge. It re-sorts the top 40 by ln(1/(1+rank)) + z(logit). With the
profile's caches computed once and copied per candidate, 40 candidates took 7.8 s in Python (MLX).

`selftest_reference.py` makes `Matinee/Matinee/ModelSelfTest.json`, the reference `Matinee -modelselftest YES`
checks the Swift port against (synthetic profile; no viewing history).
