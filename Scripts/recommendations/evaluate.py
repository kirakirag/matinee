"""Offline evaluation of Matinee's For You ranking against the user's own history.

At a cutoff time T the ranking sees only what was watched before T: the 20 most recent videos before T are the seeds
(their related lists are the candidates, fetched 2026-11-05), and everything watched before T is excluded.
It's scored on what was watched in the next 7 days after T: recall@K is the share of those future watches found
among the top K, averaged over cutoffs. Only future watches that are candidates at all count (the ranking can't
find what nobody suggested), so the metric measures the ordering, not YouTube's coverage.

Cutoffs are split by time so the settings can't be fitted to the evaluation: the oldest half tunes, the next
quarter validates, the newest quarter is only scored once at the end.
"""
import array
import json
import math
import sys

HERE = sys.argv[1] if len(sys.argv) > 1 else '.'
history = json.load(open(f'{HERE}/history.json'))          # newest first
related = {k: v for k, v in json.load(open(f'{HERE}/related.json')).items() if v}
subs = {s['id'] for s in json.load(open(f'{HERE}/subs.json'))}
vec_raw = array.array('f')
vec_raw.frombytes(open(f'{HERE}/vectors.f32', 'rb').read())
DIM = 512
row_of, script_of = {}, {}
for line in open(f'{HERE}/ids.tsv'):
    vid, script, row = line.rstrip('\n').split('\t')
    row_of[vid], script_of[vid] = int(row), script

def completion(h):
    # Watched share; unknown counts as fully watched.
    if h.get('length_seconds') and h.get('position') is not None and h['length_seconds'] > 0:
        return max(0.0, min(1.0, h['position'] / h['length_seconds']))
    return 1.0


events = sorted(({'id': h['video_id'], 't': h['watched_at'], 'title': h['title'] or '', 'channel': h['channel_id'],
                  'completion': completion(h)} for h in history), key=lambda e: e['t'])   # oldest first
_completion = {}
for e in events:
    _completion[e['id']] = e['completion']   # the latest watch's
WEEK = 7 * 86400


def vector(vid):
    r = row_of.get(vid)
    return None if r is None else vec_raw[r * DIM:(r + 1) * DIM]


