#!/usr/bin/env python3
"""Run real serial RAW benchmarks; never launches the app or modifies photos.

Requires macOS/Xcode, LUMIBASE_INTERACTIVE_RAW and an explicit scratch output root.
Use --baseline-ref to compare against an archived commit with the identical sweep.
"""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tarfile


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New scratch directory (must not exist)')
    parser.add_argument('--baseline-ref', help='Optional local git commit for the baseline')
    parser.add_argument('--summarize', nargs=2, type=Path, metavar=('BEFORE', 'AFTER'), help='Only validate and summarize existing JSON files')
    args = parser.parse_args()
    if args.summarize:
        print(summarize(*args.summarize))
        return
    source = Path(__file__).resolve().parents[1]
    raw = os.environ.get('LUMIBASE_INTERACTIVE_RAW')
    if not raw or not Path(raw).is_file():
        parser.error('LUMIBASE_INTERACTIVE_RAW must name an existing read-only RAW fixture')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    for name in ['tmp', 'modules', 'home', 'artifacts']:
        (output / name).mkdir()
    env.update(TMPDIR=str(output / 'tmp'), CLANG_MODULE_CACHE_PATH=str(output / 'modules'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / 'modules'), CFFIXED_USER_HOME=str(output / 'home'),
               LUMIBASE_TEST_OUTPUT=str(output / 'artifacts'))
    targets = []
    if args.baseline_ref:
        commit = subprocess.check_output(['git', 'rev-parse', '--verify', args.baseline_ref + '^{commit}'], cwd=source, text=True).strip()
        archive = subprocess.check_output(['git', 'archive', commit], cwd=source)
        baseline = output / 'baseline-source'
        baseline.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            # Python 3.9/macOS compatibility: reject links and traversal instead
            # of relying on the newer extractall(filter='data') API.
            for member in tar.getmembers():
                if not (member.isfile() or member.isdir()) or not (baseline / member.name).resolve().is_relative_to(baseline):
                    raise ValueError('Unsafe archive member: ' + member.name)
            tar.extractall(baseline)
        shutil.copy2(source / 'Tests/LumiBaseTests/InteractiveEditingBenchmarkTests.swift', baseline / 'Tests/LumiBaseTests/')
        targets.append(('before', baseline, 'InteractiveEditingBenchmarkTests'))
    targets.append(('after', source, 'InteractiveEditingBenchmarkTests|InteractiveBurstBenchmarkTests'))
    for label, checkout, tests in targets:
        env['LUMIBASE_INTERACTIVE_RESULTS'] = str(output / (label + '.json'))
        env['LUMIBASE_BURST_RESULTS'] = str(output / 'burst.json')
        argv = ['swift', 'test', '-c', 'release', '--disable-sandbox', '--scratch-path', str(output / ('build-' + label)), '--filter', tests]
        with (output / (label + '.log')).open('w') as log:
            subprocess.run(argv, cwd=checkout, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    if args.baseline_ref:
        text = summarize(output / 'before.json', output / 'after.json')
        (output / 'summary.md').write_text(text)
        print(text)
    print('Evidence:', output)


def summarize(before, after):
    data = [json.loads(path.read_text()) for path in [before, after]]
    fields = ['exposure', 'contrast', 'highlights', 'shadows', 'whites', 'blacks', 'texture', 'clarity', 'dehaze', 'vibrance', 'saturation', 'temperature', 'tint']
    expected = {(trial, highlight, mode, field) for trial in range(3) for highlight in [0, -80] for mode in ['Fit', 'ROI'] for field in fields}
    for rows in data:
        keys = [(row['trial'], row['highlights'], row['mode'], row['parameter']) for row in rows]
        if len(keys) != len(expected) or set(keys) != expected:
            raise ValueError('Incomplete/duplicate sweep; require 156 unique measurements')
    lines = ['Median production API→raster milliseconds (NOT GUI event→present).',
             '|Control|H0 Fit before→after|H0 ROI before→after|H−80 Fit before→after|H−80 ROI before→after|',
             '|---|---:|---:|---:|---:|']
    for field in fields:
        cells = []
        for highlights in [0, -80]:
            for mode in ['Fit', 'ROI']:
                values = [statistics.median(row['totalMs'] for row in rows if row['parameter'] == field and row['highlights'] == highlights and row['mode'] == mode) for rows in data]
                cells.append('→'.join(f'{value:.1f}' for value in values))
        lines.append('|' + field + '|' + '|'.join(cells) + '|')
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    run()
