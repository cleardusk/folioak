"""Test-only probe of the extractors shipped in the frozen downloader."""
import json
import os

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.extractor.xiaohongshu import XiaoHongShuIE
from yt_dlp.extractor.tiktok import DouyinIE, TikTokIE, TikTokVMIE
from yt_dlp.extractor.instagram import InstagramIE
from yt_dlp.extractor.vimeo import VimeoIE


class FolioakSitesIE(InfoExtractor):
    _VALID_URL = r'folioak-sites:(?P<id>fixture)'

    def _real_extract(self, url):
        note_id = '674051740000000007027a15'
        note_url = f'https://www.xiaohongshu.com/explore/{note_id}?xsec_token=fixture'
        for extractor, sample in [
            (XiaoHongShuIE, note_url),
            (XiaoHongShuIE, f'https://www.xiaohongshu.com/discovery/item/{note_id}'),
            (DouyinIE, 'https://www.douyin.com/video/6961737553342991651'),
            (TikTokIE, 'https://www.tiktok.com/@demo/video/6748451240264420610'),
            (TikTokVMIE, 'https://vm.tiktok.com/ZTR45GpSF/'),
            (TikTokVMIE, 'https://www.tiktok.com/t/ZTRC5xgJp'),
            (InstagramIE, 'https://www.instagram.com/reel/ABC_123-/'),
            (InstagramIE, 'https://www.instagram.com/p/aye83DjauH/'),
            (VimeoIE, 'https://vimeo.com/76979871'),
            (VimeoIE, 'https://player.vimeo.com/video/76979871'),
        ]:
            assert extractor.suitable(sample), (extractor.__name__, sample)

        # Only the network response is replaced. The bundled Xiaohongshu parser,
        # format selection and subsequent file transfer run unmodified.
        note = {
            'title': '小红书 offline video', 'desc': 'Offline extraction fixture',
            'user': {'userId': 'fixture'},
            'video': {'media': {'stream': {'h264': [{
                'masterUrl': os.environ['FOLIOAK_SITE_VIDEO'],
                'width': 16, 'height': 16, 'fps': 25, 'duration': 250,
                'videoBitrate': 128000, 'audioBitrate': 0,
                'videoCodec': 'h264', 'audioCodec': 'none',
            }]}}},
        }
        webpage = '<script>window.__INITIAL_STATE__=' + json.dumps({
            'note': {'noteDetailMap': {note_id: {'note': note}}},
        }) + '</script>'
        extractor = XiaoHongShuIE(self._downloader)
        extractor._download_webpage = lambda *args, **kwargs: webpage
        result = extractor.extract(note_url)
        assert result['id'] == note_id and result['title'] == note['title'], result
        assert result['formats'][0]['width'] == 16 and result['formats'][0]['vbr'] == 128, result
        return result
