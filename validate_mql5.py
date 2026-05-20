import re
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # Check for mandatory handlers
    handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    for h in handlers:
        if h not in content:
            errors.append(f"Missing mandatory handler: {h}")

    # Check for mandatory NLP functions
    nlp_funcs = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes']
    for nf in nlp_funcs:
        if nf not in content:
            errors.append(f"Missing mandatory function: {nf}")

    # Check for procedural MQL5 constraints (no .Lower(), .Upper(), .Find(), .Split() as methods)
    # Using regex to find pattern like .Lower( or .Upper(
    forbidden_methods = ['Lower', 'Upper', 'Find', 'Split', 'Scan', 'Format', 'GetCharacter']
    for fm in forbidden_methods:
        if re.search(rf'\.{fm}\s*\(', content):
            errors.append(f"Procedural violation: Found object-oriented method call '.{fm}()'")

    if errors:
        print("Validation failed:")
        for e in errors:
            print(f" - {e}")
        return False
    else:
        print("Validation successful: MT_LiveExecutor.mq5 follows procedural MQL5 and contains all mandatory components.")
        return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
