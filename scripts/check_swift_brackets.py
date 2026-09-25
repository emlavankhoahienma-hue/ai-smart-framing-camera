"""Check balanced Swift delimiters in every application Swift file.

This is a lexical bracket check, not a Swift compiler or type checker.
Comments and string contents are skipped so their punctuation is not code.
"""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
OPEN = {'(': ')', '[': ']', '{': '}'}
CLOSE = set(OPEN.values())


def check(path):
    source = path.read_text(encoding='utf-8')
    stack = []
    index = 0
    line = 1
    column = 1
    comment_depth = 0
    mode = 'code'
    errors = []

    def advance(count):
        nonlocal index, line, column
        for char in source[index:index + count]:
            if char == '\n':
                line += 1
                column = 1
            else:
                column += 1
        index += count

    while index < len(source):
        if mode == 'line_comment':
            if source[index] == '\n':
                mode = 'code'
            advance(1)
            continue
        if mode == 'block_comment':
            if source.startswith('/*', index):
                comment_depth += 1
                advance(2)
            elif source.startswith('*/', index):
                comment_depth -= 1
                advance(2)
                if comment_depth == 0:
                    mode = 'code'
            else:
                advance(1)
            continue
        if mode in ('string', 'multiline'):
            if source[index] == '\\':
                advance(min(2, len(source) - index))
            elif mode == 'multiline' and source.startswith('"""', index):
                mode = 'code'
                advance(3)
            elif mode == 'string' and source[index] == '"':
                mode = 'code'
                advance(1)
            else:
                advance(1)
            continue

        if source.startswith('//', index):
            mode = 'line_comment'
            advance(2)
        elif source.startswith('/*', index):
            mode = 'block_comment'
            comment_depth = 1
            advance(2)
        elif source.startswith('"""', index):
            mode = 'multiline'
            advance(3)
        elif source[index] == '"':
            mode = 'string'
            advance(1)
        elif source[index] in OPEN:
            stack.append((source[index], line, column))
            advance(1)
        elif source[index] in CLOSE:
            if not stack or OPEN[stack[-1][0]] != source[index]:
                errors.append(f'{line}:{column}: unexpected {source[index]}')
            else:
                stack.pop()
            advance(1)
        else:
            advance(1)

    errors.extend(f'{start_line}:{start_column}: unclosed {char}'
                  for char, start_line, start_column in stack)
    if mode in ('block_comment', 'string', 'multiline'):
        errors.append(f'{line}:{column}: unterminated {mode}')
    return errors


def main():
    files = sorted(ROOT.rglob('*.swift'))
    failures = {str(path.relative_to(ROOT)): errors
                for path in files if (errors := check(path))}
    result = {'scope': 'lexical Swift delimiter balance only', 'files': len(files),
              'passed': len(files) - len(failures), 'failures': failures,
              'ios_compiled': False}
    (ROOT.parent / 'validation/swift-bracket-report.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if len(files) == 40 and not failures else 1


if __name__ == '__main__':
    sys.exit(main())
