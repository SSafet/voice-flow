"""Compare startup eligibility and starvation on the same saved API responses."""
import argparse
import json
import statistics


def compare(trace):
    first = trace[0][0]
    def threshold(size):
        return next(t for t, count in trace if count >= size)
    old = threshold(24000)
    guarded = min(old, max(first + 220, threshold(9600)))
    def gaps(start):
        available = 0
        previous = 0
        last = start
        result = []
        for at, size in trace:
            if at < start:
                available, previous = size / 48, size
                continue
            elapsed = at - last
            if elapsed > available + 20 and previous:
                result.append(elapsed - available)
            available = max(0, available - elapsed) + (size - previous) / 48
            previous, last = size, at
        return result
    return dict(old_start_ms=old, guarded_start_ms=guarded, saving_ms=old-guarded,
                guarded_starvations=gaps(guarded), old_starvations=gaps(old))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input'); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with open(args.input) as source:
        rows = [compare(r['trace']) for r in json.load(source)['runs']]
    result = dict(kind='replay of identical live PCM arrival traces, not acoustic measurement',
                  policy='200ms audio plus 220ms arrival grace, or 500ms audio', runs=rows,
                  median_saving_ms=statistics.median(r['saving_ms'] for r in rows))
    with open(args.output, 'w') as output:
        json.dump(result, output, indent=2); output.write('\n')
    assert all(not row['guarded_starvations'] for row in rows), 'startup candidate starves on collected audio'
    print(f"PASS live trace replay: {result['median_saving_ms']:.1f} ms median saving, no >20ms starvation")


if __name__ == '__main__':
    main()
