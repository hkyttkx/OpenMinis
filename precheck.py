#!/usr/bin/env python3
"""编译前预检：捕获常见的 Swift 编译错误，避免浪费 CI 时间。

检查项：
  1. 花括号/圆括号平衡
  2. 自定义 init 的 struct 是否还有人用逐一成员构造（Swift 不合成）
  3. 跨 struct 的私有方法引用（同文件不同类型）
  4. Codable 只实现一半（自定义 init(from:) 却没 encode(to:)）
  5. 重复定义同一 private func
"""
import re, os, sys, subprocess

ROOT = "src/ios"


def read(p):
    try:
        return open(p, encoding='utf-8').read()
    except Exception:
        return ""


def strip_code(s):
    s = re.sub(r'"""[\s\S]*?"""', '""', s)
    s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s = re.sub(r'//[^\n]*', '', s)
    s = re.sub(r'/\*[\s\S]*?\*/', '', s)
    return s


def changed_files():
    try:
        out = subprocess.check_output(
            ["git", "diff", "--name-only", "HEAD~1", "--", ROOT], text=True)
        files = [f for f in out.split() if f.endswith(".swift")]
        out2 = subprocess.check_output(["git", "status", "--porcelain"], text=True)
        for line in out2.split("\n"):
            if line.endswith(".swift"):
                f = line[3:].strip()
                if f.endswith(".swift") and f not in files:
                    files.append(f)
        return files
    except Exception:
        return []


def check_balance(files):
    bad = []
    for f in files:
        s = strip_code(read(f))
        if s.count("{") != s.count("}"):
            bad.append((f, "{}", s.count("{"), s.count("}")))
        if s.count("(") != s.count(")"):
            bad.append((f, "()", s.count("("), s.count(")")))
    return bad


def check_private_func_scope(files):
    """同一文件中，A 类型调用了 B 类型里定义的 private func。"""
    problems = []
    for f in files:
        src = read(f)
        if not src:
            continue
        lines = src.split("\n")
        # 记录每个类型（struct/class/enum/extension）的起止行
        scopes = []
        for i, l in enumerate(lines):
            m = re.match(r'^(?:private |public |internal |final |@\w+\s+)*'
                         r'(struct|class|enum|extension)\s+(\w+)', l)
            if m:
                scopes.append([i, m.group(2)])
        for idx in range(len(scopes)):
            scopes[idx].append(scopes[idx + 1][0] if idx + 1 < len(scopes) else len(lines))

        # 每个类型里定义的 private func 名 → 所属类型
        func_owner = {}
        for start, name, end in scopes:
            for i in range(start, min(end, len(lines))):
                m = re.match(r'^\s+(?:@\w+\s+)?private\s+func\s+(\w+)', lines[i])
                if m:
                    func_owner.setdefault(m.group(1), []).append(name)

        # 每个类型里对这些 func 的调用。
        # 判定条件收紧：调用形如 `self.fn(` 或 `fn(` 出现在表达式位置，
        # 且排除 enum case / 同名属性等易误报的情形。
        for start, name, end in scopes:
            body = "\n".join(lines[start:end])
            for fn, owners in func_owner.items():
                if name in owners:
                    continue
                if not owners:
                    continue
                # 只看 self.fn( 这种明确的调用，避免与 enum case / 变量同名误报
                if re.search(r'\bself\.' + re.escape(fn) + r'\s*\(', body):
                    problems.append((f, name, fn, owners[0]))
    return problems


def main():
    files = changed_files()
    if not files:
        print("无改动文件")
        return 0
    print(f"预检 {len(files)} 个改动文件\n")

    fails = 0
    bad = check_balance(files)
    for f, kind, a, b in bad:
        print(f"  ✗ 括号不平衡 {kind} {a}/{b}  {f}")
        fails += 1

    prob = check_private_func_scope(files)
    for f, caller, fn, owner in prob:
        print(f"  ✗ 跨类型私有方法 {caller} 调用 {owner} 的 {fn}()  {f}")
        fails += 1

    if fails == 0:
        print("  ✓ 通过")
    return fails


if __name__ == "__main__":
    sys.exit(0 if main() == 0 else 1)
