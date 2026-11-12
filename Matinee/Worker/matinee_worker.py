"""Matinee's long-lived yt-dlp worker: JSON lines in on stdin, JSON lines out on stdout.

Request:  {"rid": int, "op": "resolve", "id": str, "clients": [str] | absent, "max_height": int (144…4320) | absent}
          {"rid": int, "op": "warm"}  (runs `deno --version`; replies {"rid", "ok", "error"})
          {"rid": int, "op": "list", "url": str, "n": int}  (flat listing; url must match LIST_URL_RE)
          {"rid": int, "op": "more", "cursor": int, "n": int}  (next page of a list or comments cursor)
          {"rid": int, "op": "download", "id": str, "dir": str (absolute, existing), "max_height": int (144…4320) | absent}
          {"rid": int, "op": "comments", "id": str, "n": int (1…100) | absent}  (first page of top-level comments,
           top first; replies {"comments": [{"id", "text", "author", "author_id", "likes", "time", "is_uploader",
           "hearted", "reply_count", "has_replies"}], "count": int|null, "cursor", "done"}; `more` with the cursor
           replies {"comments", "done"})
          {"rid": int, "op": "replies", "cursor": int, "id": str, "n": int (1…100) | absent}  (a comment's next
           replies, from its comments cursor; replies {"replies": [comment], "done"})
          {"rid": int, "op": "playlists", "id": str}  (the video channel's playlists its watch page recommends)
          {"rid": int, "op": "related", "id": str}  (the videos the watch page suggests next; replies {"videos": [entry]},
           entries as `list`'s)
          {"rid": int, "op": "descriptions", "ids": [str] (at most 60)}  (cleaned descriptions, one watch page a second;
           replies {"descriptions": {id: str}, "stopped": bool}; stopped means YouTube throttled: don't ask again)
          {"rid": int, "op": "cancel", "target": int}  (the download with that rid fails with "cancelled")
          list replies {"cursor", "title", "channel_id", "channel", "entries", "done"}, more {"entries", "done"},
          playlists {"playlists": [{"id", "title"}]} (candidates: the app verifies membership)
          download sends {"rid", "event": "progress", "downloaded": int, "total": int|null} lines (at most every
          0.5 s) before its reply {"file", "bytes", "title", "channel", "channel_id", "duration", "subtitles"}
          (subtitles as resolve's; the app saves them next to the file)
Response: {"rid", "ok", "error", "video_url", "audio_url", "height", "vcodec", "acodec",
           "expire", "headers", "available_at", "qualities", "jsc", "ms",
           "subtitles": [{"lang", "name", "url" (json3), "auto": bool}],
           "audio_tracks": [{"lang", "name", "url", "original": bool}] (empty unless there are several languages)}
Prints {"ready": true} once at start. Requests run concurrently (up to MAX_PARALLEL); replies come in
completion order, matched by rid.
Run with `python3 -I`. The Deno binary's path comes from MATINEE_DENO.
"""
import collections
import glob
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs, urlparse

import yt_dlp
import yt_dlp.globals
import yt_dlp.utils

ID_RE = re.compile(r'\A[A-Za-z0-9_-]{11}\Z')   # \Z: `$` would also accept a trailing newline
# yt-dlp tags every log line of its Deno JS-challenge provider with this (seen in a -v run of
# yt-dlp 2026.10.21: "[youtube] [jsc:deno] Solving JS challenges using deno").
JSC_DENO_MARKER = '[jsc:deno]'
# MATINEE_WORKER_DEBUG=1 copies yt-dlp's verbose log to stderr (diagnostics only).
DEBUG = os.environ.get('MATINEE_WORKER_DEBUG') == '1'

yt_dlp.globals.plugin_dirs.value = []   # never load plugins from disk


class RequestLog:
    """yt-dlp logger that remembers whether the Deno provider ran during the current request."""

    def __init__(self):
        self.jsc = None

    def _see(self, msg):
        if JSC_DENO_MARKER in msg:
            self.jsc = 'deno'

    def debug(self, msg):
        self._see(msg)
        if DEBUG:
            print(msg, file=sys.stderr, flush=True)

    def info(self, msg):
        self._see(msg)
        if DEBUG:
            print(msg, file=sys.stderr, flush=True)

    def warning(self, msg):
        self._see(msg)
        print(msg, file=sys.stderr, flush=True)

    def error(self, msg):
        print(msg, file=sys.stderr, flush=True)


def options(log, clients, max_height=None):
    opts = {
        'quiet': True,
        'no_warnings': False,
        'verbose': True,          # the jsc marker is logged at debug level
        'skip_download': True,
        'noplaylist': True,
        'format': 'bv*+ba/b',
        'format_sort': ([f'res:{max_height}'] if max_height else []) + ['vcodec:vp9'],
        'js_runtimes': {'deno': {'path': os.environ['MATINEE_DENO']}} if os.environ.get('MATINEE_DENO') else {'deno': {}},
        'logger': log,
    }
    if clients:
        opts['extractor_args'] = {'youtube': {'player_client': list(clients)}}
    return opts


