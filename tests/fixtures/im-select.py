#!/usr/bin/env python3
"""Controllable input-method process for headless integration tests."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ['AUTOIME_TEST_DIR'])
config = json.loads((root / 'config.json').read_text())
if not isinstance(config, dict):
    config = {}
target = sys.argv[1] if len(sys.argv) > 1 else None
kind = 'set' if target is not None else 'query'

def record(event):
    entry = json.dumps({'event': event, 'kind': kind, 'target': target}) + '\n'
    fd = os.open(root / 'events.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, entry.encode())
    finally:
        os.close(fd)

record('start')
blocked = config.get('block_query', False) if kind == 'query' else target in config.get('block_sets', [])
release = root / ('release-query' if kind == 'query' else 'release-' + target)
if blocked:
    deadline = time.monotonic() + 5
    while not release.exists():
        if time.monotonic() > deadline:
            raise SystemExit('fixture gate timed out')
        time.sleep(0.005)
time.sleep(config.get('query_delay_ms' if kind == 'query' else 'set_delay_ms', 0) / 1000)
code = config.get('query_code' if kind == 'query' else 'set_code', 0)
if kind == 'query':
    sys.stdout.write(config.get('query_output', (root / 'ime').read_text()))
    sys.stderr.write(config.get('query_stderr', ''))
else:
    if code == 0 or config.get('write_on_failure', False):
        (root / 'ime').write_text(target + '\n')
    sys.stderr.write(config.get('set_stderr', ''))
record('end')
raise SystemExit(code)
