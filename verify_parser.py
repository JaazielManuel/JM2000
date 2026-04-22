import re

def extrai_numero(text, start_pos=0):
    text = text[start_pos:]
    match = re.search(r'(\d+(\.\d+)?)', text)
    if match:
        return float(match.group(1))
    return 0.0

def extrai_valor_apos(text, keyword):
    pos = text.find(keyword)
    if pos < 0:
        return 0.0
    return extrai_numero(text, pos + len(keyword))

def extract_time(text):
    t = text.replace('h', ':00')
    match = re.search(r'(\d{1,2}:\d{2})', t)
    if match:
        return match.group(1)
    return "00:00"

def periodo_texto(nome):
    nome = nome.lower()
    if "15 min" in nome or "m15" in nome: return "PERIOD_M15"
    if "5 min" in nome or "m5" in nome: return "PERIOD_M5"
    if "1 min" in nome or "m1" in nome: return "PERIOD_M1"
    if "1 hora" in nome or "h1" in nome: return "PERIOD_H1"
    if "diário" in nome or "d1" in nome: return "PERIOD_D1"
    return "PERIOD_CURRENT"

def interpreta_prompt(prompt):
    work = prompt.lower()

    risk = extrai_valor_apos(work, "risco de")
    stop = int(extrai_valor_apos(work, "stop de"))
    take = int(extrai_valor_apos(work, "take de"))
    max_trades = int(extrai_valor_apos(work, "máximo"))
    start_time = extract_time(work)

    be_start = 0
    be_plus = 0
    if "move stop para entrada" in work:
        be_start = int(extrai_valor_apos(work, "atingir"))
        be_plus = int(extrai_valor_apos(work, "entrada"))

    freq = periodo_texto(work)

    segments = re.split(r' e |\.|\,', work)
    rules = []
    current_intent = "NONE"

    for s in segments:
        s = s.strip()
        if not s: continue

        if "compra" in s: current_intent = "BUY"
        elif "vende" in s: current_intent = "SELL"

        if "média" in s or " ma " in s:
            p1 = int(extrai_numero(s))
            if p1 == 0: p1 = 20
            rules.append({"type": "MA", "p1": p1, "intent": current_intent})

        if "rsi" in s:
            per = int(extrai_numero(s))
            if per == 0: per = 14
            val1 = extrai_numero(s, s.find("rsi") + 3)
            rules.append({"type": "RSI", "p1": per, "val": val1, "intent": current_intent})

    return {
        "risk": risk,
        "stop": stop,
        "take": take,
        "max_trades": max_trades,
        "start_time": start_time,
        "be_start": be_start,
        "be_plus": be_plus,
        "freq": freq,
        "rules": rules
    }

prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

result = interpreta_prompt(prompt)
import json
print(json.dumps(result, indent=2))
