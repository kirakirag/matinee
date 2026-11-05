"""Throwaway: resolve YouTube video IDs (one per stdin line) to stream URLs, timing each."""
import json
import re
import sys
import time
from urllib.parse import parse_qs, urlparse

import yt_dlp
import yt_dlp.globals

ID_RE = re.compile(r'^[A-Za-z0-9_-]{11}$')

yt_dlp.globals.plugin_dirs.value = []
OPTS = {
    'quiet': True,
    'no_warnings': True,
    'skip_download': True,
    'format': 'bv*[height<=1080]+ba/b',
    'js_runtimes': {'deno': {}},
    'verbose': '-v' in sys.argv,
}


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


if arg('--client'):  # e.g. visionos
    OPTS['extractor_args'] = {'youtube': {'player_client': arg('--client').split(',')}}
if arg('--sort'):  # e.g. vcodec:vp9
    OPTS['format_sort'] = arg('--sort').split(',')


def expire_of(url):
    try:
        return int(parse_qs(urlparse(url).query).get('expire', ['0'])[0])
    except ValueError:
        return 0


def main():
    with yt_dlp.YoutubeDL(OPTS) as ydl:
        if '--ready' in sys.argv:
            print(json.dumps({'ready': True}), flush=True)
        for line in sys.stdin:
            vid = line.strip()
            if not vid:
                continue
            out = {'id': vid, 'ms': 0, 'video_url': None, 'audio_url': None, 'height': 0,
                   'vcodec': None, 'acodec': None, 'expire': 0, 'headers': {}, 'client': None, 'available_at': 0, 'error': None}
            t0 = time.perf_counter()
            try:
                if not ID_RE.match(vid):
                    raise ValueError('invalid video id')
                info = ydl.extract_info(f'https://www.youtube.com/watch?v={vid}', download=False)
                fmts = info.get('requested_formats') or [info]
                video = next((f for f in fmts if f.get('vcodec') not in (None, 'none')), fmts[0])
                audio = next((f for f in fmts if f.get('vcodec') in (None, 'none')), None)
                out.update(video_url=video['url'], audio_url=audio['url'] if audio else None,
                           height=video.get('height') or 0, vcodec=video.get('vcodec'),
                           acodec=(audio or video).get('acodec'), expire=expire_of(video['url']),
                           headers=video.get('http_headers') or {},
                           available_at=max((f.get('available_at') or 0) for f in fmts),
                           client=parse_qs(urlparse(video['url']).query).get('c', [None])[0])
            except Exception as e:  # noqa: BLE001 - spike: report and continue
                out['error'] = str(e)[:300]
            out['ms'] = round((time.perf_counter() - t0) * 1000)
            print(json.dumps(out), flush=True)


if __name__ == '__main__':
    main()