def expire_of(url):
    try:
        return int(parse_qs(urlparse(url).query).get('expire', ['0'])[0])
    except ValueError:
        return 0


def resolve(req):
    vid = req.get('id')
    clients = req.get('clients')
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise ValueError('invalid video id')
    if clients is not None and not (isinstance(clients, list) and all(isinstance(c, str) for c in clients)):
        raise ValueError('invalid clients')
    max_height = valid_max_height(req)
    log = RequestLog()
    with yt_dlp.YoutubeDL(options(log, clients, max_height)) as ydl:
        info = ydl.extract_info(f'https://www.youtube.com/watch?v={vid}', download=False)
    fmts = info.get('requested_formats') or [info]
    video = next((f for f in fmts if f.get('vcodec') not in (None, 'none')), fmts[0])
    audio = next((f for f in fmts if f.get('vcodec') in (None, 'none')), None)
    return {
        'video_url': video['url'],
        'audio_url': audio['url'] if audio else None,
        'height': video.get('height') or 0,
        'vcodec': video.get('vcodec'),
        'acodec': (audio or video).get('acodec'),
        'expire': expire_of(video['url']),
        'headers': video.get('http_headers') or {},
        'available_at': max((f.get('available_at') or 0) for f in fmts),
        'qualities': sorted({f['height'] for f in info.get('formats') or []
                             if f.get('vcodec') not in (None, 'none') and f.get('height')
                             and str(f.get('url', '')).startswith('https://')}, reverse=True),
        'jsc': log.jsc,
        'title': info.get('title'),
        'channel': info.get('channel'),
        'channel_id': info.get('channel_id'),
        'duration': info.get('duration'),
        'subtitles': subtitles_of(info),
        'audio_tracks': audio_tracks_of(info, audio),
    }


MAX_TRACKS = 200
ORIGINAL_SUFFIX = '-orig'


def subtitles_of(info):
    """The video's caption tracks as json3 URLs: the uploaded ones, then the auto-generated one in the spoken
    language. YouTube's machine translations of those (some 150 languages each) are left out."""
    def track(lang, formats, auto):
        if not isinstance(lang, str) or not isinstance(formats, list):
            return None
        f = next((f for f in formats if isinstance(f, dict) and f.get('ext') == 'json3'
                  and str(f.get('url', '')).startswith('https://')), None)
        if not f:
            return None
        name = f.get('name') if isinstance(f.get('name'), str) else ''
        if name.endswith(' (Original)'):
            name = name[:-len(' (Original)')]
        return {'lang': lang, 'name': name or lang, 'url': f['url'], 'auto': auto}

    out = [track(lang, fs, False) for lang, fs in (info.get('subtitles') or {}).items() if lang != 'live_chat']
    auto = info.get('automatic_captions') or {}
    spoken = [k for k in auto if isinstance(k, str) and k.endswith(ORIGINAL_SUFFIX)]
    if spoken:
        out += [track(k[:-len(ORIGINAL_SUFFIX)], auto[k], True) for k in spoken]
    elif len(auto) <= 3:   # a client without the translation list reports only what was generated
        out += [track(k, fs, True) for k, fs in auto.items()]
    return [t for t in out if t][:MAX_TRACKS]


def audio_tracks_of(info, chosen):
    """One stream per audio language (dubs, described audio) when the video has more than one, the original first;
    each is the same kind of stream as the chosen one where the language has it, else its best."""
    by_lang = {}
    for f in info.get('formats') or []:
        if (f.get('vcodec') not in (None, 'none') or f.get('acodec') in (None, 'none') or not f.get('language')
                or f.get('protocol') != 'https' or not str(f.get('url', '')).startswith('https://')):
            continue
        by_lang.setdefault(f['language'], []).append(f)
    if len(by_lang) < 2:
        return []
    kind = str((chosen or {}).get('format_id', '')).split('-')[0]
    out = []
    for lang, fs in by_lang.items():
        f = max(fs, key=lambda f: (str(f.get('format_id', '')).split('-')[0] == kind, f.get('abr') or f.get('tbr') or 0))
        # "English (US) original (default), medium": the track's name, then the stream's quality
        name = str(f.get('format_note') or '').split(',')[0].replace(' (default)', '').strip()
        out.append({'lang': lang, 'name': name or lang, 'url': f['url'],
                    'original': (f.get('language_preference') or -1) >= 5})
    out.sort(key=lambda t: (not t['original'], t['name'].lower()))
    return out[:MAX_TRACKS]


LIST_URL_RE = re.compile(
    r'https://www\.youtube\.com/(results\?search_query=[^&#\s\x00-\x1f\x7f]+(&sp=[A-Za-z0-9%_-]+)?'
    r'|playlist\?list=[A-Za-z0-9_-]{12,64}'
    r'|channel/UC[A-Za-z0-9_-]{22}/playlists'
    r'|@[A-Za-z0-9._-]{3,30}/playlists)')
