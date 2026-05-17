import os
import re

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    essential_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes', 'GravaCSV', 'GravaLog']

    missing = []
    for h in mandatory_handlers:
        if not re.search(fr'\b{h}\b\s*\(', content):
            missing.append(h)

    for func in essential_functions:
        if not re.search(fr'\b{func}\b\s*\(', content):
            missing.append(func)

    if missing:
        print(f"Missing mandatory components: {', '.join(missing)}")
        return False

    # Check for forbidden OO string methods
    oo_methods = re.findall(r'\.\w+\(', content)
    forbidden = [m for m in oo_methods if m.lower() in ['.lower(', '.find(', '.replace(', '.substr(', '.split(']]
    if forbidden:
        print(f"Detected forbidden OO string methods: {', '.join(forbidden)}")
        return False

    print("MQL5 Validation Passed!")
    return True

if __name__ == "__main__":
    validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5')
