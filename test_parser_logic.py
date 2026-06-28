import re

class Rule:
    def __init__(self):
        self.active = False
        self.type = 0
        self.tf = "PERIOD_CURRENT"
        self.p1 = 0
        self.d1 = 0.0
        self.op = ""
        self.intent = ""
        self.s1 = ""

    def __repr__(self):
        return f"Rule(type={self.type}, tf={self.tf}, p1={self.p1}, d1={self.d1}, op='{self.op}', intent='{self.intent}', s1='{self.s1}')"

def extrai_numero(txt, start_pos=0):
    res = ""
    found = False
    for i in range(start_pos, len(txt)):
        c = txt[i]
        if c.isdigit() or c in '.-+':
            res += c
            found = True
        elif found:
            break
    return float(res) if res and res not in '+-' else 0.0

def periodo_texto(txt):
    txt = txt.lower()
    if 'm15' in txt: return "PERIOD_M15"
    if 'm1' in txt: return "PERIOD_M1"
    if 'm5' in txt: return "PERIOD_M5"
    if 'h1' in txt: return "PERIOD_H1"
    if 'd1' in txt: return "PERIOD_D1"
    return "PERIOD_CURRENT"

rules = []
params = {}

def add_rule_specific(segment, intent):
    rule = Rule()
    rule.intent = intent
    rule.active = True
    rule.tf = periodo_texto(segment)
    s = segment.lower()

    found_any = False

    # MA
    if 'média' in s or 'ma' in s:
        rule_ma = Rule()
        rule_ma.intent = intent
        rule_ma.active = True
        rule_ma.tf = rule.tf
        rule_ma.type = 1
        pos = s.find('média') if 'média' in s else s.find('ma')
        rule_ma.p1 = int(extrai_numero(s, pos))
        if 'cruzar acima' in s: rule_ma.op = "cross_above"
        elif 'cruzar abaixo' in s: rule_ma.op = "cross_below"
        elif 'acima' in s: rule_ma.op = ">"
        elif 'abaixo' in s: rule_ma.op = "<"
        rules.append(rule_ma)
        found_any = True

    # RSI
    if 'rsi' in s:
        rule_rsi = Rule()
        rule_rsi.intent = intent
        rule_rsi.active = True
        rule_rsi.tf = rule.tf
        rule_rsi.type = 2
        pos = s.find('rsi')
        rule_rsi.p1 = int(extrai_numero(s, pos))
        if 'acima' in s[pos:] or 'subir' in s[pos:]:
            rule_rsi.op = ">"
            p_acima = s.find('acima', pos)
            p_subir = s.find('subir', pos)
            op_idx = p_acima if p_acima != -1 else p_subir
            rule_rsi.d1 = extrai_numero(s, op_idx)
        elif 'abaixo' in s[pos:] or 'cair' in s[pos:]:
            rule_rsi.op = "<"
            p_abaixo = s.find('abaixo', pos)
            p_cair = s.find('cair', pos)
            op_idx = p_abaixo if p_abaixo != -1 else p_cair
            rule_rsi.d1 = extrai_numero(s, op_idx)
        rules.append(rule_rsi)
        found_any = True

    # Pattern
    if 'padrão' in s:
        rule_pat = Rule()
        rule_pat.intent = intent
        rule_pat.active = True
        rule_pat.tf = rule.tf
        rule_pat.type = 9
        rule_pat.op = "pattern"
        rules.append(rule_pat)
        found_any = True

def interpreta_prompt(prompt):
    global rules, params
    rules = []
    p = prompt.replace('|', '.').replace('\n', '.')
    segments = p.split('.')
    current_intent = ""

    for s in segments:
        s = s.lower().replace(',', '.')

        if 'stop de' in s: params['stop'] = int(extrai_numero(s, s.find('stop de')))
        if 'take de' in s: params['take'] = int(extrai_numero(s, s.find('take de')))
        if 'risco de' in s: params['risk'] = extrai_numero(s, s.find('risco de'))

        if 'compra' in s: current_intent = "BUY"
        elif 'vende' in s: current_intent = "SELL"

        if current_intent:
            add_rule_specific(s, current_intent)

# Test case
test_prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos."

print(f"Testing prompt: {test_prompt}\n")
interpreta_prompt(test_prompt)

print("Parsed Rules:")
for r in rules:
    print(r)

print("\nParsed Parameters:")
print(params)

# Verification
assert params['stop'] == 30
assert params['take'] == 50
assert params['risk'] == 1.0
assert any(r.type == 1 and r.intent == "BUY" and r.p1 == 20 for r in rules)
assert any(r.type == 2 and r.intent == "BUY" and r.d1 == 55.0 for r in rules)

print("\nNLP Simulation Passed!")
