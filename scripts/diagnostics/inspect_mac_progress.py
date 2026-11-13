"""Fetch the current Mac log on GitHub's network and preserve a bounded tail."""
import collections
import json
import os
from pathlib import Path
import re
import subprocess
import time
import zipfile

repo = os.environ['GITHUB_REPOSITORY']
job_id = os.environ.get('INSPECT_JOB_ID') or '132171378942'
expected = os.environ.get('INSPECT_EXPECTED_SHA') or '413e929f02e89fe983fe81362f1badf0ad3c254f'
assert job_id.isdecimal() and re.fullmatch(r'[0-9a-f]{40}', expected)

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/'+repo+path]))

job = api('/actions/jobs/'+job_id)
run = api('/actions/runs/'+str(job['run_id']))
assert run['head_sha'] == expected, 'Unexpected source SHA'
Path('mac-job.json').write_text(json.dumps(job, indent=2))
if job['status'] in ('queued', 'waiting', 'pending'):
    summary = {'job_id': job_id, 'source_sha': expected, 'job_status': job['status'],
               'job_conclusion': job.get('conclusion'), 'log_not_available_yet': True}
    Path('mac-progress.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))
    raise SystemExit(0)
with Path('mac-live.log').open('wb') as out:
    result = subprocess.run(['gh', 'api', '--allow-escape-sequences', '-H', 'Cache-Control: no-cache',
                             'repos/'+repo+'/actions/jobs/'+job_id+'/logs?openminis_observed='+str(time.time_ns())],
                            stdout=out, stderr=subprocess.PIPE)
if result.returncode:
    message = result.stderr.decode(errors='replace')
    message = re.sub(r'https?://[^\s"\']+', '[redirect URL]', message)[:3000]
    with Path('mac-run-logs.zip').open('wb') as out:
        fallback = subprocess.run(['gh','api','--allow-escape-sequences','repos/'+repo+'/actions/runs/'+str(job['run_id'])+'/logs'],
                                  stdout=out,stderr=subprocess.PIPE)
    if fallback.returncode == 0:
        with zipfile.ZipFile('mac-run-logs.zip') as archive:
            names = [n for n in archive.namelist() if 'ui-tests' in n and n.endswith('.txt')]
            if names:
                Path('mac-live.log').write_bytes(b'\n'.join(archive.read(n) for n in names))
                result = subprocess.CompletedProcess(result.args, 0)
    if result.returncode:
        fallback_message = re.sub(r'https?://[^\s"\']+', '[redirect URL]',fallback.stderr.decode(errors='replace'))[:3000]
        Path('mac-progress.json').write_text(json.dumps({'job_id':job_id,'source_sha':expected,
            'status':job['status'],'log_download_failed':True,'exit_code':result.returncode,
            'job_log_error':message,'run_log_error':fallback_message},indent=2))
        print(message)
        print(fallback_message)
        if job['status'] != 'completed' and '404' in message:
            print('Live log has not been published yet; this is not a test result.')
            raise SystemExit(0)
        raise SystemExit('Could not retrieve current logs; exact API errors were preserved')

path = Path('mac-live.log')
# A live job's plain-log redirect can lag while its per-step run archive
# already has newer blocks. Read both without touching the running Mac.
with Path('mac-run-progress.zip').open('wb') as out:
    archive_result = subprocess.run(['gh', 'api', '--allow-escape-sequences',
        'repos/'+repo+'/actions/runs/'+str(job['run_id'])+'/logs'], stdout=out, stderr=subprocess.PIPE)
def last_stamp(value):
    stamps = re.findall(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', value, re.M)
    return max(stamps, default='')
log_source = 'job'
if archive_result.returncode == 0 and zipfile.is_zipfile('mac-run-progress.zip'):
    with zipfile.ZipFile('mac-run-progress.zip') as archive:
        names = [n for n in archive.namelist() if 'ui-tests' in n and n.endswith('.txt')]
        candidates = [archive.read(n).decode('utf-8-sig', errors='replace') for n in names]
        if candidates:
            joined = '\n'.join(candidates)
            old = path.read_text(encoding='utf-8-sig', errors='replace')
            if last_stamp(joined) > last_stamp(old):
                path.write_text(joined)
                log_source = 'run archive'
print('Log source:', log_source, '; run archive available:', archive_result.returncode == 0)
log = path.read_text(encoding='utf-8-sig', errors='replace')
lines = log.splitlines()
Path('mac-live-tail.log').write_text('\n'.join(lines[-180:])[-90000:]+'\n')
markers = [line for line in lines if re.search(r'Test Case|Test case|Test Suite|Testing started|\*\* TEST|SwiftCompile|SwiftEmitModule|(?:^|\s)Ld\s|CodeSign|Touch ',line)]
Path('mac-operation-tail.log').write_text('\n'.join(markers[-60:])+'\n')
results = [line for line in lines if re.search(r'Test [Cc]ase .*\b(passed|failed|skipped)\b',line)]
Path('mac-test-results.log').write_text('\n'.join(results)+'\n')
entry = next((i for i, line in enumerate(lines) if re.search(r'Z\s+OPENMINIS_UI_ENTRY_FAILURE:', line)), None)
if entry is not None:
    Path('mac-entry-failure.log').write_text('\n'.join(lines[entry:entry+250])[:50000]+'\n')
started = [line for line in lines if re.search(r'Test Case .* started|Test case .* started|Testing started',line)]
errors = [line for line in lines if re.search(r'\.swift:\d+:\d+: error:|\*\* TEST FAILED|Testing failed:',line)]
failure_indexes = set()
for index, line in enumerate(lines):
    if re.search(r'error: -\[|XCTAssert.*failed|XCTFail|Assertion Failure|Caught error|failed -|Timed out.*(?:App|application|idle)',line):
        failure_indexes.update(range(max(0,index-7),min(len(lines),index+5)))
Path('mac-failure-context.log').write_text('\n'.join(lines[i] for i in sorted(failure_indexes))[:250000]+'\n')
warning_files = collections.Counter(re.findall(r'/([^/\n]+\.swift):\d+:\d+: warning:',log))
summary = {'job_id':job_id,'source_sha':expected,'job_status':job['status'],'log_source':log_source,
    'job_conclusion':job.get('conclusion'),'log_bytes':path.stat().st_size,
    'first_line':lines[0] if lines else '', 'last_line':lines[-1] if lines else '',
    'test_start_records':len(started),'passed_records':sum(' passed ' in l for l in results),
    'failed_records':sum(' failed ' in l for l in results),
    'last_test_start':started[-1] if started else None,
    'last_test_result':results[-1] if results else None,
    'first_failure_context':[lines[i] for i in sorted(failure_indexes)[:35]],
    'last_operation':markers[-1] if markers else None,
    'compilation_errors':errors[-10:], 'warning_counts':warning_files.most_common(12)}
Path('mac-progress.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
