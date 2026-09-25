"""Run portable reference/source checks and record an honest, machine-readable report.

Usage: python3 scripts/run_regressions.py
Requires numpy. This does not compile Swift or execute camera/PhotoKit APIs.
"""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'validation'
REPORTS.mkdir(exist_ok=True)
results = []
with (REPORTS / 'portable-tests.log').open('w', encoding='utf-8') as log:
    for name in ['validate_tracking_geometry', 'validate_tracking_stability',
                 'validate_local_framing', 'validate_super_resolution']:
        spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromModule(module))
        results.append({'suite': name, 'run': result.testsRun,
                        'passed': result.testsRun - len(result.failures) - len(result.errors) - len(result.skipped),
                        'failures': len(result.failures), 'errors': len(result.errors),
                        'skipped': [{'test': str(test), 'reason': reason} for test, reason in result.skipped],
                        'metrics': getattr(module, 'METRICS', {})})
    replay = subprocess.run([sys.executable, str(ROOT / 'scripts/validate_patch_flow_reference.py')],
                            capture_output=True, text=True)
    log.write(replay.stdout + replay.stderr)
report = {'scope': 'Python numerical reference scenarios and Swift source contracts only',
          'ios_compiled': False, 'device_tested': False, 'swift_xctest_run': False,
          'suites': results, 'patch_flow_replay_exit_code': replay.returncode,
          'patch_flow_replay': json.loads(replay.stdout) if replay.returncode == 0 else replay.stderr}
(REPORTS / 'portable-results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'run': sum(r['run'] for r in results), 'passed': sum(r['passed'] for r in results),
                  'skipped': sum(len(r['skipped']) for r in results),
                  'failures': sum(r['failures'] + r['errors'] for r in results),
                  'patch_flow_replay_exit_code': replay.returncode}))
raise SystemExit(int(any(r['failures'] or r['errors'] for r in results) or replay.returncode != 0))
