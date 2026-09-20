import glob
import sys

def check_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    stack = []
    pairs = {')':'(', ']':'[', '}':'{'}
    in_string = False
    in_multiline_comment = 0
    lines = content.split('\n')
    for line_num, line in enumerate(lines, 1):
        i = 0
        while i < len(line):
            c = line[i]
            if not in_string and in_multiline_comment == 0:
                if c == '/' and i + 1 < len(line) and line[i+1] == '/':
                    break
                elif c == '/' and i + 1 < len(line) and line[i+1] == '*':
                    in_multiline_comment += 1
                    i += 2
                    continue
                elif c == '"':
                    # check for multiline string """
                    if i + 2 < len(line) and line[i+1] == '"' and line[i+2] == '"':
                        # not handling full multi-line string here, but basic quotes
                        i += 3
                        continue
                    in_string = True
                    i += 1
                    continue
                elif c in '({[':
                    stack.append((c, line_num, i+1))
                elif c in ')}]':
                    if not stack:
                        print(f"{path}:{line_num}:{i+1} Unmatched closing {c}")
                        return False
                    top, t_line, t_col = stack.pop()
                    if pairs[c] != top:
                        print(f"{path}:{line_num}:{i+1} Mismatched {c}, expected matching for {top} from line {t_line}:{t_col}")
                        return False
            elif in_string:
                if c == '\\':
                    i += 2
                    continue
                elif c == '"':
                    in_string = False
            elif in_multiline_comment > 0:
                if c == '*' and i + 1 < len(line) and line[i+1] == '/':
                    in_multiline_comment -= 1
                    i += 2
                    continue
            i += 1
    if stack:
        for top, t_line, t_col in stack:
            print(f"{path}:{t_line}:{t_col} Unclosed {top}")
        return False
    return True

files = glob.glob('AISmartFramingCamera/**/*.swift', recursive=True)
all_ok = True
for f in files:
    if not check_file(f):
        all_ok = False
        print(f"FAILED: {f}")

if all_ok:
    print(f"SUCCESS: All {len(files)} Swift files passed bracket balance check!")
    sys.exit(0)
else:
    sys.exit(1)
