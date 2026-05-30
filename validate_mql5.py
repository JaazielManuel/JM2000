import re
import sys

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except UnicodeError:
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
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    # Prohibited OO string methods: e.g. str.Lower()
    # Allowed: trade.Buy(), position.Select(), etc.
    # Heuristic: if it's a string function that should be procedural
    oo_string_methods = re.findall(r'\.(\w+)\(', content)
    prohibited = ['Lower', 'Upper', 'Trim', 'Replace', 'Find', 'Substr', 'Len']

    found_prohibited = []
    for method in oo_string_methods:
        if method in prohibited:
            # Check if it's preceded by something that looks like a trade/position object
            # This is a bit simplified, but let's follow the memory instructions.
            # Memory says: "blocks prohibited object-oriented string method calls (e.g., .Lower()) using the regex r'\.\w+\(' but is refined to allow necessary standard library object methods"
            # Actually, memory says it blocks .Lower() etc.
            found_prohibited.append(method)

    if found_prohibited:
        print(f"Found prohibited OO methods: {', '.join(found_prohibited)}")
        # return False # Just warning for now or strict? Let's be strict as per memory.
        # Actually, let's refine the regex to be more specific if possible,
        # or just follow the instruction to block .Lower() etc.
        pass

    # Check for procedural string functions
    procedural_functions = ['StringToLower', 'StringToUpper', 'StringTrimLeft', 'StringTrimRight', 'StringReplace', 'StringFind', 'StringSubstr', 'StringLen']
    # If we find .Lower(, we should fail.

    oo_match = re.search(r'\.(Lower|Upper|Trim|Replace|Find|Substr|Len)\(', content)
    if oo_match:
        print(f"Error: Found prohibited OO string method call: .{oo_match.group(1)}()")
        return False

    print("MQL5 validation passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)
    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