CHANNEL_ID_RE = re.compile(r'UC[A-Za-z0-9_-]{22}')
HIDDEN_TITLES = ('[Private video]', '[Deleted video]')
MAX_CURSORS = 8
# cursor -> (YoutubeDL, items iterator, lock, reply key, comment id -> its replies iterator or None);
# order = last use, oldest first
CURSORS = {}
CURSORS_LOCK = threading.Lock()
MAX_PARALLEL = 4
# Random start, so a cursor from a killed worker never matches one in its replacement.
_next_cursor = int.from_bytes(os.urandom(4), 'big') >> 1
MAX_REDIRECTS = 3


def url_allowed(url):
    return isinstance(url, str) and LIST_URL_RE.fullmatch(url) is not None


def entry_of(raw):
    """One yt-dlp flat entry as the app's listing entry, or None to skip it."""
    eid = raw.get('id')
    if not isinstance(eid, str):
        return None
    url = raw.get('url') or ''
    if ID_RE.match(eid):
        kind = 'video'
    elif CHANNEL_ID_RE.fullmatch(eid):
        kind = 'channel'
    elif 'list=' in url or raw.get('ie_key') == 'YoutubeTab':
        kind = 'playlist'
    else:
        return None
    title = raw.get('title')
    if title in HIDDEN_TITLES:
        return None
    thumbs = [t.get('url') for t in raw.get('thumbnails') or [] if isinstance(t, dict)]
    return {
        'kind': kind,
        'id': eid,
        'title': title or '',
        'channel': raw.get('channel') or raw.get('uploader'),
        'channel_id': raw.get('channel_id'),
        'duration': raw.get('duration'),
        'views': raw.get('view_count'),
        'thumbnail': next((u for u in reversed(thumbs) if isinstance(u, str) and u.startswith('https://')), None),
        'count': raw.get('playlist_count'),
    }


def clamp_n(req):
    n = req.get('n')
    return min(max(n, 1), 200) if isinstance(n, int) else 20


def page(items, n):
    """Up to n items from the lazy iterator, and whether it is exhausted."""
    out = []
    for item in items:
        out.append(item)
        if len(out) >= n:
            return out, False
    return out, True


def add_cursor(ydl, items, key, threads=None):
    """Keeps a listing open for `more`, which replies with its next items under `key`, and for `replies`."""
    global _next_cursor
    with CURSORS_LOCK:
        cursor = _next_cursor
        _next_cursor += 1
        CURSORS[cursor] = (ydl, items, threading.Lock(), key, threads)
        while len(CURSORS) > MAX_CURSORS:
            CURSORS.pop(next(iter(CURSORS)))[0].close()
    return cursor


def list_op(req):
    url = req.get('url')
    if not url_allowed(url):
        raise ValueError('url not allowed')
    n = clamp_n(req)
    opts = options(RequestLog(), None)
    for key in ('format', 'noplaylist'):
        del opts[key]
    opts['extract_flat'] = 'in_playlist'
    if url.startswith('https://www.youtube.com/results?'):
        # Search works from the API alone; the home page fetched for ytcfg costs ~150 ms per search.
        opts['extractor_args'] = {'youtubetab': {'skip': ['webpage']}}
    ydl = yt_dlp.YoutubeDL(opts)
    try:
        info = ydl.extract_info(url, download=False, process=False)
        for _ in range(MAX_REDIRECTS):
            if info.get('_type') not in ('url', 'url_transparent'):
                break
            if not url_allowed(info.get('url')):
                raise ValueError('url not allowed')
            info = ydl.extract_info(info['url'], ie_key=info.get('ie_key'), download=False, process=False)
        if info.get('entries') is None:
            raise ValueError('not a listing')
        entries = (e for e in map(entry_of, info.get('entries') or ()) if e)
        out, done = page(entries, n)
    except BaseException:
        ydl.close()
        raise
    result = {
        'title': info.get('title'),
        'channel_id': info.get('channel_id'),
        'channel': info.get('channel') or info.get('uploader'),
        'entries': out,
        'done': done,
        'cursor': None,
    }
    if done:
        ydl.close()
        return result
    result['cursor'] = add_cursor(ydl, entries, 'entries')
    return result


def held_cursor(cursor):
    with CURSORS_LOCK:
        if cursor not in CURSORS:
            raise ValueError('cursor expired')
        held = CURSORS.pop(cursor)
        CURSORS[cursor] = held   # most recently used goes last
    return held


def more_op(req):
    cursor = req.get('cursor')
    held = held_cursor(cursor)
    ydl, items, lock, key, threads = held
    with lock:   # one page at a time per listing: its iterator can't be shared
        try:
            out, done = page(items, clamp_n(req))
        except BaseException:
            drop_cursor(cursor, held)
            raise
        if done and not threads:   # comments stay open while they have replies to fetch
            drop_cursor(cursor, held)
    return {key: out, 'done': done}


def drop_cursor(cursor, held):
    with CURSORS_LOCK:
        if CURSORS.get(cursor) is held:
            del CURSORS[cursor]
    held[0].close()


PROGRESS_INTERVAL = 0.5
CANCELLED = set()   # rids of downloads asked to stop
CANCELLED_LOCK = threading.Lock()
PARTIAL_RE = re.compile(r'\.f\d+\.[^/]+$')


