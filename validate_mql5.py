import re
import sys

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    errors = []

    # Mandatory Handlers
    handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    for h in handlers:
        if h not in content:
            errors.append(f"Missing mandatory handler: {h}")

    # Procedural Standards (Anti-OO strings)
    prohibited_methods = ['.Lower()', '.Upper()', '.Substr()', '.Replace()', '.Find()', '.TrimLeft()', '.TrimRight()', '.Split()']
    for m in prohibited_methods:
        if m in content:
            # Check if it's an allowed Exception (like Reset() for Rule struct)
            errors.append(f"Prohibited OO string method used: {m}")

    # Check for specific Rule.Reset() which is allowed
    if '.Reset()' in content:
        # This is fine as per memory
        pass

    if errors:
        print("\n".join(errors))
        return False

    print("MQL5 validation passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
    else:
        if not validate_mql5(sys.argv[1]):
            sys.exit(1)
