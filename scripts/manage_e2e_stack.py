#!/usr/bin/env python3
"""管理 CI 假服务，遇到端口冲突先核实进程归属，绝不终止其他服务。"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/e2e_cloud_stack.py'
PORTS = (18765, 18796, 18797, 18799)


def process_identity(pid):
    command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
    if command.returncode or not command.stdout.strip():
        return None
    cwd = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True)
    directory = next((line[1:] for line in cwd.stdout.splitlines() if line.startswith('n')), '')
    return command.stdout.strip(), directory


def owns_stack(identity, root=ROOT):
    if not identity:
        return False
    command, directory = identity
    if not directory or Path(directory).resolve() != root.resolve():
        return False
    try:
        args = shlex.split(command)
    except ValueError:
        return False
    if len(args) < 2 or not Path(args[0]).name.lower().startswith('python'):
        return False
    # 仅接受 Python 执行脚本的形式，拒绝 -c 字符串里碰巧出现文件名。
    index = 1
    if args[index] == '-u':
        index += 1
    if index >= len(args) or args[index].startswith('-'):
        return False
    script = Path(args[index])
    return (Path(directory) / script).resolve() == root.resolve() / 'scripts/e2e_cloud_stack.py'


def listeners():
    pids = set()
    for port in PORTS:
        result = subprocess.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-t'], capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise RuntimeError(f'无法查询测试端口 {port}')
        pids.update(int(value) for value in result.stdout.split() if value.isdigit())
    return pids


def terminate_owned(pid):
    identity = process_identity(pid)
    if identity is None:
        return
    if not owns_stack(identity):
        raise RuntimeError(f'PID {pid} 不属于当前仓库的假服务，拒绝终止')
    print(f'终止当前仓库遗留的假服务 PID {pid}', flush=True)
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process_identity(pid) != identity:
            return
        time.sleep(0.1)
    # 再核对命令和工作目录，防止 PID 已被系统复用。
    if process_identity(pid) == identity:
        os.kill(pid, signal.SIGKILL)


def clean_listeners():
    pids = listeners()
    # 先检查全部，再做任何修改；未知占用者必须显式失败。
    for pid in pids:
        if not owns_stack(process_identity(pid)):
            raise RuntimeError(f'测试端口被未知进程 PID {pid} 占用，未改动该进程')
    for pid in sorted(pids):
        terminate_owned(pid)


def start(work, record, log):
    clean_listeners()
    work.mkdir(parents=True, exist_ok=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w') as output:
        proc = subprocess.Popen([sys.executable, '-u', str(SCRIPT), str(work)], cwd=ROOT,
                                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({'pid': proc.pid, 'root': str(ROOT), 'work': str(work)}))
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        text = log.read_text(errors='replace')
        if proc.poll() is not None:
            raise RuntimeError('假服务启动退出：\n' + text[-5000:])
        if 'E2E 云端就绪' in text:
            print(text, end='')
            return
        time.sleep(0.25)
    terminate_owned(proc.pid)
    raise RuntimeError('假服务未就绪：\n' + log.read_text(errors='replace')[-5000:])


def stop(record):
    if not record.exists():
        return
    data = json.loads(record.read_text())
    if Path(data['root']).resolve() != ROOT:
        raise RuntimeError('PID 记录不属于当前仓库')
    terminate_owned(int(data['pid']))
    record.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop'])
    parser.add_argument('--record', required=True, type=Path)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--log', type=Path, default=Path('e2e-cloud-stack.log'))
    args = parser.parse_args()
    try:
        if args.action == 'start':
            if args.work is None:
                parser.error('start 需要 --work')
            start(args.work.resolve(), args.record.resolve(), args.log.resolve())
        else:
            stop(args.record.resolve())
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
