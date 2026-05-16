import sys
import re

def validate_mql5(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    required_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in required_handlers if h not in content]

    if missing:
        print(f"FAILURE: Missing handlers: {', '.join(missing)}")
        return False

    # Check for object-oriented string methods (e.g., .Lower(), .Find())
    oo_string_methods = re.findall(r'\.\w+\(', content)
    forbidden = ['.Lower', '.Find', '.Upper', '.Replace', '.Split']
    violations = [m for m in oo_string_methods if any(f in m for f in forbidden)]

    if violations:
        print(f"FAILURE: Object-oriented string methods found: {', '.join(violations)}")
        return False

    print("SUCCESS: MQL5 file is compliant with procedural requirements and contains all necessary handlers.")
    return True

if __name__ == "__main__":
    if not validate_mql5('MQL5/Experts/MT_LiveExecutor.mq5'):
        sys.exit(1)
