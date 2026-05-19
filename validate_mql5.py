import sys
import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    required_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    required_functions = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem', 'GerenciaPosicoes', 'AguardaNoticias', 'GravaLog']

    missing = []
    for handler in required_handlers:
        if handler not in content:
            missing.append(handler)

    for func in required_functions:
        if func not in content:
            missing.append(func)

    if missing:
        print(f"Missing mandatory components: {', '.join(missing)}")
        return False

    if '.Lower()' in content:
        print("Error: Object-oriented string method '.Lower()' found. Use 'StringToLower()' instead.")
        return False

    print(f"Validation successful for {filepath}")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    success = validate_mql5(sys.argv[1])
    sys.exit(0 if success else 1)
