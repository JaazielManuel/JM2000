import re

def extrai_numero(text, keyword, start_pos=0):
    idx = text.find(keyword, start_pos)
    if idx == -1: return None

    # Look for the first number after the keyword
    match = re.search(r'[-+]?\d*\.?\d+', text[idx + len(keyword):])
    if match:
        return float(match.group())
    return None

def periodo_texto(nome):
    nome = nome.lower().strip()
    if "m15" in nome or "15 min" in nome: return "PERIOD_M15"
    if "m30" in nome or "30 min" in nome: return "PERIOD_M30"
    if "m1" in nome or "1 min" in nome: return "PERIOD_M1"
    if "m5" in nome or "5 min" in nome: return "PERIOD_M5"
    if "h1" in nome or "60 min" in nome or "1 hora" in nome: return "PERIOD_H1"
    if "h4" in nome or "4 horas" in nome: return "PERIOD_H4"
    if "d1" in nome or "diário" in nome: return "PERIOD_D1"
    return "PERIOD_CURRENT"

class Rule:
    def __init__(self):
        self.active = False
        self.intent = 0 # 1 BUY, -1 SELL
        self.type = 0
        self.tf = "PERIOD_CURRENT"
        self.p1 = 0
        self.p2 = 0
        self.p3 = 0
        self.d1 = 0.0
        self.d2 = 0.0
        self.s1 = ""
        self.op = ""

def test_parser(prompt):
    rules = []
    # Normalize
    p = prompt.replace('|', '.').replace('\n', '.')
    p = p.replace(' e o ', '.').replace(' e a ', '.').replace(' e ', '.')
    segments = p.split('.')

    current_intent = 0
    p_frequency = "PERIOD_M15"

    for seg in segments:
        seg = seg.replace('(', ' ').replace(')', ' ').replace(',', '.')
        seg = seg.lower()
        if "compra" in seg: current_intent = 1
        if "vende" in seg: current_intent = -1

        tf = periodo_texto(seg)
        if tf == "PERIOD_CURRENT": tf = p_frequency

        if "média" in seg or "ma" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 1 # MA
            r.p1 = int(extrai_numero(seg, "média") or extrai_numero(seg, "ma") or 20)

            # Check for second period
            idx_ma = seg.find("média") if "média" in seg else seg.find("ma")
            idx_next = seg.find("/", idx_ma)
            if idx_next == -1: idx_next = seg.find(" e ", idx_ma)
            if idx_next == -1: idx_next = seg.find(" de ", idx_ma + 5) # search after first period

            if idx_next != -1:
                r.p2 = int(extrai_numero(seg, "", idx_next) or 0)

            if "cruzar acima" in seg: r.op = "cross_above"
            elif "cruzar abaixo" in seg: r.op = "cross_below"
            elif "acima" in seg: r.op = ">"
            elif "abaixo" in seg: r.op = "<"
            rules.append(r)

        if "rsi" in seg:
            rsi_pos = seg.find("rsi")
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 2 # RSI
            r.p1 = int(extrai_numero(seg, "rsi", rsi_pos) or 14)
            if "acima" in seg or "subir" in seg:
                r.op = ">"
                r.d1 = extrai_numero(seg, "acima", rsi_pos) or extrai_numero(seg, "subir", rsi_pos) or 70
            elif "abaixo" in seg or "cair" in seg:
                r.op = "<"
                r.d1 = extrai_numero(seg, "abaixo", rsi_pos) or extrai_numero(seg, "cair", rsi_pos) or 30
            rules.append(r)

        if "estocástico" in seg or "stoch" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 3
            rules.append(r)

        if "bollinger" in seg or "bb" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 4
            rules.append(r)

        if "breakout" in seg or "rompimento" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 5
            rules.append(r)

        if "delta" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 6
            rules.append(r)

        if "volume" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 7
            rules.append(r)

        if "ama" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 8
            rules.append(r)

        if "padrão" in seg or "pattern" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 9
            rules.append(r)

        if "força relativa" in seg or "bench" in seg:
            r = Rule()
            r.active = True
            r.intent = current_intent
            r.tf = tf
            r.type = 10
            rules.append(r)

    return rules

if __name__ == "__main__":
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Use também estocástico e bollinger. Breakout diário ativado."
    rules = test_parser(prompt)
    print(f"Parsed {len(rules)} rules.")
    for i, r in enumerate(rules):
        print(f"Rule {i}: Intent={r.intent}, Type={r.type}, P1={r.p1}, P2={r.p2}, Op={r.op}, D1={r.d1}, TF={r.tf}")

    # Basic assertions
    assert any(r.intent == 1 and r.type == 1 and r.p1 == 20 for r in rules)
    assert any(r.intent == 1 and r.type == 2 and r.d1 == 55 for r in rules)
    assert any(r.intent == -1 and r.type == 1 for r in rules)
    assert any(r.intent == -1 and r.type == 2 and r.d1 == 45 for r in rules)
    assert any(r.type == 3 for r in rules)
    assert any(r.type == 4 for r in rules)
    assert any(r.type == 5 for r in rules)

    # Test MA cross
    prompt2 = "Compra se média 9 cruzar acima de média 21"
    rules2 = test_parser(prompt2)
    assert rules2[0].type == 1 and rules2[0].p1 == 9 and rules2[0].p2 == 21

    print("All tests passed!")