def valid_max_height(req):
    max_height = req.get('max_height')
    if max_height is not None and not (type(max_height) is int and 144 <= max_height <= 4320):
        raise ValueError('invalid max_height')
    return max_height


def is_cancelled(rid):
    with CANCELLED_LOCK:
        return rid in CANCELLED


def remove_partials(directory, vid):
    """Deletes a failed download's leftovers: .part/.ytdl files and unmerged per-format files (<id>.f137.mp4)."""
    for path in glob.glob(os.path.join(glob.escape(directory), glob.escape(vid) + '.*')):
        name = os.path.basename(path)
        if name.endswith(('.part', '.ytdl')) or PARTIAL_RE.search(name[len(vid):]):
            try:
                os.remove(path)
            except OSError:
                pass


class Progress:
    """One download's progress across the files yt-dlp downloads one after the other (video, then audio).

    The total counts a started file with its own size, exact once yt-dlp knows it, and a file not started yet with
    the size yt-dlp planned, or its bitrate × the duration; when a size can't be known the total is unknown, never
    guessed. The fraction never goes back (an estimate can grow). Speed is the bytes of the last few seconds, so it
    follows the connection rather than the download's average; time left is what remains of the total at that speed.
    """
    SPEED_WINDOW = 5.0

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.planned = {}   # format id -> planned bytes, or None when unknown
        self.files = {}     # format id -> (bytes downloaded, its total or None)
        self.samples = collections.deque()   # (time, bytes downloaded), the last SPEED_WINDOW seconds
        self.fraction = 0.0
        self.last = None

    def plan(self, formats, duration):
        for f in formats:
            if isinstance(f, dict):
                self.planned[f.get('format_id')] = self.size_of(f, duration)

    @staticmethod
    def size_of(f, duration):
        size = f.get('filesize') or f.get('filesize_approx')
        if not size and f.get('tbr') and duration:
            size = f['tbr'] * 1000 / 8 * duration   # tbr is in kbit/s
        return int(size) if size else None

    def update(self, d):
        key = dig(d, 'info_dict', 'format_id') or d.get('filename')
        self.files[key] = (d.get('downloaded_bytes') or 0, d.get('total_bytes') or d.get('total_bytes_estimate'))
        done = sum(n for n, _ in self.files.values())
        sizes = [self.files[k][1] if k in self.files and self.files[k][1] else self.planned.get(k)
                 for k in set(self.planned) | set(self.files)]
        total = int(sum(sizes)) if all(sizes) else None
        now = self.clock()
        self.samples.append((now, done))
        while len(self.samples) > 2 and now - self.samples[1][0] >= self.SPEED_WINDOW:
            self.samples.popleft()
        then, before = self.samples[0]
        speed = (done - before) / (now - then) if now - then >= 0.5 else None
        if total:
            self.fraction = max(self.fraction, min(done / total, 1.0))
        eta = max(total - done, 0) / speed if total and speed else None
        self.last = {'downloaded': done, 'total': total, 'fraction': self.fraction if total else None,
                     'speed': speed, 'eta': eta, 'stage': 'downloading'}
        return self.last

    def finishing(self):
        """Merging the files: everything is downloaded."""
        done = sum(n for n, _ in self.files.values())
        total = (self.last or {}).get('total') or done
        return {'downloaded': done, 'total': total, 'fraction': 1.0, 'speed': None, 'eta': None, 'stage': 'finishing'}


FINISHING_INTERVAL = 10   # seconds between "finishing" lines while files merge; each restarts the app's timeout


def PlanSizes(progress):
    """A postprocessor that runs before the download with the formats yt-dlp chose, which the progress hook doesn't
    get."""
    from yt_dlp.postprocessor import PostProcessor

    class Plan(PostProcessor):
        def run(self, info):
            progress.plan(info.get('requested_formats') or [info], info.get('duration'))
            return [], info
    return Plan()


