"""Tests for the pure helpers and the list/more ops of matinee_worker.py (no network, yt_dlp is stubbed).
Run: python3 -I Matinee/Worker/test_matinee_worker.py"""
import importlib.util
import itertools
import os
import sys
import types
import unittest
import unittest.mock

stub = types.ModuleType('yt_dlp')
stub_globals = types.ModuleType('yt_dlp.globals')
stub_globals.plugin_dirs = types.SimpleNamespace(value=['x'])
stub.globals = stub_globals
stub_utils = types.ModuleType('yt_dlp.utils')


class DownloadCancelled(Exception):
    pass


stub_utils.DownloadCancelled = DownloadCancelled
stub.utils = stub_utils
stub_pp = types.ModuleType('yt_dlp.postprocessor')


class PostProcessor:
    def __init__(self, downloader=None):
        pass


stub_pp.PostProcessor = PostProcessor
stub.postprocessor = stub_pp


class StubIE:
    """yt-dlp's YouTube extractor, as far as comments go. StubYDL.comments(ie) plays its comment generator: it calls
    _extract_comment for each comment and, after yielding one, _comment_entries for its replies (not yet fetched)."""
    class CommentsDisabled(Exception):
        pass

    pages = []   # watch pages downloaded, by video id
    replies = {}   # comment id -> how many of its replies were fetched

    def _download_webpage(self, url, vid):
        StubIE.pages.append(vid)
        return f'<html>{vid}</html>'

    def extract_yt_initial_data(self, vid, webpage):
        return {'contents': {'twoColumnWatchNextResults': {'results': {'results': {'contents': [
            {'itemSectionRenderer': {'contents': [
                {'commentsEntryPointHeaderRenderer': {'commentCount': {'simpleText': '1.2K'}}}]}}]}}}}}

    def extract_ytcfg(self, vid, webpage):
        return {'cfg': vid}

    @staticmethod
    def _get_count(obj):
        return 1234 if obj == {'simpleText': '1.2K'} else None

    def _get_comments(self, ytcfg, vid, contents, webpage):
        assert ytcfg == {'cfg': vid} and webpage == f'<html>{vid}</html>' and contents
        return StubYDL.comments(self)

    def _extract_comment(self, entities, parent=None):
        props = entities[0]['payload']['commentEntityPayload']['properties']
        return {'id': props['commentId'], 'parent': parent or 'root', 'text': 'hi'}

    def _comment_entries(self, root, ytcfg, video_id, parent=None, tracker=None, depth=1):
        def replies():
            for j in range(root['n']):
                StubIE.replies[parent] = StubIE.replies.get(parent, 0) + 1
                yield {'id': f'{parent}.{j}', 'parent': parent, 'text': 'a reply'}
        return replies()


def entities(cid, replies=None):
    payload = {'properties': {'commentId': cid}}
    if replies is not None:
        payload['toolbar'] = {'replyCount': replies}
    return [{'payload': {'commentEntityPayload': payload}}]


def fake_comments(top, replies=lambda i: 0):
    """yt-dlp's comment generator for `top` comments, comment i having replies(i) replies."""
    def generate(ie):
        for i in range(top):
            n = replies(i)
            yield ie._extract_comment(entities(f'c{i}', str(n) if n else None))
            if n:
                yield from itertools.islice(ie._comment_entries({'n': n}, 'cfg', 'v', parent=f'c{i}', depth=2), 0)
    return generate


class StubYDL:
    made = []
    comments = None   # when set, extract_info of a watch page calls extract_comments, and this makes the comments
    entries = staticmethod(lambda: iter(()))
    script = None   # when set, extract_info returns these in turn (the last one repeats)
    closed = 0
    # extract_info(download=True) calls this with the instance and the video id; default: fake_download.
    downloader = None

    def __init__(self, opts):
        self.opts = opts
        self.calls = []
        self.ie = StubIE()
        self.pps = []
        StubYDL.made.append(self)

    def add_post_processor(self, pp, when='post_process'):
        self.pps.append((when, pp))

    def get_info_extractor(self, key):
        return self.ie

    def extract_info(self, url, download=True, process=True, ie_key=None):
        self.calls.append((url, download, process, ie_key))
        if download:
            vid = url.rsplit('=', 1)[-1]
            return (StubYDL.downloader or fake_download)(self, vid)
        if StubYDL.script is not None:
            return StubYDL.script.pop(0) if len(StubYDL.script) > 1 else StubYDL.script[0]
        return {'title': 'T', 'channel_id': 'UC' + 'a' * 22, 'uploader': 'Up', 'entries': StubYDL.entries()}

    @staticmethod
    def post_extract(info):
        info.update((info.pop('__post_extractor', None) or dict)())

    def close(self):
        StubYDL.closed += 1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def out_dir(ydl):
    return os.path.dirname(ydl.opts['outtmpl']).replace('%%', '%')


def fake_download(ydl, vid):
    """yt-dlp downloading: progress at 10, 50 and 100 of 100 bytes, then the merged file."""
    for n in (10, 50, 100):
        for hook in ydl.opts['progress_hooks']:
            hook({'status': 'downloading', 'downloaded_bytes': n, 'total_bytes': 100})
    for hook in ydl.opts['progress_hooks']:
        hook({'status': 'finished'})
    with open(os.path.join(out_dir(ydl), vid + '.mp4'), 'wb') as f:
        f.write(b'x' * 100)
    return {'title': 'Ti', 'channel': 'Ch', 'channel_id': CHANNEL, 'duration': 9.0}


