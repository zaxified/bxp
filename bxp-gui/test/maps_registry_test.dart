// Unit tests for the drill-down `maps` registry helpers in trace_store.dart.
//
// These back the fix that makes GUI drill-down re-eval resolve REMAP/REPLACE
// `'name'` refs into the GLOBAL top-level `maps` registry, not just the
// template-local block (the global half is fetched via `loadConfig`, which
// returns the config annotated with `$comm_*`/`$err_*` siblings — hence the
// annotation-key filter — and merged under the template-local block with
// engine "template-local wins wholesale" precedence).

import 'package:bxp_gui/store/trace_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseMapsRegistry', () {
    test('builds the {name: {k: v}} shape and stringifies values', () {
      final out = parseMapsRegistry({
        'tickers': {'VOW.DE': 'VOW.DE.XETRA', 'AGNC': 'AGNC.NASDAQ'},
        'nums': {'a': 1, 'b': true},
      });
      expect(out, {
        'tickers': {'VOW.DE': 'VOW.DE.XETRA', 'AGNC': 'AGNC.NASDAQ'},
        'nums': {'a': '1', 'b': 'true'},
      });
    });

    test('skips \$-prefixed annotation keys at both levels', () {
      // The annotated loadConfig tree interleaves `$comm_*`/`$err_*` siblings
      // next to real entries; they must not leak into the resolved maps.
      final out = parseMapsRegistry({
        '\$comm_1': 'a note about the maps block',
        'tickers': {
          '\$comm_1': 'inline note',
          'VOW.DE': 'VOW.DE.XETRA',
        },
      });
      expect(out, {
        'tickers': {'VOW.DE': 'VOW.DE.XETRA'},
      });
    });

    test('ignores non-object map entries', () {
      final out = parseMapsRegistry({
        'good': {'k': 'v'},
        'bogus': 'not-an-object',
      });
      expect(out, {
        'good': {'k': 'v'},
      });
    });
  });

  group('mergeMapsRegistries', () {
    final global = {
      'tickers': {'VOW.DE': 'VOW.DE.XETRA'},
      'currencies': {'CZK': 'Kč'},
    };

    test('empty global returns the local registry unchanged', () {
      final local = {
        'tickers': {'X': 'Y'}
      };
      expect(mergeMapsRegistries(const {}, local), same(local));
    });

    test('global-only names survive and local-only names are added', () {
      final out = mergeMapsRegistries(global, {
        'extra': {'P': 'Q'}
      });
      expect(out['currencies'], {'CZK': 'Kč'});
      expect(out['extra'], {'P': 'Q'});
    });

    test('a template-local block overrides a same-named global one WHOLESALE',
        () {
      // Local `tickers` has a different key — the global key must NOT survive
      // (engine replaces the whole named map, it does not merge key-by-key).
      final out = mergeMapsRegistries(global, {
        'tickers': {'AAPL': 'AAPL.NASDAQ'}
      });
      expect(out['tickers'], {'AAPL': 'AAPL.NASDAQ'});
      expect(out['tickers']!.containsKey('VOW.DE'), isFalse);
      // Untouched global entry is still present.
      expect(out['currencies'], {'CZK': 'Kč'});
    });
  });
}