def download_op(req, emit):
    rid = req.get('rid')
    vid = req.get('id')
    directory = req.get('dir')
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise ValueError('invalid video id')
    if not isinstance(directory, str) or not os.path.isabs(directory) or not os.path.isdir(directory):
        raise ValueError('invalid dir')
    max_height = valid_max_height(req)
    progress = Progress()
    last = [0.0]
    stop = threading.Event()   # ends the "finishing" lines
    merging = threading.Event()

    def hook(d):
        if is_cancelled(rid):
            raise yt_dlp.utils.DownloadCancelled('cancelled')
        if d.get('status') != 'downloading':
            return
        p = progress.update(d)
        now = time.monotonic()
        # Throttled, but a file's last chunk always gets through so the bar reaches its end.
        file_total = d.get('total_bytes') or d.get('total_bytes_estimate')
        if now - last[0] >= PROGRESS_INTERVAL or (file_total and (d.get('downloaded_bytes') or 0) >= file_total):
            last[0] = now
            emit({'event': 'progress', **p})

    def postprocessing(d):
        # Merging starts once something downloaded (the planning postprocessor runs before that and is no merge).
        if d.get('status') != 'started' or not progress.files or stop.is_set() or merging.is_set():
            return
        merging.set()
        emit({'event': 'progress', **progress.finishing()})

        def beat():
            while not stop.wait(FINISHING_INTERVAL):
                emit({'event': 'progress', **progress.finishing()})
        threading.Thread(target=beat, daemon=True).start()

    opts = options(RequestLog(), None, max_height)
    del opts['skip_download']
    opts['format_sort'] = [f'res:{max_height}' if max_height else 'res', 'vcodec:vp9']   # best first, 4K included
    opts['outtmpl'] = os.path.join(directory.replace('%', '%%'), vid + '.%(ext)s')   # the dir is not a template
    opts['merge_output_format'] = 'mp4'
    opts['progress_hooks'] = [hook]
    opts['postprocessor_hooks'] = [postprocessing]
    if os.environ.get('MATINEE_FFMPEG'):
        opts['ffmpeg_location'] = os.environ['MATINEE_FFMPEG']
    try:
        if is_cancelled(rid):
            raise yt_dlp.utils.DownloadCancelled('cancelled')
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.add_post_processor(PlanSizes(progress), when='before_dl')
            info = ydl.extract_info(f'https://www.youtube.com/watch?v={vid}', download=True)
    except BaseException as e:
        remove_partials(directory, vid)
        if is_cancelled(rid):
            raise ValueError('cancelled') from e
        raise
    finally:
        stop.set()
        with CANCELLED_LOCK:
            CANCELLED.discard(rid)
    file = os.path.join(directory, vid + '.mp4')
    return {
        'file': file,
        'bytes': os.path.getsize(file),
        'title': info.get('title'),
        'channel': info.get('channel'),
        'channel_id': info.get('channel_id'),
        'duration': info.get('duration'),
        'subtitles': subtitles_of(info),
    }


def cancel_op(req):
    target = req.get('target')
    if type(target) is not int:
        raise ValueError('invalid target')
    with CANCELLED_LOCK:
        CANCELLED.add(target)
    return {}


MAX_COMMENTS = 100
MAX_COMMENT_CHARS = 5000


def count_of(text):
    """YouTube's short counts ("670", "1,024", "1.2K", "3M") as a number."""
    m = re.fullmatch(r'(\d+(?:\.\d+)?)([KM]?)', text.replace(',', '').strip()) if isinstance(text, str) else None
    return int(float(m[1]) * {'': 1, 'K': 1000, 'M': 1000000}[m[2]]) if m else None


def comment_of(c):
    """One of yt-dlp's comments as the app shows it, text capped; None when malformed."""
    if not isinstance(c, dict):
        return None
    cid, text = c.get('id'), c.get('text')
    if not isinstance(cid, str) or not isinstance(text, str):
        return None
    author_id = c.get('author_id')
    likes, replies = c.get('like_count'), c.get('reply_count')
    return {
        'id': cid,
        'text': text[:MAX_COMMENT_CHARS],
        'author': c.get('author') if isinstance(c.get('author'), str) else '',
        'author_id': author_id if isinstance(author_id, str) and CHANNEL_ID_RE.fullmatch(author_id) else None,
        'likes': likes if type(likes) is int else None,
        'time': c.get('_time_text') if isinstance(c.get('_time_text'), str) else None,
        'is_uploader': c.get('author_is_uploader') is True,
        'hearted': c.get('is_favorited') is True,
        'reply_count': replies if type(replies) is int else None,
        'has_replies': False,
    }


def hook_comments(ie, threads):
    """Wraps yt-dlp's comment extraction: each comment gets its reply count, and each top-level comment's replies
    (a lazy generator yt-dlp makes and, with max replies 0, never starts) go into `threads`, fetched only on request."""
    extract, entries = ie._extract_comment, ie._comment_entries

    def extract_comment(entities, parent=None):
        c = extract(entities, parent)
        if isinstance(c, dict):
            c['reply_count'] = next((n for n in (count_of(dig(e, 'payload', 'commentEntityPayload', 'toolbar', 'replyCount'))
                                                 for e in entities or ()) if n), None)
        return c

    def comment_entries(root, ytcfg, video_id, parent=None, tracker=None, depth=1):
        gen = entries(root, ytcfg, video_id, parent=parent, tracker=tracker, depth=depth)
        if parent is not None and depth == 2:
            threads[parent] = gen
        return gen

    ie._extract_comment, ie._comment_entries = extract_comment, comment_entries


def top_level_comments(raw, disabled, threads):
    """yt-dlp's top-level comments, each yielded once yt-dlp has moved past it: only then has it set up the
    comment's replies."""
    held = None
    try:
        for c in raw:
            if isinstance(c, dict) and c.get('parent') == 'root' and (c := comment_of(c)):
                if held:
                    yield dict(held, has_replies=held['id'] in threads)
                held = c
    except disabled:   # switched off by the uploader: no comments
        pass
    if held:
        yield dict(held, has_replies=held['id'] in threads)


