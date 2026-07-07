import re

def extrai_numero(txt, start_pos=0):
    match = re.search(r'[+-]?\d+(?:\.\d+)?', txt[start_pos:])
    if match:
        return float(match.group())
    return 0.0

def periodo_texto(nome):
    s = nome.lower()
    if 'm1' in s: return 'PERIOD_M1'
    if 'm5' in s: return 'PERIOD_M5'
    if 'm15' in s: return 'PERIOD_M15'
    if 'h1' in s: return 'PERIOD_H1'
    if 'd1' in s: return 'PERIOD_D1'
    return 'PERIOD_CURRENT'

def test_parser(prompt):
    print(f"Parsing prompt: {prompt}")
    p = prompt.lower()

    config = {}
    if "a cada" in p:
        config['frequency'] = periodo_texto(re.search(r'a cada\s+(\w+)', p).group(1))
    if "depois das" in p:
        config['start_hour'] = extrai_numero(p, p.find("depois das"))
    if "stop de" in p:
        config['stop_points'] = extrai_numero(p, p.find("stop de"))
    if "take de" in p:
        config['take_points'] = extrai_numero(p, p.find("take de"))
    if "risco de" in p:
        config['risk_percent'] = extrai_numero(p, p.find("risco de"))

    be_pos = p.find("ao atingir")
    if be_pos >= 0:
        config['be_trigger'] = extrai_numero(p, be_pos)
        config['be_profit'] = extrai_numero(p, p.find("entrada", be_pos))

    print(f"Config: {config}")

    segments = p.split('.')
    rules = []
    current_intent = None

    for s in segments:
        if 'compra' in s: current_intent = 'BUY'
        elif 'vende' in s: current_intent = 'SELL'

        if current_intent:
            if 'média' in s or 'ma' in s or 'ema' in s:
                period = extrai_numero(s, s.find('média'))
                op = "cross_above" if "cruzar acima" in s else "cross_below" if "cruzar abaixo" in s else ">" if "acima" in s else "<"
                rules.append({'intent': current_intent, 'type': 'MA', 'period': period, 'op': op})
            if 'rsi' in s:
                period = extrai_numero(s, s.find('rsi'))
                level = extrai_numero(s, max(s.find('acima'), s.find('abaixo')))
                op = "cross_above" if "subir acima" in s or "cruzar acima" in s else "cross_below" if "cair abaixo" in s or "cruzar abaixo" in s else ">" if "acima" in s else "<"
                rules.append({'intent': current_intent, 'type': 'RSI', 'period': period, 'level': level, 'op': op})

    for r in rules:
        print(f"Rule: {r}")

if __name__ == "__main__":
    example_prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 300 pontos, take de 500 pontos. Risco de 1.0 % do capital por trade. Máximo 3 trades simultâneos. Ao atingir +300 pontos, move stop para entrada +50 pontos."
    test_parser(example_prompt)
