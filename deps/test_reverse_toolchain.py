#!/usr/bin/env python3
"""Exercise installed runtime tools on real ELF and iOS Mach-O functions."""
import json
import pathlib
import subprocess
import sys
import traceback

ROOT = pathlib.Path('/opt/minis-reverse')
ROOT.mkdir(exist_ok=True)
REPORT = ROOT / 'runtime-tests.log'

def emit(text):
    text = str(text)
    print(text, flush=True)
    with REPORT.open('a') as stream:
        stream.write(text + '\n')

def run(args, name, timeout=90):
    emit('TEST ' + name + ': ' + repr(args))
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    (ROOT / (name + '.stdout')).write_text(p.stdout)
    (ROOT / (name + '.stderr')).write_text(p.stderr)
    emit(p.stdout)
    if p.stderr:
        emit('STDERR: ' + p.stderr)
    if p.returncode:
        raise RuntimeError(name + ' exited ' + str(p.returncode))
    return p.stdout

def r2(path, commands, name):
    return run(['r2', '-q', '-e', 'scr.color=0', '-e', 'bin.relocs.apply=true',
                '-c', 'e r2ghidra.sleighhome=/usr/lib/radare2/5.9.8/r2ghidra_sleigh; ' + commands, str(path)], name)

def decompile(filename, label):
    path = ROOT / filename
    # r2 normalizes Mach-O's leading underscore differently across versions.
    # Resolve the actual function once, then seek by its numeric address.
    raw = r2(path, 'aaa; aflj', label + '-functions')
    functions = json.loads(raw.strip())
    candidates = [f for f in functions if 'test_add' in f.get('name', '')]
    if len(candidates) != 1:
        raise RuntimeError(label + ': expected one test_add function, got ' + repr(candidates))
    offset = int(candidates[0]['offset'])
    emit(label + ': using function ' + candidates[0]['name'] + ' at ' + hex(offset))
    result = r2(path, 'aaa; s ' + hex(offset) + '; pdgj', label + '-decompile')
    decoded = json.loads(result.strip())
    if not isinstance(decoded, dict) or decoded.get('errors'):
        raise RuntimeError(label + ': decompiler errors: ' + repr(decoded))
    code = decoded.get('code', '')
    if not isinstance(code, str) or 'return' not in code or len(code.strip()) < 25:
        raise RuntimeError(label + ': missing real pseudo-C output: ' + repr(decoded))
    emit('PASS ' + label + ': real function decompiled')

def main():
    emit('=== Runtime smoke test: ' + ' '.join(sys.argv[1:]) + ' ===')
    run(['r2', '-v'], 'r2-version')
    run(['r2', '-q', '-c', 'Lc', '-'], 'r2-plugins')
    decompile('smoke-elf', 'elf')
    decompile('smoke-macho', 'macho')
    detected = run(['file', str(ROOT / 'smoke-macho')], 'file-macho')
    assert 'Mach-O' in detected, detected
    symbols = run(['/usr/lib/llvm19/bin/llvm-nm', str(ROOT / 'smoke-macho')], 'llvm-nm')
    assert '_test_add' in symbols, symbols
    run(['/usr/lib/llvm19/bin/llvm-objdump', '--section-headers', str(ROOT / 'smoke-macho')], 'llvm-objdump')
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    assert list(md.disasm(bytes.fromhex('c0035fd6'), 0))[0].mnemonic == 'ret'
    emit('PASS capstone ' + capstone.__version__)
    assert run(['sqlite3', ':memory:', 'select 6*7;'], 'sqlite').strip() == '42'
    emit('TOOLCHAIN_SMOKE_TESTS_PASSED')

if __name__ == '__main__':
    try:
        main()
    except Exception:
        emit(traceback.format_exc())
        sys.exit(1)
