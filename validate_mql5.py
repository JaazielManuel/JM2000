import sys
import os
import re

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found")
        return False

    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    required_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing_handlers = [h for h in required_handlers if h not in content]

    if missing_handlers:
        print(f"Missing required handlers: {missing_handlers}")
        return False

    # Procedural standards: check for prohibited instance methods (simplified)
    prohibited = [r'\.Lower\(', r'\.Substr\(', r'\.Replace\(', r'\.TrimLeft\(', r'\.TrimRight\(']
    violations = []
    for p in prohibited:
        if re.search(p, content):
            violations.append(p)

    if violations:
        print(f"Procedural violations (instance methods found): {violations}")
        return False

    # Check for EA_MAGIC and EA structure
    if "EA_MAGIC" not in content:
        print("Missing EA_MAGIC definition")
        return False

    print("Validation passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) > 1:
        validate_mql5(sys.argv[1])
    else:
        validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