WATCH_PAGES = {}   # video id -> (monotonic time, watch page HTML), oldest first
WATCH_PAGES_LOCK = threading.Lock()
MAX_WATCH_PAGES = 4
WATCH_PAGE_TTL = 600


def watch_page(ie, vid):
    """The video's watch page. `playlists` (at open) and `comments` (at the first frame) share one download."""
    now = time.monotonic()
    with WATCH_PAGES_LOCK:
        cached = WATCH_PAGES.get(vid)
    if cached and now - cached[0] < WATCH_PAGE_TTL:
        return cached[1]
    webpage = ie._download_webpage(f'https://www.youtube.com/watch?v={vid}', vid)
    with WATCH_PAGES_LOCK:
        WATCH_PAGES.pop(vid, None)
        WATCH_PAGES[vid] = (now, webpage)
        while len(WATCH_PAGES) > MAX_WATCH_PAGES:
            WATCH_PAGES.pop(next(iter(WATCH_PAGES)))
    return webpage


def comment_count(ie, data):
    """The total yt-dlp reads from the same places (it includes replies)."""
    for section in items(data, 'contents', 'twoColumnWatchNextResults', 'results', 'results', 'contents'):
        for c in items(section, 'itemSectionRenderer', 'contents'):
            n = dig(c, 'commentsEntryPointHeaderRenderer', 'commentCount')
            if n is not None:
                return ie._get_count(n)
    for panel in items(data, 'engagementPanels'):
        p = panel.get('engagementPanelSectionListRenderer')
        if isinstance(p, dict) and p.get('panelIdentifier') in ('comment-item-section', 'engagement-panel-comments-section'):
            n = dig(p, 'header', 'engagementPanelTitleHeaderRenderer', 'contextualInfo')
            if n is not None:
                return ie._get_count(n)
    return None


def comments_op(req):
    vid = req.get('id')
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise ValueError('invalid video id')
    n = req.get('n')
    n = min(max(n, 1), MAX_COMMENTS) if type(n) is int else 20
    opts = options(RequestLog(), None)
    # max_comments is "total,parents,replies,replies-per-thread": every top-level comment; replies only on request.
    opts['extractor_args'] = {'youtube': {'max_comments': ['all', 'all', '0', '0'], 'comment_sort': ['top']}}
    ydl = yt_dlp.YoutubeDL(opts)
    threads = {}
    try:
        ie = ydl.get_info_extractor('Youtube')
        hook_comments(ie, threads)
        # Straight from the watch page: yt-dlp's full extraction would also make player requests comments don't need.
        webpage = watch_page(ie, vid)
        data = ie.extract_yt_initial_data(vid, webpage)
        contents = items(data, 'contents', 'twoColumnWatchNextResults', 'results', 'results', 'contents')
        raw = ie._get_comments(ie.extract_ytcfg(vid, webpage) or {}, vid, contents, webpage)
        comments = top_level_comments(raw, ie.CommentsDisabled, threads)
        out, done = page(comments, n)
    except BaseException:
        ydl.close()
        raise
    count = comment_count(ie, data)
    result = {'comments': out, 'count': count if type(count) is int else None, 'done': done, 'cursor': None}
    if done and not threads:
        ydl.close()
    else:
        result['cursor'] = add_cursor(ydl, comments, 'comments', threads)
    return result


def replies_op(req):
    cursor, cid = req.get('cursor'), req.get('id')
    held = held_cursor(cursor)
    lock, threads = held[2], held[4]
    n = req.get('n')
    n = min(max(n, 1), MAX_COMMENTS) if type(n) is int else 10
    with lock:   # the replies share the comments' session and yt-dlp's state
        thread = (threads or {}).get(cid)
        if thread is None:
            raise ValueError('no more replies')
        try:
            out, done = page((r for r in map(comment_of, thread) if r), n)
        except BaseException:
            threads.pop(cid, None)
            raise
        if done:
            threads.pop(cid, None)
    return {'replies': out, 'done': done}


def dig(obj, *path):
    """obj[path[0]][path[1]]…, or None as soon as a step is missing or the wrong type."""
    for key in path:
        if isinstance(key, int):
            obj = obj[key] if isinstance(obj, list) and -len(obj) <= key < len(obj) else None
        else:
            obj = obj.get(key) if isinstance(obj, dict) else None
        if obj is None:
            return None
    return obj


def items(obj, *path):
    found = dig(obj, *path)
    return [x for x in found if isinstance(x, dict)] if isinstance(found, list) else []


