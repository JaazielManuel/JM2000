import re

def test_nlp_parsing(prompt):
    print(f"Testing Prompt: {prompt}")

    # Simulate ExtractNumber
    def extract_number(txt, keyword):
        pos = txt.lower().find(keyword.lower())
        if pos < 0: return 0
        sub = txt[pos + len(keyword):]
        res = ""
        found = False
        for c in sub:
            if c.isdigit() or c == '.':
                res += c
                found = True
            elif found: break
        return float(res) if res else 0

    # Simulate ExtractTime
    def extract_time(txt):
        pos = txt.lower().find("depois das ")
        if pos < 0: return ""
        sub = txt[pos + 11:]
        res = ""
        for c in sub:
            if c.isdigit() or c == ':' or c == 'h':
                if c == 'h': res += ":00"
                else: res += c
            elif res: break
        if ":" not in res and res: res += ":00"
        return res

    # Simulate PeriodoTexto
    def periodo_texto(nome):
        nome = nome.lower()
        if "m15" in nome: return "PERIOD_M15"
        if "m30" in nome: return "PERIOD_M30"
        if "h1" in nome: return "PERIOD_H1"
        return "PERIOD_CURRENT"

    # Extraction
    risk = extract_number(prompt, "risco de ")
    stop = extract_number(prompt, "stop de ")
    take = extract_number(prompt, "take de ")
    max_trades = extract_number(prompt, "máximo ")
    start_time = extract_time(prompt)
    freq = periodo_texto(prompt)

    print(f"Results:")
    print(f"  Risk: {risk}%")
    print(f"  Stop: {stop} pts")
    print(f"  Take: {take} pts")
    print(f"  Max Trades: {max_trades}")
    print(f"  Start Time: {start_time}")
    print(f"  Frequency: {freq}")

    # Check Indicators
    p_lower = prompt.lower().replace(" e ", "|").replace(" + ", "|").replace(",", "|").replace(".", "|")
    segments = [s.strip() for s in p_lower.split("|") if s.strip()]
    print(f"  Segments: {segments}")

    for s in segments:
        if "média" in s:
            p1 = extract_number(s, "média de ")
            if p1 == 0: p1 = extract_number(s, "média ")
            is_cross = "cruzar" in s
            print(f"  Indicator MA: Period={p1}, Cross={is_cross}")
        if "rsi" in s:
            per = extract_number(s, "rsi (")
            if per == 0: per = extract_number(s, "rsi ")
            threshold = extract_number(s, "acima de ")
            if threshold == 0: threshold = extract_number(s, "abaixo de ")
            is_cross = any(k in s for k in ["subir", "cair", "cruzar"])
            print(f"  Indicator RSI: Period={per}, Threshold={threshold}, Cross={is_cross}")

if __name__ == "__main__":
    example = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    test_nlp_parsing(example)
