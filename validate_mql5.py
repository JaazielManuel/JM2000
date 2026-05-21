import os
import re
import sys

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    # Check for mandatory handlers
    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    missing_handlers = [h for h in mandatory_handlers if h not in content]

    # Check for core NLP functions
    core_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes']
    missing_functions = [f for f in core_functions if f not in content]

    # Check for procedural MQL5 (no .Lower(), .Upper(), etc. on strings)
    # This is a simple regex check
    oo_string_methods = re.findall(r'\.\w+\(', content)
    # Filter out common valid MQL5 object calls if any (like trade.Buy)
    forbidden_oo = [m for m in oo_string_methods if m in ['.Lower(', '.Upper(', '.Trim(', '.Split(']]

    valid = True
    if missing_handlers:
        print(f"Missing mandatory handlers: {missing_handlers}")
        valid = False
    if missing_functions:
        print(f"Missing core functions: {missing_functions}")
        valid = False
    if forbidden_oo:
        print(f"Detected forbidden OO string methods: {forbidden_oo}")
        valid = False

    if valid:
        print("MQL5 Validation Passed!")
    else:
        print("MQL5 Validation Failed!")

    return valid

if __name__ == "__main__":
    filepath = "MQL5/Experts/MT_LiveExecutor.mq5"
    if validate_mql5(filepath):
        sys.exit(0)
    else:
        sys.exit(1)
