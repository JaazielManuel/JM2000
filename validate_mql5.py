import re
import sys

def validate_mql5(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    errors = []

    # Check for forbidden object-oriented string methods
    forbidden_methods = [r'\.Lower\(', r'\.Upper\(', r'\.Find\(', r'\.Replace\(', r'\.Substr\(', r'\.Split\(']
    for method in forbidden_methods:
        if re.search(method, content, re.IGNORECASE):
            errors.append(f"Forbidden method found: {method}")

    # Check for mandatory functions
    mandatory_functions = ['InterpretaPrompt', 'AvaliaTudo', 'CalculaLote', 'EnviaOrdem', 'GerenciaPosicoes', 'AguardaNoticias', 'GravaLog', 'GravaCSV', 'OnTick', 'OnInit', 'OnTimer']
    for func in mandatory_functions:
        if func not in content:
            errors.append(f"Mandatory function missing: {func}")

    # Check for magic number usage
    if 'EA_MAGIC' not in content:
        errors.append("Constant EA_MAGIC missing")

    # Check for position selection before use
    if 'PositionSelect' not in content:
        errors.append("PositionSelect or equivalent missing")

    if errors:
        print("Validation failed:")
        for error in errors:
            print(f"- {error}")
        return False
    else:
        print("Validation passed!")
        return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_mql5.py <filepath>")
        sys.exit(1)

    if not validate_mql5(sys.argv[1]):
        sys.exit(1)
