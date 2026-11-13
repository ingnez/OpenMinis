"""Fetch the current Mac log on GitHub's network and preserve a bounded tail."""
import collections
import json
import os
from pathlib import Path
import re
import subprocess

repo = os.environ['GITHUB_REPOSITORY']
job_id = '131892608182'
expected = 'a5a2b7c9230026e5df6f9d6a77eafba306f99977'

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/'+repo+path]))

job = api('/actions/jobs/'+job_id)
run = api('/actions/runs/'+str(job['run_id']))
assert run['head_sha'] == expected, 'Unexpected source SHA'
Path('mac-job.json').write_text(json.dumps(job, indent=2))
with Path('mac-live.log').open('wb') as out:
    result = subprocess.run(['gh', 'api', 'repos/'+repo+'/actions/jobs/'+job_id+'/logs'],
                            stdout=out, stderr=subprocess.PIPE)
if result.returncode:
    Path('mac-progress.json').write_text(json.dumps({'job_id':job_id,'source_sha':expected,
        'status':job['status'],'log_download_failed':True,'exit_code':result.returncode},indent=2))
    raise SystemExit('Could not retrieve Mac log; metadata was preserved')

path = Path('mac-live.log')
log = path.read_text(encoding='utf-8-sig', errors='replace')
lines = log.splitlines()
Path('mac-live-tail.log').write_text('\n'.join(lines[-180:])[-90000:]+'\n')
markers = [line for line in lines if re.search(r'Test Case|Test case|Test Suite|Testing started|\*\* TEST|SwiftCompile|SwiftEmitModule|(?:^|\s)Ld\s|CodeSign|Touch ',line)]
Path('mac-operation-tail.log').write_text('\n'.join(markers[-60:])+'\n')
results = [line for line in lines if re.search(r'Test [Cc]ase .*\b(passed|failed|skipped)\b',line)]
Path('mac-test-results.log').write_text('\n'.join(results)+'\n')
started = [line for line in lines if re.search(r'Test Case .* started|Test case .* started|Testing started',line)]
errors = [line for line in lines if re.search(r'\.swift:\d+:\d+: error:|\*\* TEST FAILED|Testing failed:',line)]
warning_files = collections.Counter(re.findall(r'/([^/\n]+\.swift):\d+:\d+: warning:',log))
summary = {'job_id':job_id,'source_sha':expected,'job_status':job['status'],
    'job_conclusion':job.get('conclusion'),'log_bytes':path.stat().st_size,
    'first_line':lines[0] if lines else '', 'last_line':lines[-1] if lines else '',
    'test_start_records':len(started),'passed_records':sum(' passed ' in l for l in results),
    'failed_records':sum(' failed ' in l for l in results),
    'last_test_start':started[-1] if started else None,
    'last_test_result':results[-1] if results else None,
    'last_operation':markers[-1] if markers else None,
    'compilation_errors':errors[-10:], 'warning_counts':warning_files.most_common(12)}
Path('mac-progress.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
