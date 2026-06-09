import re
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # 1. Mandatory Handlers
    handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    for h in handlers:
        if f'void {h}(' not in content and f'int {h}(' not in content:
            errors.append(f"Missing mandatory handler: {h}")

    # 2. Required Functions
    req_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes', 'AguardaNoticias', 'GravaLog']
    for rf in req_functions:
        if rf not in content:
            errors.append(f"Missing required function: {rf}")

    # 3. Procedural Standard (No OO string methods)
    prohibited = [r'\.Lower\(', r'\.Upper\(', r'\.Substr\(', r'\.Replace\(', r'\.Trim\(']
    for p in prohibited:
        if re.search(p, content):
            errors.append(f"OO string method detected: {p}")

    # 4. Allowed methods (white list for structs/objects)
    # This is a bit complex for a simple regex, but we check for common MQL5 OO calls that ARE allowed
    # like trade.Buy, posInfo.Select, etc.

    if errors:
        print("Validation FAILED:")
        for e in errors:
            print(f" - {e}")
        return False
    else:
        print("Validation PASSED.")
        return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
