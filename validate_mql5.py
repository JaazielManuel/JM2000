import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16-le') as f:
            content = f.read()
    except UnicodeDecodeError:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    missing_handlers = [h for h in mandatory_handlers if h not in content]

    if missing_handlers:
        print(f"Error: Missing mandatory handlers: {missing_handlers}")
        return False

    # Check for procedural string standards (no .Lower(), .Substr(), etc.)
    # Allowed methods include custom Rule struct methods and standard library methods
    allowed_methods = ['Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit', 'Volume', 'Magic',
                       'ResultRetcode', 'ResultPrice', 'SetExpertMagicNumber', 'Name', 'Reset']

    # Simple regex to find method calls like .MethodName()
    method_calls = re.findall(r'\.(\w+)\(', content)
    for call in method_calls:
        if call not in allowed_methods:
            print(f"Error: Prohibited object-oriented string method used: .{call}()")
            return False

    # Check for mandatory NLP functions
    mandatory_nlp = ['InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_nlp = [f for f in mandatory_nlp if f not in content]
    if missing_nlp:
        print(f"Error: Missing mandatory NLP/Signal functions: {missing_nlp}")
        return False

    print("MQL5 validation successful.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
