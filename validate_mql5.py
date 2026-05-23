import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except Exception:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    mandatory_handlers = [
        'OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt',
        'AvaliaTudo', 'EnviaOrdem'
    ]

    missing = []
    for handler in mandatory_handlers:
        if handler not in content:
            missing.append(handler)

    if missing:
        print(f"Error: Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Check for object-oriented string methods (dot notation)
    # Exceptions: symInfo.Name, trade.Buy, etc. are OK if they are objects we defined
    # But string objects like 'work.Lower()' are not allowed in procedural MQL5
    dot_calls = re.findall(r'\.\w+\(', content)
    forbidden_prefixes = ['work', 'prompt', 'seg', 'txt', 'numStr']

    # Simple heuristic: if it looks like a string method call on a common string variable name
    for call in dot_calls:
        # This is a bit aggressive but helps enforce the memory instruction
        # "procedural functions like StringToLower(work) ... must be used instead of object-oriented dot notation"
        pass

    # Strictly check for .Lower(), .Upper(), .Find(), .Split() on anything
    forbidden_methods = ['.Lower(', '.Upper(', '.Find(', '.Split(', '.Scan(', '.Len(', '.Substr(', '.GetCharacter(']
    for method in forbidden_methods:
        if method in content:
            print(f"Error: Found forbidden object-oriented string method: {method}")
            return False

    print("Validation passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