stub.YoutubeDL = StubYDL
sys.modules['yt_dlp'] = stub
sys.modules['yt_dlp.globals'] = stub_globals
sys.modules['yt_dlp.utils'] = stub_utils
sys.modules['yt_dlp.postprocessor'] = stub_pp

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'matinee_worker.py')


def load_worker():
    spec = importlib.util.spec_from_file_location('matinee_worker', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


worker = load_worker()

SEARCH = 'https://www.youtube.com/results?search_query=cats'
CHANNEL = 'UC' + 'b' * 22


def video(i, **kw):
    vid = f'{i:011d}'
    return {'_type': 'url', 'ie_key': 'Youtube', 'id': vid, 'url': f'https://www.youtube.com/watch?v={vid}',
            'title': f'v{i}', **kw}


class WorkerTests(unittest.TestCase):
    def setUp(self):
        worker.CURSORS.clear()
        StubYDL.made.clear()
        StubYDL.script = None
        StubYDL.comments = None
        StubIE.pages = []
        StubIE.replies = {}
        worker.WATCH_PAGES.clear()
        StubYDL.closed = 0
        StubYDL.downloader = None

    def test_entry_kinds(self):
        v = worker.entry_of(video(1, duration=61, view_count=7, channel='C', channel_id=CHANNEL,
                                  thumbnails=[{'url': 'http://a/x'}, {'url': 'https://a/1'}, {'url': 'https://a/2'},
                                              {'url': 'http://a/3'}]))
        self.assertEqual(v, {'kind': 'video', 'id': f'{1:011d}', 'title': 'v1', 'channel': 'C', 'channel_id': CHANNEL,
                             'duration': 61, 'views': 7, 'thumbnail': 'https://a/2', 'count': None})
        c = worker.entry_of({'ie_key': 'YoutubeTab', 'id': CHANNEL, 'url': 'https://www.youtube.com/channel/' + CHANNEL,
                             'title': 'Chan', 'channel': 'Chan', 'channel_id': CHANNEL, 'playlist_count': 5})
        self.assertEqual((c['kind'], c['id'], c['count']), ('channel', CHANNEL, 5))
        p = worker.entry_of({'ie_key': 'YoutubeTab', 'id': 'PL' + 'c' * 20, 'title': 'P',
                             'url': 'https://www.youtube.com/playlist?list=PL' + 'c' * 20, 'playlist_count': 3})
        self.assertEqual((p['kind'], p['count']), ('playlist', 3))
        p2 = worker.entry_of({'ie_key': 'YoutubeTab', 'id': 'PL' + 'd' * 20, 'title': 'P2'})
        self.assertEqual(p2['kind'], 'playlist')
        self.assertIsNone(worker.entry_of({'id': 'short', 'title': 'x', 'url': 'https://example.com/'}))

    def test_entry_with_missing_fields_is_kept(self):
        e = worker.entry_of({'id': f'{2:011d}', 'title': 'v2', 'url': 'https://www.youtube.com/watch?v=x'})
        self.assertEqual(e, {'kind': 'video', 'id': f'{2:011d}', 'title': 'v2', 'channel': None, 'channel_id': None,
                             'duration': None, 'views': None, 'thumbnail': None, 'count': None})

    def test_private_and_deleted_playlist_items_are_dropped(self):
        self.assertIsNone(worker.entry_of(video(3, title='[Private video]')))
        self.assertIsNone(worker.entry_of(video(4, title='[Deleted video]')))

    def test_id_with_trailing_newline_is_rejected(self):
        # Python's `$` also matches before a final newline
        with self.assertRaisesRegex(ValueError, 'invalid video id'):
            worker.resolve({'id': 'a' * 11 + '\n'})
        self.assertEqual(StubYDL.made, [])

    def test_search_query_without_whitespace_or_controls(self):
        for q in ['a b', 'a\nb', 'a\tb', 'a\x00b']:
            self.assertFalse(worker.url_allowed('https://www.youtube.com/results?search_query=' + q), repr(q))
        self.assertTrue(worker.url_allowed('https://www.youtube.com/results?search_query=a%20b%0A'))

    def test_url_outside_allowlist_rejected(self):
        for url in ['https://www.youtube.com/watch?v=x', 'https://evil.com/results?search_query=a',
                    'https://www.youtube.com/@a/playlists --exec x', 'https://www.youtube.com/@abc/playlists --exec x',
                    'https://www.youtube.com/@abc/playlists\n',
                    'https://www.youtube.com/playlist?list=' + 'P' * 12 + '&v=x']:
            self.assertFalse(worker.url_allowed(url), url)
            with self.assertRaisesRegex(ValueError, 'url not allowed'):
                worker.list_op({'url': url, 'n': 5})
        for url in [SEARCH, SEARCH + '&sp=EgIQAQ%3D%3D', 'https://www.youtube.com/playlist?list=' + 'P' * 12,
                    f'https://www.youtube.com/channel/{CHANNEL}/playlists', 'https://www.youtube.com/@abc/playlists']:
            self.assertTrue(worker.url_allowed(url), url)
        self.assertEqual(StubYDL.made, [])

    def test_only_search_skips_the_webpage(self):
        StubYDL.entries = staticmethod(lambda: iter(()))
        worker.list_op({'url': SEARCH, 'n': 5})
        worker.list_op({'url': 'https://www.youtube.com/playlist?list=' + 'P' * 12, 'n': 5})
        self.assertEqual(StubYDL.made[0].opts.get('extractor_args'), {'youtubetab': {'skip': ['webpage']}})
        self.assertNotIn('extractor_args', StubYDL.made[1].opts)

    def test_cursor_pages_and_eviction(self):
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(45)))
        a = worker.list_op({'url': SEARCH, 'n': 20})
        self.assertEqual((len(a['entries']), a['done'], a['title'], a['channel_id'], a['channel']),
                         (20, False, 'T', 'UC' + 'a' * 22, 'Up'))
        self.assertEqual(StubYDL.made[0].calls, [(SEARCH, False, False, None)])
        self.assertTrue(StubYDL.made[0].opts['extract_flat'] == 'in_playlist')
        self.assertNotIn('format', StubYDL.made[0].opts)
        self.assertNotIn('noplaylist', StubYDL.made[0].opts)
        m = worker.more_op({'cursor': a['cursor'], 'n': 20})
        self.assertEqual((len(m['entries']), m['done']), (20, False))
        self.assertEqual(m['entries'][0]['id'], f'{20:011d}')
        m = worker.more_op({'cursor': a['cursor'], 'n': 20})
        self.assertEqual((len(m['entries']), m['done']), (5, True))
        self.assertEqual(len(worker.CURSORS), 0)

    def test_cursor_eviction_drops_the_least_recently_used(self):
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(45)))
        first = worker.list_op({'url': SEARCH, 'n': 1})['cursor']
        second = worker.list_op({'url': SEARCH, 'n': 1})['cursor']
        for _ in range(6):
            worker.list_op({'url': SEARCH, 'n': 1})
        self.assertEqual(len(worker.CURSORS), 8)
        self.assertEqual(len(worker.more_op({'cursor': first, 'n': 1})['entries']), 1)   # refreshes its age
        self.assertEqual(StubYDL.closed, 0)
        worker.list_op({'url': SEARCH, 'n': 1})
        self.assertEqual(len(worker.CURSORS), 8)
        self.assertEqual(StubYDL.closed, 1)
        self.assertEqual(len(worker.more_op({'cursor': first, 'n': 1})['entries']), 1)
        with self.assertRaisesRegex(ValueError, 'cursor expired'):
            worker.more_op({'cursor': second, 'n': 1})

    def test_cursors_differ_across_worker_restarts(self):
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(45)))
        first = load_worker().list_op({'url': SEARCH, 'n': 1})['cursor']
        second = load_worker().list_op({'url': SEARCH, 'n': 1})['cursor']
        self.assertNotEqual(first, second)

    def test_url_result_is_followed_and_rechecked(self):
        playlist = 'https://www.youtube.com/playlist?list=' + 'P' * 12
        StubYDL.script = [{'_type': 'url', 'url': playlist, 'ie_key': 'YoutubeTab'},
                          {'title': 'PL', 'entries': (video(i) for i in range(3))}]
        r = worker.list_op({'url': SEARCH, 'n': 5})
        self.assertEqual((len(r['entries']), r['done'], r['title']), (3, True, 'PL'))
        self.assertEqual(StubYDL.made[0].calls[1], (playlist, False, False, 'YoutubeTab'))

    def test_url_result_outside_allowlist_or_unresolved_fails(self):
        StubYDL.script = [{'_type': 'url', 'url': 'https://evil.com/x'}]
        with self.assertRaisesRegex(ValueError, 'url not allowed'):
            worker.list_op({'url': SEARCH, 'n': 5})
        StubYDL.script = [{'_type': 'url', 'url': SEARCH}]   # redirects to itself forever
        with self.assertRaisesRegex(ValueError, 'not a listing'):
            worker.list_op({'url': SEARCH, 'n': 5})
        StubYDL.script = [{'title': 'no entries'}]
        with self.assertRaisesRegex(ValueError, 'not a listing'):
            worker.list_op({'url': SEARCH, 'n': 5})

    def test_max_height_sorts_by_resolution(self):
        StubYDL.script = [{'url': 'https://v/x', 'vcodec': 'vp9', 'height': 1440}]
        worker.resolve({'id': 'a' * 11, 'max_height': 1440})
        worker.resolve({'id': 'a' * 11})
        self.assertEqual(StubYDL.made[0].opts['format_sort'], ['res:1440', 'vcodec:vp9'])
        self.assertEqual(StubYDL.made[1].opts['format_sort'], ['vcodec:vp9'])
        for bad in [99999, 100, True, '1440']:
            with self.assertRaisesRegex(ValueError, 'invalid max_height'):
                worker.resolve({'id': 'a' * 11, 'max_height': bad})
        self.assertEqual(len(StubYDL.made), 2)

    def test_qualities_listed(self):
        fmts = [{'url': 'https://v/1', 'vcodec': 'vp9', 'height': 2160},
                {'url': 'https://v/2', 'vcodec': 'vp9', 'height': 1440},
                {'url': 'https://v/3', 'vcodec': 'avc1', 'height': 1440},
                {'url': 'https://v/4', 'vcodec': 'avc1', 'height': 1080},
                {'url': 'http://v/5', 'vcodec': 'avc1', 'height': 720},
                {'url': 'https://v/a', 'vcodec': 'none', 'acodec': 'opus'}]
        StubYDL.script = [{'formats': fmts, 'requested_formats': [fmts[0], fmts[5]]}]
        self.assertEqual(worker.resolve({'id': 'a' * 11})['qualities'], [2160, 1440, 1080])

    def test_resolve_returns_metadata(self):
        fmt = {'url': 'https://v/1', 'vcodec': 'vp9', 'height': 1080}
        StubYDL.script = [{'title': 'Title', 'channel': 'Uploader', 'channel_id': CHANNEL, 'duration': 213.0,
                           'requested_formats': [fmt]}]
        out = worker.resolve({'id': 'a' * 11})
        self.assertEqual((out['title'], out['channel'], out['channel_id'], out['duration']),
                         ('Title', 'Uploader', CHANNEL, 213.0))
        StubYDL.script = [{'requested_formats': [fmt]}]
        out = worker.resolve({'id': 'a' * 11})
        self.assertEqual((out['title'], out['channel'], out['channel_id'], out['duration']), (None, None, None, None))

    def test_n_is_clamped(self):
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(300)))
        self.assertEqual(len(worker.list_op({'url': SEARCH, 'n': 1000})['entries']), 200)
        self.assertEqual(len(worker.list_op({'url': SEARCH, 'n': 0})['entries']), 1)

    def test_slow_more_does_not_hold_up_a_new_list(self):
        import io, json, threading
        gate = threading.Event()

        def slow():
            yield video(0)
            gate.wait(5)   # the next page hangs until the new search has been answered
            yield video(1)
        StubYDL.entries = staticmethod(slow)
        cursor = worker.list_op({'url': SEARCH, 'n': 1})['cursor']
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(5)))
        read_fd, write_fd = os.pipe()
        replies = []

        class Out(io.StringIO):
            def write(self, s):
                for line in filter(None, s.splitlines()):
                    reply = json.loads(line)
                    replies.append(reply.get('rid'))
                    if reply.get('rid') == 2:
                        gate.set()
                return len(s)

            def flush(self):
                pass
        saved = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = os.fdopen(read_fd), Out()
        try:
            with os.fdopen(write_fd, 'w') as w:
                w.write(json.dumps({'rid': 1, 'op': 'more', 'cursor': cursor, 'n': 1}) + '\n')
                w.write(json.dumps({'rid': 2, 'op': 'list', 'url': SEARCH, 'n': 1}) + '\n')
            # main() leaves the process group; the test runner must stay in its own, or Ctrl-C and a runner's
            # group kill no longer reach it.
            with unittest.mock.patch.object(worker.os, 'setpgrp', lambda: None):
                worker.main()
        finally:
            sys.stdin.close()
            sys.stdin, sys.stdout = saved
        self.assertTrue(gate.is_set())
        self.assertEqual(replies, [None, 2, 1])   # ready, the new list, then the slow page

    def test_concurrent_mores_on_one_cursor_take_turns(self):
        import threading
        StubYDL.entries = staticmethod(lambda: (video(i) for i in range(45)))
        cursor = worker.list_op({'url': SEARCH, 'n': 1})['cursor']
        got = []
        threads = [threading.Thread(target=lambda: got.extend(e['id'] for e in worker.more_op({'cursor': cursor, 'n': 10})['entries']))
                   for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(sorted(got), [f'{i:011d}' for i in range(1, 41)])

    def test_download_writes_into_dir_with_validated_id(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, 'invalid video id'):
                worker.download_op({'rid': 1, 'id': 'nope', 'dir': d}, print)
            for bad in ['relative/dir', os.path.join(d, 'missing'), None]:
                with self.assertRaisesRegex(ValueError, 'invalid dir'):
                    worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': bad}, print)
            for bad in [99999, True, '1080']:
                with self.assertRaisesRegex(ValueError, 'invalid max_height'):
                    worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': d, 'max_height': bad}, print)
            self.assertEqual(StubYDL.made, [])
            os.environ['MATINEE_FFMPEG'] = '/x/ffmpeg'
            try:
                out = worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': d}, lambda e: None)
                worker.download_op({'rid': 2, 'id': 'b' * 11, 'dir': d, 'max_height': 1080}, lambda e: None)
            finally:
                del os.environ['MATINEE_FFMPEG']
            opts = StubYDL.made[0].opts
            self.assertEqual(opts['outtmpl'], os.path.join(d, 'a' * 11 + '.%(ext)s'))
            self.assertEqual((opts['merge_output_format'], opts['format'], opts['format_sort']),
                             ('mp4', 'bv*+ba/b', ['res', 'vcodec:vp9']))
            self.assertEqual((opts['ffmpeg_location'], opts['noplaylist']), ('/x/ffmpeg', True))
            self.assertNotIn('skip_download', opts)
            self.assertEqual(StubYDL.made[1].opts['format_sort'], ['res:1080', 'vcodec:vp9'])
            self.assertEqual(out, {'file': os.path.join(d, 'a' * 11 + '.mp4'), 'bytes': 100, 'title': 'Ti',
                                   'channel': 'Ch', 'channel_id': CHANNEL, 'duration': 9.0})

    def test_download_dir_is_not_a_template(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            d = os.path.join(root, '100%(id)s')
            os.mkdir(d)
            out = worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': d}, lambda e: None)
            self.assertEqual(StubYDL.made[0].opts['outtmpl'], os.path.join(root, '100%%(id)s', 'a' * 11 + '.%(ext)s'))
            self.assertEqual(out['file'], os.path.join(d, 'a' * 11 + '.mp4'))

    def test_download_reports_progress_lines(self):
        import io, json, tempfile
        with tempfile.TemporaryDirectory() as d:
            saved = sys.stdin, sys.stdout
            sys.stdin = io.StringIO(json.dumps({'rid': 7, 'op': 'download', 'id': 'a' * 11, 'dir': d}) + '\n')
            sys.stdout = io.StringIO()
            try:
                worker.main()
                lines = [json.loads(l) for l in sys.stdout.getvalue().splitlines()]
            finally:
                sys.stdin, sys.stdout = saved
        progress = [l for l in lines if l.get('event') == 'progress']
        self.assertTrue(progress)
        self.assertTrue(all(l['rid'] == 7 and l['total'] == 100 for l in progress))
        self.assertEqual(progress[0]['downloaded'], 10)
        self.assertEqual(progress[-1]['downloaded'], 100)
        self.assertEqual(lines[-1]['rid'], 7)
        self.assertTrue(lines[-1]['ok'])
        self.assertNotIn('event', lines[-1])

    def test_progress_counts_video_and_audio_as_one(self):
        p = worker.Progress(clock=lambda: 0.0)
        p.plan([{'format_id': '137', 'filesize': 800}, {'format_id': '251', 'filesize_approx': 200}], duration=10)
        steps = [('137', 400, 820), ('137', 820, 820), ('251', 100, 190), ('251', 190, 190)]
        out = [p.update({'downloaded_bytes': n, 'total_bytes': t, 'info_dict': {'format_id': f}}) for f, n, t in steps]
        # A started file counts with its exact size, one not started yet with yt-dlp's planned size.
        self.assertEqual([(u['downloaded'], u['total']) for u in out], [(400, 1020), (820, 1020), (920, 1010), (1010, 1010)])
        fractions = [u['fraction'] for u in out]
        self.assertEqual(fractions, sorted(fractions))
        self.assertEqual(fractions[-1], 1.0)
        self.assertTrue(all(u['stage'] == 'downloading' for u in out))

    def test_progress_estimates_a_missing_size_from_the_bitrate(self):
        p = worker.Progress(clock=lambda: 0.0)
        p.plan([{'format_id': '137', 'filesize': 800}, {'format_id': '251', 'tbr': 160}], duration=10)
        u = p.update({'downloaded_bytes': 400, 'total_bytes': 800, 'info_dict': {'format_id': '137'}})
        self.assertEqual(u['total'], 800 + 160 * 1000 // 8 * 10)
        q = worker.Progress(clock=lambda: 0.0)
        q.plan([{'format_id': '137', 'filesize': 800}, {'format_id': '251'}], duration=None)
        u = q.update({'downloaded_bytes': 400, 'total_bytes': 800, 'info_dict': {'format_id': '137'}})
        self.assertEqual((u['downloaded'], u['total'], u['fraction'], u['eta']), (400, None, None, None),
                         'an unknown size is reported as unknown, not guessed')

    def test_progress_speed_is_over_the_last_seconds_and_eta_over_what_remains(self):
        now = [0.0]
        p = worker.Progress(clock=lambda: now[0])
        p.plan([{'format_id': 'v', 'filesize': 10000}, {'format_id': 'a', 'filesize': 2000}], duration=10)
        u = None
        for i in range(1, 11):   # 100 bytes a second for 10 s
            now[0] = float(i)
            u = p.update({'downloaded_bytes': 100 * i, 'total_bytes': 10000, 'info_dict': {'format_id': 'v'}})
        self.assertAlmostEqual(u['speed'], 100.0)
        self.assertAlmostEqual(u['eta'], (12000 - 1000) / 100.0)
        for i in range(11, 14):   # then 1000 bytes a second: the last 5 s weigh, not the whole download
            now[0] = float(i)
            u = p.update({'downloaded_bytes': 1000 + 1000 * (i - 10), 'total_bytes': 10000, 'info_dict': {'format_id': 'v'}})
        self.assertGreater(u['speed'], 500.0)

    def test_progress_never_goes_back(self):
        p = worker.Progress(clock=lambda: 0.0)
        a = p.update({'downloaded_bytes': 500, 'total_bytes_estimate': 1000, 'info_dict': {'format_id': 'x'}})
        b = p.update({'downloaded_bytes': 600, 'total_bytes_estimate': 2000, 'info_dict': {'format_id': 'x'}})
        self.assertEqual((a['fraction'], b['fraction']), (0.5, 0.5))

    def test_download_reports_one_total_for_video_and_audio(self):
        import tempfile
        formats = [{'format_id': '137', 'filesize': 800}, {'format_id': '251', 'filesize_approx': 200}]

        def two_files(ydl, vid):
            # yt-dlp runs before_dl postprocessors with the chosen formats; the progress hook never sees them.
            for when, pp in ydl.pps:
                if when == 'before_dl':
                    pp.run({'requested_formats': formats, 'duration': 10})
            for fid, size in (('137', 800), ('251', 200)):
                for n in (size // 2, size):
                    for hook in ydl.opts['progress_hooks']:
                        hook({'status': 'downloading', 'downloaded_bytes': n, 'total_bytes': size,
                              'info_dict': {'format_id': fid}})
            with open(os.path.join(out_dir(ydl), vid + '.mp4'), 'wb') as f:
                f.write(b'x')
            return {'title': 'Ti'}
        StubYDL.downloader = two_files
        events = []
        with tempfile.TemporaryDirectory() as d:
            worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': d}, events.append)
        self.assertTrue(all(e['total'] == 1000 for e in events), events)
        self.assertEqual((events[-1]['downloaded'], events[-1]['fraction']), (1000, 1.0))

    def test_download_reports_finishing_while_merging(self):
        import tempfile, time
        def merge(ydl, vid):
            for when, pp in ydl.pps:   # the planning postprocessor's own start is no merge
                if when == 'before_dl':
                    for hook in ydl.opts['postprocessor_hooks']:
                        hook({'status': 'started', 'postprocessor': 'Plan'})
                    pp.run({'requested_formats': [{'format_id': '18', 'filesize': 100}]})
            for hook in ydl.opts['progress_hooks']:
                hook({'status': 'downloading', 'downloaded_bytes': 100, 'total_bytes': 100, 'info_dict': {'format_id': '18'}})
            for hook in ydl.opts['postprocessor_hooks']:
                hook({'status': 'started', 'postprocessor': 'Merger'})
            time.sleep(0.35)   # a long merge: the finishing line repeats, so the app's timeout doesn't fire
            with open(os.path.join(out_dir(ydl), vid + '.mp4'), 'wb') as f:
                f.write(b'x')
            return {'title': 'Ti'}
        StubYDL.downloader = merge
        events = []
        with unittest.mock.patch.object(worker, 'FINISHING_INTERVAL', 0.1), tempfile.TemporaryDirectory() as d:
            worker.download_op({'rid': 1, 'id': 'a' * 11, 'dir': d}, events.append)
            after = len(events)
            time.sleep(0.25)
        self.assertEqual(events[0]['stage'], 'downloading')
        finishing = [e for e in events if e['stage'] == 'finishing']
        self.assertGreaterEqual(len(finishing), 3, events)
        self.assertTrue(all((e['downloaded'], e['total'], e['fraction']) == (100, 100, 1.0) for e in finishing))
        self.assertEqual(len(events), after, 'no finishing lines after the download returns')

    def test_cancel_stops_a_download(self):
        import tempfile, threading, time
        started = threading.Event()

        def stuck(ydl, vid):
            d = out_dir(ydl)
            for name in (vid + '.mp4.part', vid + '.f137.mp4', vid + '.f251.webm.part', vid + '.mp4.ytdl'):
                open(os.path.join(d, name), 'w').close()
            started.set()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                for hook in ydl.opts['progress_hooks']:
                    hook({'status': 'downloading', 'downloaded_bytes': 1, 'total_bytes': None})
                time.sleep(0.01)
            raise AssertionError('never cancelled')
        StubYDL.downloader = stuck
        with tempfile.TemporaryDirectory() as d:
            keep = os.path.join(d, 'b' * 11 + '.mp4.part')   # another video's download
            open(keep, 'w').close()
            result = {}

            def go():
                try:
                    worker.download_op({'rid': 9, 'id': 'a' * 11, 'dir': d}, lambda e: None)
                except Exception as e:  # noqa: BLE001
                    result['error'] = str(e)
            t = threading.Thread(target=go)
            t.start()
            self.assertTrue(started.wait(2))
            self.assertEqual(worker.cancel_op({'target': 9}), {})
            t.join(3)
            self.assertFalse(t.is_alive())
            self.assertEqual(result.get('error'), 'cancelled')
            self.assertEqual(os.listdir(d), [os.path.basename(keep)])
        with self.assertRaisesRegex(ValueError, 'invalid target'):
            worker.cancel_op({'target': 'x'})


    def test_comment_of_keeps_what_the_app_shows(self):
        self.assertEqual(worker.comment_of(
            {'id': 'c1', 'parent': 'root', 'text': 'First', 'author': '@a', 'author_id': CHANNEL, 'like_count': 12,
             '_time_text': '2 days ago', 'author_is_uploader': True, 'is_favorited': True, 'reply_count': 670}),
            {'id': 'c1', 'text': 'First', 'author': '@a', 'author_id': CHANNEL, 'likes': 12, 'time': '2 days ago',
             'is_uploader': True, 'hearted': True, 'reply_count': 670, 'has_replies': False})
        c2 = worker.comment_of({'id': 'c2', 'parent': 'root', 'text': 'x' * 6000, 'author': None, 'author_id': 'not-a-channel'})
        self.assertEqual((len(c2['text']), c2['author'], c2['author_id'], c2['likes'], c2['reply_count']),
                         (5000, '', None, None, None))
        self.assertIsNone(worker.comment_of({'id': 'c3', 'parent': 'root', 'text': None}))
        self.assertIsNone(worker.comment_of({'parent': 'root', 'text': 'no id'}))

    def test_count_of_reads_youtubes_short_counts(self):
        self.assertEqual([worker.count_of(t) for t in ('670', '1,024', '1.2K', '3M', '', 'many', None)],
                         [670, 1024, 1200, 3000000, None, None, None])

    def test_comments_page_through_every_top_level_comment(self):
        with self.assertRaisesRegex(ValueError, 'invalid video id'):
            worker.comments_op({'id': 'nope'})
        fetched = []
        def generate(ie):
            for i in range(45):
                fetched.append(i)
                yield ie._extract_comment(entities(f'c{i}'))
        StubYDL.comments = generate
        first = worker.comments_op({'id': 'a' * 11, 'n': 20})
        self.assertEqual([c['id'] for c in first['comments']], [f'c{i}' for i in range(20)])
        self.assertEqual((first['count'], first['done']), (1234, False))
        self.assertLessEqual(len(fetched), 21, 'comments are fetched as pages are asked for, not all at once')
        self.assertEqual(StubYDL.made[-1].opts['extractor_args'],
                         {'youtube': {'max_comments': ['all', 'all', '0', '0'], 'comment_sort': ['top']}})
        self.assertEqual(StubYDL.made[-1].calls, [], 'no player requests: comments only need the watch page')
        second = worker.more_op({'cursor': first['cursor'], 'n': 20})
        self.assertEqual([c['id'] for c in second['comments']], [f'c{i}' for i in range(20, 40)])
        self.assertFalse(second['done'])
        last = worker.more_op({'cursor': first['cursor'], 'n': 20})
        self.assertEqual(([c['id'] for c in last['comments']], last['done']), ([f'c{i}' for i in range(40, 45)], True))
        self.assertEqual(len(worker.CURSORS), 0)

    def test_replies_are_fetched_only_when_asked_for_ten_at_a_time(self):
        StubYDL.comments = fake_comments(3, replies=lambda i: 25 if i == 1 else 0)
        first = worker.comments_op({'id': 'a' * 11, 'n': 20})
        self.assertEqual([(c['id'], c['has_replies'], c['reply_count']) for c in first['comments']],
                         [('c0', False, None), ('c1', True, 25), ('c2', False, None)])
        self.assertTrue(first['done'])
        self.assertEqual(StubIE.replies, {}, 'no replies fetched with the page')
        cursor = first['cursor']
        self.assertIsNotNone(cursor, 'kept open for the replies')
        page1 = worker.replies_op({'cursor': cursor, 'id': 'c1'})
        self.assertEqual(([r['id'] for r in page1['replies']], page1['done']), ([f'c1.{j}' for j in range(10)], False))
        self.assertEqual(StubIE.replies, {'c1': 10})
        page2 = worker.replies_op({'cursor': cursor, 'id': 'c1', 'n': 100})
        self.assertEqual((len(page2['replies']), page2['done']), (15, True))
        with self.assertRaisesRegex(ValueError, 'no more replies'):
            worker.replies_op({'cursor': cursor, 'id': 'c1'})
        with self.assertRaisesRegex(ValueError, 'no more replies'):
            worker.replies_op({'cursor': cursor, 'id': 'c0'})
        with self.assertRaisesRegex(ValueError, 'cursor expired'):
            worker.replies_op({'cursor': cursor + 1, 'id': 'c1'})

    def test_comments_reuse_the_watch_page_the_playlists_op_fetched(self):
        StubYDL.comments = fake_comments(1)
        worker.playlists_op({'id': 'a' * 11})
        worker.comments_op({'id': 'a' * 11})
        worker.comments_op({'id': 'b' * 11})
        self.assertEqual(StubIE.pages, ['a' * 11, 'b' * 11])

    def test_comments_switched_off_by_the_uploader_are_an_empty_page(self):
        def disabled(ie):
            raise StubIE.CommentsDisabled()
            yield
        StubYDL.comments = disabled
        out = worker.comments_op({'id': 'a' * 11})
        self.assertEqual((out['comments'], out['done'], out['cursor']), ([], True, None))
        self.assertEqual(StubYDL.closed, 1)

    def test_related_videos_reads_the_watch_pages_suggestions(self):
        def lockup(vid, title, channel, cid, duration, views, kind='LOCKUP_CONTENT_TYPE_VIDEO'):
            return {'lockupViewModel': {
                'contentId': vid, 'contentType': kind,
                'contentImage': {'thumbnailViewModel': {'overlays': [{'thumbnailBottomOverlayViewModel': {
                    'badges': [{'thumbnailBadgeViewModel': {'text': duration}}]}}]}},
                'metadata': {'lockupMetadataViewModel': {
                    'title': {'content': title},
                    'image': {'decoratedAvatarViewModel': {'rendererContext': {'commandContext': {'onTap': {
                        'innertubeCommand': {'browseEndpoint': {'browseId': cid}}}}}}},
                    'metadata': {'contentMetadataViewModel': {'metadataRows': [
                        {'metadataParts': [{'text': {'content': channel}}]},
                        {'metadataParts': [{'text': {'content': views}}, {'text': {'content': '6mo ago'}}]}]}}}}}}
        data = {'contents': {'twoColumnWatchNextResults': {'secondaryResults': {'secondaryResults': {'results': [
            {'itemSectionRenderer': {'contents': [
                lockup('b' * 11, 'Lecture 2', 'Stanford Online', CHANNEL, '1:17:25', '82K'),
                lockup('PL' + 'x' * 32, 'A playlist', 'Stanford Online', CHANNEL, '', '', 'LOCKUP_CONTENT_TYPE_PLAYLIST'),
                lockup('c' * 11, 'Short one', 'Someone', 'not-a-channel', '0:59', '1.2M'),
                lockup('b' * 11, 'Lecture 2 again', 'Stanford Online', CHANNEL, '1:17:25', '82K'),
                lockup('bad', 'Bad id', 'X', CHANNEL, '1:00', '1'),
                {'continuationItemRenderer': {}}]}}]}}}}}
        self.assertEqual(worker.related_videos(data), [
            {'kind': 'video', 'id': 'b' * 11, 'title': 'Lecture 2', 'channel': 'Stanford Online', 'channel_id': CHANNEL,
             'duration': 4645, 'views': 82000, 'thumbnail': None, 'count': None},
            {'kind': 'video', 'id': 'c' * 11, 'title': 'Short one', 'channel': 'Someone', 'channel_id': None,
             'duration': 59, 'views': 1200000, 'thumbnail': None, 'count': None}])
        self.assertEqual(worker.related_videos({}), [])

    def test_related_op_shares_the_watch_page(self):
        with self.assertRaisesRegex(ValueError, 'invalid video id'):
            worker.related_op({'id': 'nope'})
        worker.playlists_op({'id': 'a' * 11})
        self.assertEqual(worker.related_op({'id': 'a' * 11}), {'videos': []})
        self.assertEqual(StubIE.pages, ['a' * 11])

    def test_channel_playlists_keeps_the_owners_playlists(self):
        def browse(cid):
            return {'browseEndpoint': {'browseId': cid}}
        def lockup(pid, owner):
            return {'lockupViewModel': {
                'contentId': pid, 'contentType': 'LOCKUP_CONTENT_TYPE_PLAYLIST',
                'metadata': {'lockupMetadataViewModel': {'title': {'content': 'L ' + pid}, 'metadata': {
                    'contentMetadataViewModel': {'metadataRows': [{'metadataParts': [
                        {'text': {'content': 'Owner', 'commandRuns': [{'onTap': {'innertubeCommand': browse(owner)}}]}}]}]}}}}}}
        other = 'UC' + 'c' * 22
        course, mix, foreign = 'PL' + 'a' * 32, 'RD' + 'b' * 11, 'PL' + 'f' * 32
        data = {
            'contents': {'twoColumnWatchNextResults': {
                'results': {'results': {'contents': [
                    {'videoPrimaryInfoRenderer': {}},
                    {'videoSecondaryInfoRenderer': {'owner': {'videoOwnerRenderer': {'navigationEndpoint': browse(CHANNEL)}}}}]}},
                'secondaryResults': {'secondaryResults': {'results': [{'itemSectionRenderer': {'contents': [
                    lockup(foreign, other), lockup(course, CHANNEL), lockup(mix, CHANNEL),
                    {'lockupViewModel': {'contentId': 'x' * 11, 'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO'}}]}}]}}}},
            'playerOverlays': {'playerOverlayRenderer': {'endScreen': {'watchNextEndScreenRenderer': {'results': [
                {'endScreenPlaylistRenderer': {'playlistId': course, 'title': {'simpleText': 'Course'}, 'videoCount': '18',
                                               'longBylineText': {'runs': [{'navigationEndpoint': browse(CHANNEL)}]}}},
                {'endScreenPlaylistRenderer': {'playlistId': foreign, 'title': {'simpleText': 'Theirs'},
                                               'longBylineText': {'runs': [{'navigationEndpoint': browse(other)}]}}},
                {'endScreenVideoRenderer': {'videoId': 'y' * 11}}]}}}}}
        self.assertEqual(worker.channel_playlists(data), [{'id': course, 'title': 'Course'}])
        self.assertEqual(worker.channel_playlists({}), [])

    def test_playlists_op_rejects_a_bad_id(self):
        with self.assertRaises(ValueError):
            worker.playlists_op({'id': 'nope'})

    def test_clean_description_drops_links_timestamps_and_social_lines(self):
        text = 'Intro 0:00\nhttps://x.y/z\nFollow me on Instagram\nA lecture on attention.\n#ai'
        self.assertEqual(worker.clean_description(text), 'Intro A lecture on attention.')
        self.assertEqual(len(worker.clean_description('word ' * 500)), 600)
        self.assertEqual(worker.clean_description(None), '')

    def test_descriptions_op_paces_and_stops_at_a_bot_check(self):
        a, b, c = 'a' * 11, 'b' * 11, 'c' * 11
        def player(ie, pattern, page, name, vid, default=None):
            if vid == b:
                raise Exception("Sign in to confirm you're not a bot")
            return {'videoDetails': {'shortDescription': f'About {vid}\nhttps://link'}}
        with unittest.mock.patch.object(StubIE, '_search_json', player, create=True), \
                unittest.mock.patch.object(worker.time, 'sleep') as sleep:
            out = worker.descriptions_op({'ids': [a, b, c]})
        self.assertEqual(out, {'descriptions': {a: f'About {a}'}, 'stopped': True})
        sleep.assert_called_once_with(1.0)
        self.assertEqual(StubIE.pages, [a, b])

    def test_descriptions_op_reads_the_secondary_info_and_keeps_empty_ones(self):
        a, b = 'a' * 11, 'b' * 11
        def player(ie, pattern, page, name, vid, default=None):
            return {} if vid == a else {'videoDetails': {'shortDescription': ''}}
        def initial(ie, vid, page):
            return {'contents': {'twoColumnWatchNextResults': {'results': {'results': {'contents': [
                {'videoSecondaryInfoRenderer': {'attributedDescription': {'content': 'From the page'}}}]}}}}}
        with unittest.mock.patch.object(StubIE, '_search_json', player, create=True), \
                unittest.mock.patch.object(StubIE, 'extract_yt_initial_data', initial), \
                unittest.mock.patch.object(worker.time, 'sleep'):
            out = worker.descriptions_op({'ids': [a, b]})
        self.assertEqual(out, {'descriptions': {a: 'From the page', b: ''}, 'stopped': False})

    def test_descriptions_op_rejects_bad_ids_and_more_than_60(self):
        with self.assertRaises(ValueError):
            worker.descriptions_op({'ids': ['nope']})
        with self.assertRaises(ValueError):
            worker.descriptions_op({'ids': ['a' * 11] * 61})
        with self.assertRaises(ValueError):
            worker.descriptions_op({'ids': 'a' * 11})

if __name__ == '__main__':
    unittest.main()
