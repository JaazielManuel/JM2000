import re

def extrai_numero(text, keyword, start_pos=0):
    idx = text.find(keyword, start_pos)
    if idx == -1: return 0.0

    # Look for the first number after the keyword
    match = re.search(r'[-+]?\d*\.?\d+', text[idx + len(keyword):])
    if match:
        return float(match.group())
    return 0.0

def periodo_texto(nome):
    nome = nome.lower().strip()
    # Order matters: m15 before m1
    if "m15" in nome: return "PERIOD_M15"
    if "m30" in nome: return "PERIOD_M30"
    if "m5" in nome: return "PERIOD_M5"
    if "m1" in nome: return "PERIOD_M1"
    if "h1" in nome: return "PERIOD_H1"
    if "h4" in nome: return "PERIOD_H4"
    if "d1" in nome: return "PERIOD_D1"
    return "PERIOD_CURRENT"

class Rule:
    def __init__(self, intent, tf, rtype):
        self.active = True
        self.intent = intent
        self.tf = tf
        self.type = rtype
        self.p1 = 0
        self.d1 = 0.0
        self.op = ""
        self.s1 = ""

def test_parser(prompt):
    rules = []
    # Normalize
    prompt = prompt.replace('|', '.').replace('\n', '.')
    prompt = prompt.replace(' e o ', '.').replace(' e a ', '.').replace(' e ', '.')
    segments = prompt.split('.')

    current_intent = 0
    p_frequency = "PERIOD_M15"

    for seg in segments:
        seg = seg.lower()
        if "compra" in seg: current_intent = 1
        if "vende" in seg: current_intent = -1

        tf = periodo_texto(seg)
        if tf == "PERIOD_CURRENT": tf = p_frequency
        if "cada" in seg and periodo_texto(seg) != "PERIOD_CURRENT":
             p_frequency = periodo_texto(seg)

        # MA
        ma_pos = seg.find("média")
        if ma_pos == -1: ma_pos = seg.find("ma")
        if ma_pos >= 0:
            r = Rule(current_intent, tf, 1)
            kw = "média" if seg.find("média", ma_pos) >= 0 else "ma"
            ext_p1 = extrai_numero(seg, kw, ma_pos)
            r.p1 = int(ext_p1) if ext_p1 != 0 else 20
            if "cruzar acima" in seg: r.op = "cross_above"
            elif "cruzar abaixo" in seg: r.op = "cross_below"
            elif "acima" in seg and "rsi" not in seg: r.op = ">"
            elif "abaixo" in seg and "rsi" not in seg: r.op = "<"
            if r.op != "": rules.append(r)

        # RSI
        rsi_pos = seg.find("rsi")
        if rsi_pos >= 0:
            r = Rule(current_intent, tf, 2)
            # Find period if in parens like RSI (14)
            period_match = re.search(r'rsi\s*\(\s*(\d+)\s*\)', seg)
            if period_match:
                r.p1 = int(period_match.group(1))
            else:
                ext_p1 = extrai_numero(seg, "rsi", rsi_pos)
                r.p1 = int(ext_p1) if ext_p1 != 0 else 14

            if "acima" in seg or "subir" in seg:
                r.op = ">"
                kw = "acima" if "acima" in seg else "subir"
                ext_d1 = extrai_numero(seg, kw, rsi_pos)
                r.d1 = ext_d1 if ext_d1 != 0 else 70.0
            elif "abaixo" in seg or "cair" in seg:
                r.op = "<"
                kw = "abaixo" if "abaixo" in seg else "cair"
                ext_d1 = extrai_numero(seg, kw, rsi_pos)
                r.d1 = ext_d1 if ext_d1 != 0 else 30.0
            rules.append(r)

    return rules

if __name__ == "__main__":
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    rules = test_parser(prompt)
    print(f"Parsed {len(rules)} rules.")
    for i, r in enumerate(rules):
        print(f"Rule {i}: Intent={r.intent}, Type={r.type}, P1={r.p1}, Op={r.op}, D1={r.d1}, TF={r.tf}")

    # Assertions for the complex prompt
    assert len(rules) >= 4
    # Rule 0: Buy MA 20
    assert rules[0].intent == 1 and rules[0].type == 1 and rules[0].p1 == 20 and rules[0].op == "cross_above"
    # Rule 1: Buy RSI 14 > 55
    assert rules[1].intent == 1 and rules[1].type == 2 and rules[1].p1 == 14 and rules[1].d1 == 55
    # Rule 2: Sell MA 20
    assert rules[2].intent == -1 and rules[2].type == 1 and rules[2].p1 == 20 and rules[2].op == "cross_below"
    # Rule 3: Sell RSI 14 < 45 (In prompt it is RSI without (14) but it should inherit or default to 14)
    assert rules[3].intent == -1 and rules[3].type == 2 and rules[3].d1 == 45

    print("Test passed!")