def cutoffs():
    """Every watch whose 20 predecessors all have related lists, and that has future watches among the candidates."""
    out = []
    for i in range(20, len(events)):
        before = events[:i]
        seeds = []
        for e in reversed(before):
            if e['id'] not in seeds:
                seeds.append(e['id'])
            if len(seeds) == 20:
                break
        if sum(1 for s in seeds if s in related) < 15:   # most of the seeds need their lists
            continue
        t = events[i]['t']
        watched = {e['id'] for e in before}
        future = {e['id'] for e in events[i:] if e['t'] < t + WEEK and e['id'] not in watched}
        candidates = {c['id'] for s in seeds for c in related.get(s, [])}
        targets = future & candidates
        if targets:
            out.append({'t': t, 'seeds': seeds, 'watched': watched, 'targets': targets,
                        'history': [e for e in reversed(before)][:100]})
    # Thin to one cutoff per day, so a binge doesn't weigh 30 times.
    thinned, last_day = [], None
    for c in out:
        day = int(c['t'] // 86400)
        if day != last_day:
            thinned.append(c)
            last_day = day
    return thinned


def affinity(hist_ids, cand_ids, top=3):
    """TitleSimilarity's z-scores: centred on the candidates' mean, per script, mean of the best `top` cosines."""
    sims = {}
    by_script = {}
    for c in cand_ids:
        if c in row_of:
            by_script.setdefault(script_of[c], []).append(c)
    for script, cs in by_script.items():
        past = [h for h in hist_ids if script_of.get(h) == script]
        if not past:
            continue
        mean = [0.0] * DIM
        for c in cs:
            v = vector(c)
            for i in range(DIM):
                mean[i] += v[i]
        mean = [m / len(cs) for m in mean]

        def unit(vid):
            v = vector(vid)
            d = [v[i] - mean[i] for i in range(DIM)]
            n = math.sqrt(sum(x * x for x in d)) or 1.0
            return [x / n for x in d]
        pu = [unit(h) for h in past]
        for c in cs:
            u = unit(c)
            best = sorted((sum(a * b for a, b in zip(p, u)) for p in pu), reverse=True)[:top]
            sims[c] = sum(best) / len(best)
    if len(sims) < 2:
        return {k: 0.0 for k in sims}
    m = sum(sims.values()) / len(sims)
    sd = math.sqrt(sum((x - m) ** 2 for x in sims.values()) / len(sims)) or 1.0
    return {k: (x - m) / sd for k, x in sims.items()}


def rank(cut, p, aff):
    score, entry, order = {}, {}, []
    for i, s in enumerate(cut['seeds'][:p['seeds']]):
        w = p['recency'] ** i * (max(_completion.get(s, 1.0), 0.05) ** p.get('completion', 0))
        for pos, c in enumerate(related.get(s, [])):
            cid = c['id']
            if cid in cut['watched']:
                continue
            if cid not in entry:
                entry[cid] = c
                order.append(cid)
            score[cid] = score.get(cid, 0.0) + w / (1 + pos) ** p['position']
    seen_channels = {}
    for e in cut['history'][:p.get('channel_window', 100)]:
        if e['channel']:
            seen_channels[e['channel']] = seen_channels.get(e['channel'], 0) + 1
    for cid, c in entry.items():
        if c.get('channel_id') in subs:
            score[cid] *= p['subscribed']
        elif p.get('channel_boost'):
            score[cid] *= 1 + p['channel_boost'] * math.log1p(seen_channels.get(c.get('channel_id'), 0))
        if p.get('popularity') and c.get('views'):
            score[cid] *= (1 + math.log10(1 + c['views'])) ** -p['popularity']
        if aff and cid in aff:
            score[cid] *= math.exp(p['affinity'] * aff[cid])
    remaining, out = order[:], []
    while remaining and len(out) < 100:
        best = max(remaining, key=lambda k: score[k])
        remaining.remove(best)
        out.append(best)
        ch = entry[best].get('channel_id')
        if ch:
            for k in remaining:
                if entry[k].get('channel_id') == ch:
                    score[k] *= p['repeat']
    return out


def recall(cuts, p, affs, k=20):
    total = 0.0
    for c, aff in zip(cuts, affs):
        top = rank(c, p, aff if p['affinity'] else None)[:k]
        total += len(set(top) & c['targets']) / len(c['targets'])
    return total / len(cuts)


_channel = {e['id']: e['channel'] for e in events}


def discovery_targets(cut):
    """Future watches from channels the user isn't subscribed to: what For You is for (the feed has the rest)."""
    return {t for t in cut['targets'] if _channel.get(t) not in subs}


def per_cut(cuts, p, affs, metric='ndcg', discovery=True, k=50):
    """One score per cutoff (for paired comparisons). Cutoffs without a discovery target are skipped (None)."""
    out = []
    for c, aff in zip(cuts, affs):
        targets = discovery_targets(c) if discovery else c['targets']
        if not targets:
            out.append(None)
            continue
        ranked = rank(c, p, aff if p['affinity'] else None)[:k]
        if metric == 'recall':
            out.append(len(set(ranked) & targets) / len(targets))
        else:
            dcg = sum(1 / math.log2(i + 2) for i, v in enumerate(ranked) if v in targets)
            ideal = sum(1 / math.log2(i + 2) for i in range(min(len(targets), k)))
            out.append(dcg / ideal)
    return out


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else float('nan')


def paired_better(a, b, rounds=2000, seed=7):
    """Share of bootstrap resamples (over cutoffs) in which `a` beats `b` on average: ~1 is a reliable gain."""
    import random
    rnd = random.Random(seed)
    pairs = [(x, y) for x, y in zip(a, b) if x is not None and y is not None]
    if not pairs:
        return float('nan')
    wins = 0
    for _ in range(rounds):
        s = [pairs[rnd.randrange(len(pairs))] for _ in pairs]
        wins += sum(x - y for x, y in s) > 0
    return wins / rounds
