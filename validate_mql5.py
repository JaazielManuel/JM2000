import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    required_functions = [
        'InterpretaPrompt',
        'AvaliaTudo',
        'CalculaLote',
        'EnviaOrdem',
        'GerenciaPosicoes',
        'GravaCSV',
        'GravaLog',
        'AguardaNoticias',
        'OnTick',
        'OnTimer'
    ]

    missing = [fn for fn in required_functions if fn not in content]
    if missing:
        print(f"Missing required functions: {', '.join(missing)}")
        return False

    # Check for forbidden MQL5 patterns (e.g. string.Lower())
    forbidden_patterns = [
        r'\.Lower\(\)',
        r'\.Upper\(\)',
        r'\.Find\(\)',
        r'\.Split\(\)',
        r'\.Replace\(\)'
    ]

    for pattern in forbidden_patterns:
        if re.search(pattern, content):
            print(f"Forbidden MQL5 pattern found: {pattern}")
            return False

    # Check for position selection before access
    if 'posInfo.SelectByIndex' not in content:
         print("Warning: CPositionInfo selection might be missing or manual selection used.")

    print("MQL5 validation passed successfully.")
    return True

if __name__ == "__main__":
    if validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5'):
        sys.exit(0)
    else:
        sys.exit(1)
