import os

def validate_mql5(filepath):
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return False

    with open(filepath, 'r') as f:
        content = f.read()

    mandatory_handlers = ['OnInit', 'OnTick', 'OnTimer', 'InterpretaPrompt', 'AvaliaTudo', 'EnviaOrdem']
    missing = [h for h in mandatory_handlers if h not in content]

    if missing:
        print(f"Missing mandatory handlers: {', '.join(missing)}")
        return False

    prohibited = ['.Lower()'] # Object oriented string methods (use StringToLower instead)
    found_prohibited = [p for p in prohibited if p in content]

    if found_prohibited:
        print(f"Found prohibited patterns: {', '.join(found_prohibited)}")
        return False

    print("MQL5 validation passed.")
    return True

if __name__ == "__main__":
    validate_mql5("MQL5/Experts/MT_LiveExecutor.mq5")
