import sys
import re

def validate_mql5(filepath):
    try:
        with open(filepath, 'r', encoding='utf-16') as f:
            content = f.read()
    except:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

    errors = []

    # Check mandatory handlers
    mandatory_handlers = ['OnInit', 'OnDeinit', 'OnTick', 'OnTimer']
    for handler in mandatory_handlers:
        if not re.search(fr'\b{handler}\s*\(', content):
            errors.append(f"Missing mandatory handler: {handler}")

    # Check for procedural standards (no OO string methods)
    # Allowed library methods as per memory
    allowed_methods = [
        'Buy', 'Sell', 'PositionSelect', 'PositionModify', 'Profit',
        'Volume', 'Magic', 'ResultRetcode', 'ResultPrice',
        'SetExpertMagicNumber', 'Name', 'Reset'
    ]

    # Find all pattern like .Something(
    matches = re.findall(r'\.(\w+)\s*\(', content)
    for method in matches:
        if method not in allowed_methods:
            errors.append(f"Prohibited OO method call: .{method}()")

    if errors:
        print("Validation FAILED:")
        for error in errors:
            print(f"- {error}")
        return False

    print("Validation PASSED.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
