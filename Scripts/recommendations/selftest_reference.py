# Reference values for Matinee's --model-self-test: e5 vectors (sentence-transformers) and JevK5 verdicts (mlx-lm,
# the blind test's prompt code). Synthetic profile and candidates: no viewing history.
import json, sys, random, time
out_path = sys.argv[1]
random.seed(7)
topics = [("Lecture {n}: attention and transformers", "Stanford Online"), ("Building a DIY radio telescope, part {n}", "Maker Lab"),
          ("Pilot explains engine failure #{n}", "Aviation Talk"), ("Speedrun history of a classic platformer ({n})", "Game Archive"),
          ("Jazz piano voicings lesson {n}", "Keys Daily"), ("Kernel exploit walkthrough {n}", "Sec Notes"),
          ("Formula 1 race analysis: round {n}", "Pit Wall"), ("Cooking ramen from scratch, day {n}", "Noodle Lab"),
          ("Theme park ride that closed forever ({n})", "Park Stories"), ("Interview with an ML researcher #{n}", "Podcast Hour")]
subs = ["Stanford Online", "Maker Lab", "Aviation Talk", "Keys Daily", "Sec Notes", "Ünïcode Kanal 日本"]
recent = []
for i in range(50):
    t, c = random.choice(topics)
    recent.append({"title": t.format(n=i + 1), "channel": c, "watched": random.choice([None, 0.05, 0.5, 0.95])})
dismissed = ["Late night host roasts the senators", "Celebrity reacts to \"viral\" clips"]
cand_topics = topics + [("Top 10 celebrity moments {n}", "Clip Zone"), ("Election night recap {n}", "News 24"),
                        ("Relaxing lofi beats {n}", "Lofi Radio"), ("Tank battle compilation {n}", "War Clips")]
cands = []
for i in range(40):
    t, c = random.choice(cand_topics)
    cands.append({"id": f"c{i:02d}", "title": t.format(n=100 + i), "channel": c, "seconds": random.choice([None, 45, 754, 5354])})

def watched(f): return '' if f is None else ('finished' if f > 0.85 else ('left early' if f < 0.2 else 'partly'))
profile = ("Channels they subscribe to: " + ", ".join(subs) + "\n\nRecently watched, newest first:\n"
           + "\n".join(f"- {h['title']} — {h['channel']}" + (f" ({watched(h['watched'])})" if watched(h['watched']) else '') for h in recent)
           + ("\n\nThey said they're not interested in:\n" + "\n".join("- " + d for d in dismissed) if dismissed else ''))
def length(s): return '' if not s else (f"{s // 3600} h {s % 3600 // 60} min" if s >= 3600 else f"{max(1, s // 60)} min")
def cand(r): return f"{r['title']} — {r['channel']}" + (f" ({length(r.get('seconds'))})" if r.get('seconds') else '')
question = ("Would this viewer want to watch this YouTube video? Judge by their actual interests and channels, "
            "not popularity; videos they left early count less.")
def jevk5_prompt(r):
    payload = {"evidence": profile, "criterion": f"{question} The video: {cand(r)}",
               "options": [{"letter": "A", "description": "true: Yes, they would want to watch it."},
                           {"letter": "B", "description": "false: No, they would not want to watch it."}]}
    system = ("Apply the supplied criterion to the supplied evidence. Choose exactly one listed option. "
              "Respond with only its uppercase letter, with no explanation or reasoning.")
    return (f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{json.dumps(payload, ensure_ascii=False)}<|im_end|>\n"
            "<|im_start|>assistant\n<think>\n\n</think>\n\n")

texts = ["passage: Stanford CS336 Language Modeling from Scratch. A lecture on tokenization.",
         "passage: Celebrity goes completely unfiltered for 8 minutes",
         "passage: 日本の鉄道の旅. 東京から大阪まで新幹線で。"]
from sentence_transformers import SentenceTransformer
e5 = SentenceTransformer('intfloat/multilingual-e5-large', device='cpu')
vectors = e5.encode(texts, normalize_embeddings=True).tolist()
del e5

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache
model, tok = load('alibiserikbay/JevK5', model_config={'model_type': 'qwen3_5'})
A, B = tok.convert_tokens_to_ids('A'), tok.convert_tokens_to_ids('B')
logits, tokens = {}, {}
t0 = time.time()
for r in cands:
    full = tok.encode(jevk5_prompt(r), add_special_tokens=False)
    tokens[r['id']] = len(full)
    lg = model(mx.array(full)[None], cache=make_prompt_cache(model))[0, -1].astype(mx.float32)
    logits[r['id']] = round((lg[A] - lg[B]).item(), 4)
first = tok.encode(jevk5_prompt(cands[0]), add_special_tokens=False)
json.dump({"source": "Scripts/recommendations/selftest_reference.py: sentence-transformers e5, mlx-lm 0.32.2 JevK5 full prompts",
           "e5": [{"text": t, "vector": [round(x, 6) for x in v]} for t, v in zip(texts, vectors)],
           "subscriptions": subs, "recent": recent, "dismissed": dismissed, "profile": profile,
           "candidates": [dict(r, logit=logits[r['id']]) for r in cands],
           "first_prompt_tokens": first},
          open(out_path, 'w'), ensure_ascii=False)
print('done', time.time() - t0, 's; logits range', min(logits.values()), max(logits.values()), 'tokens', min(tokens.values()), max(tokens.values()))
