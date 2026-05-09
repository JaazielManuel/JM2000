import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    errors = []

    # Check for mandatory functions
    mandatory = ["OnInit", "OnTick", "OnTimer", "InterpretaPrompt", "AvaliaTudo", "EnviaOrdem"]
    for func in mandatory:
        if func not in content:
            errors.append(f"Missing mandatory function: {func}")

    # Check for OOP string methods (invalid in procedural MQL5)
    invalid_methods = [".Lower()", ".Replace(", ".Split(", ".Find(", ".Scan("]
    for method in invalid_methods:
        if method in content:
            errors.append(f"Found invalid OOP string method: {method}. Use StringToLower, StringReplace, etc.")

    # Check for correct handle management
    if "IndicatorRelease" not in content:
        errors.append("Missing IndicatorRelease for proper handle management.")

    if errors:
        for err in errors:
            print(f"ERROR: {err}")
        return False

    print("SUCCESS: MQL5 validation passed.")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
