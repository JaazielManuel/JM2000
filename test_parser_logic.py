# Mock of the parser logic in Python to verify the NLP rules
import re

def extrai_numero(txt, start_index):
    match = re.search(r'(\d+[\.,]?\d*)', txt[start_index:])
    if match:
        val = match.group(1).replace(',', '.')
        new_cursor = start_index + match.end()
        return float(val), new_cursor
    return 0, start_index

def test_parser(prompt):
    print(f"Testing prompt: {prompt}")

    p_risk = 1.0
    p_slPoints = 300
    p_tpPoints = 500

    clean_prompt = prompt.replace('|', '.').replace('\n', '.')
    segments = clean_prompt.split('.')

    for s in segments:
        s = s.strip().lower()
        if not s: continue

        if "stop" in s:
            val, _ = extrai_numero(s, s.find("stop"))
            p_slPoints = int(val)
            print(f"Found SL: {p_slPoints}")

        if "take" in s:
            val, _ = extrai_numero(s, s.find("take"))
            p_tpPoints = int(val)
            print(f"Found TP: {p_tpPoints}")

        if "risco" in s:
            val, _ = extrai_numero(s, s.find("risco"))
            p_risk = val
            print(f"Found Risk: {p_risk}%")

    assert p_slPoints == 30
    assert p_tpPoints == 50
    assert p_risk == 1.0
    print("Test passed!")

if __name__ == "__main__":
    sample_prompt = "Compra se o preço cruzar acima da média de 20 períodos. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade."
    test_parser(sample_prompt)
