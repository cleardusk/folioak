"""Test-only fixture: exercise the frozen downloader's real QuickJS provider."""
import json
import os
from pathlib import Path

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.extractor.youtube.jsc._builtin.quickjs import QuickJSJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeRequest, JsChallengeType, NChallengeInput, SigChallengeInput,
)


class Logger:
    def debug(self, *_): pass
    def info(self, *_): pass
    def warning(self, message, **_): raise AssertionError(message)


class LeafpickEJSIE(InfoExtractor):
    _VALID_URL = r'leafpick-ejs:(?P<id>fixture)'

    def _real_extract(self, url):
        provider = QuickJSJCP(self, Logger(), {})
        assert provider.is_available(), 'Bundled QuickJS provider unavailable'
        signature = ('NJAJEij0EwRgIhAI0KExTgjfPk-MPM9MAdzyyPRt=BM8-XO5tm5hlMCSVpAiEAv7eP3CURqZNSPow8BXXAoazVoXgeMP7gH9BdylHCwgw=gwzz')
        inputs = ['IlLiA21ny7gqA2m4p37', 'eabGFpsUKuWHXGh6FR4', 'eabGF/ps%UK=uWHXGh6FR4']
        requests = [JsChallengeRequest(JsChallengeType.N, NChallengeInput('fixture', inputs)),
                    JsChallengeRequest(JsChallengeType.SIG, SigChallengeInput('fixture', [signature]))]
        if player_path := os.environ.get('LEAFPICK_EJS_PLAYER'):
            # Optional live validation: upstream EJS 0.8.0 player 74edf1a3 fixtures.
            player = Path(player_path).read_text()
            self._load_player = lambda **_: player
            responses = list(provider.bulk_solve(requests))
            assert all(response.response and not response.error for response in responses), responses
            actual = [response.response.output.results for response in responses]
            expected = [dict(zip(inputs, ['9nRTxrbM1f0yHg', 'izmYqDEY6kl7Sg', 'LACmqlhaBpiPlgE-a'])),
                        {signature: signature.replace('hlMCSV', 'hzMCSV')[:-1] + 'l'}]
        else:
            # Synthetic preprocessed player keeps regular CI entirely offline.
            script = provider._construct_stdin(
                '_result.n = s => s.split("").reverse().join(""); _result.sig = s => s.slice(2);',
                True, requests)
            result = json.loads(provider._run_js_runtime(script))
            actual = [response['data'] for response in result['responses']]
            expected = [{value: value[::-1] for value in inputs}, {signature: signature[2:]}]
        assert actual == expected, (actual, expected)
        return {'id': 'fixture', 'title': 'EJS provider passed', 'ext': 'mp4',
                'url': 'https://example.invalid/offline.mp4'}
