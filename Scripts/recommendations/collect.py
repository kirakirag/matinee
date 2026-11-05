import sys, json, time
from concurrent.futures import ThreadPoolExecutor
sys.path[:0] = [sys.argv[1], sys.argv[2]]
import matinee_worker as w
out = sys.argv[4]
hist = json.load(open(sys.argv[3]))
ids = []
for h in hist:
    if h['video_id'] not in ids: ids.append(h['video_id'])
ids = ids[:400]
def get(v):
    for attempt in range(2):
        try: return v, w.related_op({'id': v})['videos']
        except Exception as e: err = str(e)[:80]; time.sleep(1)
    return v, None
t = time.time()
with ThreadPoolExecutor(4) as pool:
    res = dict(pool.map(get, ids))
json.dump(res, open(out, 'w'))
print('related', sum(1 for v in res.values() if v is not None), 'of', len(ids), 'in', round(time.time() - t), 's')