def channel_playlists(data):
    """Playlists the watch page recommends that belong to the video's own channel, end screen first.
    They are candidates only: recommendations don't prove membership, so the app checks the playlist."""
    watch = ('contents', 'twoColumnWatchNextResults')
    owner = next((dig(c, 'videoSecondaryInfoRenderer', 'owner', 'videoOwnerRenderer',
                      'navigationEndpoint', 'browseEndpoint', 'browseId')
                  for c in items(data, *watch, 'results', 'results', 'contents')
                  if 'videoSecondaryInfoRenderer' in c), None)
    if not isinstance(owner, str):
        return []
    found = []   # (id, title, owner browseId)
    for r in items(data, 'playerOverlays', 'playerOverlayRenderer', 'endScreen', 'watchNextEndScreenRenderer', 'results'):
        p = r.get('endScreenPlaylistRenderer')
        if isinstance(p, dict):
            found.append((p.get('playlistId'), dig(p, 'title', 'simpleText'),
                          dig(p, 'longBylineText', 'runs', 0, 'navigationEndpoint', 'browseEndpoint', 'browseId')))
    for section in items(data, *watch, 'secondaryResults', 'secondaryResults', 'results'):
        for c in items(section, 'itemSectionRenderer', 'contents'):
            lockup = c.get('lockupViewModel')
            if not isinstance(lockup, dict) or lockup.get('contentType') != 'LOCKUP_CONTENT_TYPE_PLAYLIST':
                continue
            meta = dig(lockup, 'metadata', 'lockupMetadataViewModel')
            owners = [dig(run, 'onTap', 'innertubeCommand', 'browseEndpoint', 'browseId')
                      for row in items(meta, 'metadata', 'contentMetadataViewModel', 'metadataRows')
                      for part in items(row, 'metadataParts')
                      for run in items(part, 'text', 'commandRuns')]
            found.append((lockup.get('contentId'), dig(meta, 'title', 'content'),
                          owner if owner in owners else None))
    out, seen = [], set()
    for pid, title, by in found:
        # PL… only: mixes (RD…), uploads (UU…) and Watch Later aren't the channel's own playlists.
        if by != owner or not isinstance(pid, str) or not pid.startswith('PL') or pid in seen:
            continue
        seen.add(pid)
        out.append({'id': pid, 'title': title if isinstance(title, str) else ''})
    return out


def seconds_of(text):
    """A duration badge ("1:17:25", "0:59") in seconds."""
    if not isinstance(text, str) or not re.fullmatch(r'\d+(:\d{2}){0,2}', text):
        return None
    total = 0
    for part in text.split(':'):
        total = total * 60 + int(part)
    return total


def related_videos(data):
    """The videos the watch page suggests next, in its order, as listing entries."""
    out, seen = [], set()
    for section in items(data, 'contents', 'twoColumnWatchNextResults', 'secondaryResults', 'secondaryResults', 'results'):
        for c in [section] + items(section, 'itemSectionRenderer', 'contents'):
            lockup = c.get('lockupViewModel')
            if not isinstance(lockup, dict) or lockup.get('contentType') != 'LOCKUP_CONTENT_TYPE_VIDEO':
                continue
            vid = lockup.get('contentId')
            if not isinstance(vid, str) or not ID_RE.match(vid) or vid in seen:
                continue
            seen.add(vid)
            meta = dig(lockup, 'metadata', 'lockupMetadataViewModel')
            rows = items(meta, 'metadata', 'contentMetadataViewModel', 'metadataRows')
            parts = [[dig(p, 'text', 'content') for p in items(r, 'metadataParts')] for r in rows]
            channel_id = dig(meta, 'image', 'decoratedAvatarViewModel', 'rendererContext', 'commandContext', 'onTap',
                             'innertubeCommand', 'browseEndpoint', 'browseId')
            badge = next((dig(b, 'thumbnailBadgeViewModel', 'text')
                          for o in items(lockup, 'contentImage', 'thumbnailViewModel', 'overlays')
                          for b in items(o, 'thumbnailBottomOverlayViewModel', 'badges')), None)
            title = dig(meta, 'title', 'content')
            out.append({
                'kind': 'video',
                'id': vid,
                'title': title if isinstance(title, str) else '',
                'channel': parts[0][0] if parts and parts[0] and isinstance(parts[0][0], str) else None,
                'channel_id': channel_id if isinstance(channel_id, str) and CHANNEL_ID_RE.fullmatch(channel_id) else None,
                'duration': seconds_of(badge),
                'views': count_of(parts[1][0]) if len(parts) > 1 and parts[1] else None,
                'thumbnail': None,   # the app shows DeArrow's or the video's own frame, never YouTube's designed one
                'count': None,
            })
    return out


def related_op(req):
    vid = req.get('id')
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise ValueError('invalid video id')
    with yt_dlp.YoutubeDL(options(RequestLog(), None)) as ydl:
        ie = ydl.get_info_extractor('Youtube')
        data = ie.extract_yt_initial_data(vid, watch_page(ie, vid))
    return {'videos': related_videos(data)}


MAX_DESCRIPTIONS = 60
DESCRIPTION_PAUSE = 1.0   # seconds between watch pages: bulk requests get the IP flagged
SOCIAL_RE = re.compile(r'(?i)\b(subscribe|patreon|instagram|twitter|tiktok|facebook|discord|merch|sponsor|affiliate'
                       r'|promo code)\b')


