import re

def test_nlp_parsing_v2(prompt):
    print(f"Testing Prompt: {prompt}\n")

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

    def periodo_texto(nome):
        nome = nome.lower()
        if "m30" in nome or "30 min" in nome: return "PERIOD_M30"
        if "m15" in nome or "15 min" in nome: return "PERIOD_M15"
        if "m5" in nome or "5 min" in nome: return "PERIOD_M5"
        if "h1" in nome or "1 hora" in nome: return "PERIOD_H1"
        return "PERIOD_CURRENT"

    # Context Inheritance Logic
    p_lower = prompt.lower().replace(" e ", "|").replace(" + ", "|").replace(",", "|").replace(".", "|")
    segments = [s.strip() for s in p_lower.split("|") if s.strip()]

    risk = extract_number(prompt, "risco de ") or 1.0
    stop = extract_number(prompt, "stop de ")
    take = extract_number(prompt, "take de ")
    max_trades = extract_number(prompt, "máximo ") or 1.0
    martingale = "martingale" in prompt.lower()
    hedge = "hedge" in prompt.lower()
    news_veto = extract_number(prompt, "não operar ") or extract_number(prompt, "notícias de ")
    start_time = extract_time(prompt)
    freq = periodo_texto(prompt)

    print(f"Global Parameters:")
    print(f"  Risk: {risk}% | Stop: {stop} | Take: {take} | MaxTrades: {max_trades}")
    print(f"  Martingale: {martingale} | Hedge: {hedge} | NewsVeto: {news_veto} min")
    print(f"  StartTime: {start_time} | Frequency: {freq}\n")

    current_intent = "NONE"
    ts_points = 0
    be_points = 0
    be_offset = 0

    for s in segments:
        if "compra" in s: current_intent = "BUY"
        elif "vende" in s: current_intent = "SELL"

        # Parameter inheritance
        if "atingir +" in s:
            val = extract_number(s, "atingir +")
            if "move stop" in s: be_points = val
            else: ts_points = val
        if "entrada +" in s: be_offset = extract_number(s, "entrada +")

        if "média" in s:
            p1 = extract_number(s, "média de ") or extract_number(s, "média ") or 20.0
            print(f"  [Rule] MA: Period={p1}, Intent={current_intent}, Cross={'cruzar' in s}")
        if "rsi" in s:
            per = extract_number(s, "rsi (") or extract_number(s, "rsi ") or 14.0
            thr = extract_number(s, "acima de ") or extract_number(s, "abaixo de ")
            print(f"  [Rule] RSI: Period={per}, Threshold={thr}, Intent={current_intent}, Cross=True")

    print(f"\nFinal State Management:")
    print(f"  TS Points: {ts_points} | BE Points: {be_points} | BE Offset: {be_offset}")

if __name__ == "__main__":
    example = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    test_nlp_parsing_v2(example)
