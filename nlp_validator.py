import re

def extrai_numero(txt, keyword=None, pos=None):
    start_pos = 0
    if keyword:
        start_pos = txt.find(keyword)
        if start_pos == -1: return 0, 0
        search_txt = txt[start_pos + len(keyword):]
    elif pos is not None:
        search_txt = txt[pos:]
        start_pos = pos
    else:
        search_txt = txt

    match = re.search(r'(\d+\.?\d*)', search_txt)
    if match:
        absolute_pos = txt.find(match.group(1), start_pos + (len(keyword) if keyword else 0))
        return float(match.group(1)), absolute_pos + len(match.group(1))
    return 0, 0

def periodo_texto(nome):
    nome = nome.lower()
    if "15 min" in nome or "m15" in nome: return "PERIOD_M15"
    if "5 min" in nome or "m5" in nome: return "PERIOD_M5"
    if "1 min" in nome or "m1" in nome: return "PERIOD_M1"
    if "1 hora" in nome or "h1" in nome: return "PERIOD_H1"
    if "diário" in nome or "d1" in nome: return "PERIOD_D1"
    return "PERIOD_CURRENT"

def extract_time(txt):
    match = re.search(r'(\d{1,2})h(\d{0,2})', txt)
    if match:
        h = match.group(1)
        m = match.group(2) if match.group(2) else "00"
        return f"{h}:{m}"
    return "00:00"

def interpreta_prompt(prompt):
    lower_prompt = prompt.lower()

    config = {
        "frequency": periodo_texto(lower_prompt),
        "risk": extrai_numero(lower_prompt, "risco de ")[0] or 1.0,
        "stop": extrai_numero(lower_prompt, "stop de ")[0],
        "take": extrai_numero(lower_prompt, "take de ")[0],
        "start_time": extract_time(lower_prompt),
        "be_start": extrai_numero(lower_prompt, "atingir +")[0],
        "be_plus": extrai_numero(lower_prompt, "entrada +")[0],
        "rules": []
    }

    segments = re.split(r' e |[.,]', lower_prompt)
    current_intent = "NONE"

    for s in segments:
        s = s.strip()
        if not s: continue

        if "compra" in s: current_intent = "BUY"
        elif "vende" in s: current_intent = "SELL"

        rule = {"intent": current_intent, "tf": periodo_texto(s)}
        if rule["tf"] == "PERIOD_CURRENT": rule["tf"] = config["frequency"]

        if "média" in s or " ma " in s:
            val, next_pos = extrai_numero(s, pos=0)
            rule["type"] = "MA"
            rule["p1"] = val
            val2, _ = extrai_numero(s, pos=next_pos)
            rule["p2"] = val2
            config["rules"].append(rule)
        elif "rsi" in s:
            rule["type"] = "RSI"
            val, next_pos = extrai_numero(s, pos=s.find("rsi") + 3)
            val2, _ = extrai_numero(s, pos=next_pos)
            if val < 40:
                rule["period"] = val
                rule["threshold"] = val2
            else:
                rule["period"] = 14
                rule["threshold"] = val
            config["rules"].append(rule)
        elif "stoch" in s or "estocástico" in s:
            rule["type"] = "STOCH"
            config["rules"].append(rule)
        elif "bollinger" in s or "bb" in s:
            rule["type"] = "BB"
            config["rules"].append(rule)
        elif "rompimento diário" in s:
            rule["type"] = "DAILYBREAK"
            config["rules"].append(rule)

    return config

example = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos."

result = interpreta_prompt(example)
print(f"Frequency: {result['frequency']}")
print(f"Start Time: {result['start_time']}")
print(f"Risk: {result['risk']}%")
print(f"Stop: {result['stop']}")
print(f"Take: {result['take']}")
print(f"BE Start: {result['be_start']}")
print(f"BE Plus: {result['be_plus']}")
print("\nRules:")
for r in result['rules']:
    print(r)

print("\nTesting multiple indicators:")
multi_example = "Compra se Bollinger e Estocástico e Rompimento Diário."
multi_result = interpreta_prompt(multi_example)
for r in multi_result['rules']:
    print(r)