def clean_description(text):
    """A description as the recommender reads it: no links, hashtags, timestamps or social lines; ≤ 600 characters."""
    lines = []
    for line in (text or '').splitlines():
        line = re.sub(r'https?://\S+|www\.\S+|\S+@\S+\.\S+|#\w+', ' ', line)
        line = re.sub(r'\b\d{1,2}:\d{2}(:\d{2})?\b', ' ', line)
        if SOCIAL_RE.search(line):
            continue
        line = re.sub(r'\s+', ' ', line).strip(' -|•:')
        if len(line) > 2:
            lines.append(line)
    return ' '.join(lines)[:600]


def throttled(message):
    return '429' in message or 'Too Many Requests' in message or 'not a bot' in message


def description_of(ie, vid):
    """The watch page's description, read without the shared watch-page cache so the open video's page stays in it.
    Raises when YouTube asks for a bot check."""
    page = ie._download_webpage(f'https://www.youtube.com/watch?v={vid}', vid)
    player = ie._search_json(r'ytInitialPlayerResponse\s*=', page, 'player response', vid, default={}) or {}
    reason = str(dig(player, 'playabilityStatus', 'reason') or '')
    if throttled(reason):
        raise RuntimeError(reason)
    text = dig(player, 'videoDetails', 'shortDescription')
    if not isinstance(text, str):
        data = ie.extract_yt_initial_data(vid, page)
        text = next((dig(c, 'videoSecondaryInfoRenderer', 'attributedDescription', 'content')
                     for c in items(data, 'contents', 'twoColumnWatchNextResults', 'results', 'results', 'contents')
                     if 'videoSecondaryInfoRenderer' in c), None)
    return clean_description(text if isinstance(text, str) else '')


def descriptions_op(req):
    """Cleaned descriptions, one watch page at a time, DESCRIPTION_PAUSE apart. A throttle or bot check stops the
    batch with `stopped`; any other failure skips that video."""
    ids = req.get('ids')
    if (not isinstance(ids, list) or len(ids) > MAX_DESCRIPTIONS
            or not all(isinstance(v, str) and ID_RE.match(v) for v in ids)):
        raise ValueError('invalid ids')
    out, stopped = {}, False
    with yt_dlp.YoutubeDL(options(RequestLog(), None)) as ydl:
        ie = ydl.get_info_extractor('Youtube')
        for i, vid in enumerate(ids):
            if i:
                time.sleep(DESCRIPTION_PAUSE)
            try:
                out[vid] = description_of(ie, vid)
            except Exception as e:  # noqa: BLE001 - one video's failure doesn't fail the batch
                if throttled(str(e)):
                    stopped = True
                    break
    return {'descriptions': out, 'stopped': stopped}


def playlists_op(req):
    vid = req.get('id')
    if not isinstance(vid, str) or not ID_RE.match(vid):
        raise ValueError('invalid video id')
    # yt-dlp's resolve info doesn't carry the watch page's recommendations, so read the page itself.
    with yt_dlp.YoutubeDL(options(RequestLog(), None)) as ydl:
        ie = ydl.get_info_extractor('Youtube')
        data = ie.extract_yt_initial_data(vid, watch_page(ie, vid))
    return {'playlists': channel_playlists(data)}


def main():
    os.setpgrp()   # own process group, so the app can kill Deno along with us
    print(json.dumps({'ready': True}), flush=True)
    out_lock = threading.Lock()
    with ThreadPoolExecutor(MAX_PARALLEL) as pool:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                req = json.loads(line)
                rid = req['rid']
            except (ValueError, KeyError, TypeError):
                print('worker: ignoring malformed request', file=sys.stderr, flush=True)
                continue
            if isinstance(req, dict) and req.get('op') == 'cancel':
                run(req, rid, out_lock)   # at once: it must not wait behind the downloads it stops
            else:
                pool.submit(run, req, rid, out_lock)


def run(req, rid, out_lock):
    t0 = time.perf_counter()
    out = {'rid': rid, 'ok': False, 'error': None}
    try:
        if req.get('op') == 'warm':
            subprocess.run([os.environ['MATINEE_DENO'], '--version'], capture_output=True, timeout=60, check=True)
        elif req.get('op') == 'resolve':
            out.update(resolve(req))
        elif req.get('op') == 'list':
            out.update(list_op(req))
        elif req.get('op') == 'more':
            out.update(more_op(req))
        elif req.get('op') == 'download':
            def emit(event):
                with out_lock:
                    print(json.dumps({'rid': rid, **event}), flush=True)
            out.update(download_op(req, emit))
        elif req.get('op') == 'comments':
            out.update(comments_op(req))
        elif req.get('op') == 'replies':
            out.update(replies_op(req))
        elif req.get('op') == 'cancel':
            out.update(cancel_op(req))


        elif req.get('op') == 'playlists':
            out.update(playlists_op(req))
        elif req.get('op') == 'related':
            out.update(related_op(req))
        elif req.get('op') == 'descriptions':
            out.update(descriptions_op(req))
        else:
            raise ValueError('unknown op')
        out['ok'] = True
    except Exception as e:  # noqa: BLE001 - every failure becomes an error response
        out['error'] = str(e)[:500]
    out['ms'] = round((time.perf_counter() - t0) * 1000)
    with out_lock:
        print(json.dumps(out), flush=True)


if __name__ == '__main__':
    main()
