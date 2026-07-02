import re

def extrai_numero(txt, keyword, start_pos=0):
    pos = txt.find(keyword, start_pos)
    if pos < 0:
        return 0, start_pos

    sub = txt[pos + len(keyword):]
    res = ""
    found_digit = False
    for char in sub:
        if char.isdigit() or char in ".,-+":
            if char == ",":
                res += "."
            else:
                res += char
            found_digit = True
        elif found_digit:
            break
        elif char.isspace():
            continue
        else:
            # If we found something that is not a digit/space before any digit,
            # maybe it's not the number we are looking for in this specific keyword match?
            # Actually, the MQL5 logic is quite simple.
            pass

    try:
        val = float(res) if res else 0
        return val, pos + len(keyword) + len(res)
    except ValueError:
        return 0, pos + len(keyword)

def test_parser():
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."

    print(f"Testing Prompt: {prompt}")

    # Global Params
    risco, _ = extrai_numero(prompt, "Risco de")
    stop, _ = extrai_numero(prompt, "Stop de")
    take, _ = extrai_numero(prompt, "take de")
    max_trades, _ = extrai_numero(prompt, "Máximo")

    start_hour = 0
    if "depois das" in prompt:
        start_hour, _ = extrai_numero(prompt, "depois das")
    elif "após as" in prompt:
        start_hour, _ = extrai_numero(prompt, "após as")

    be_trigger = 0
    be_step = 0
    if "move stop para entrada" in prompt or "breakeven" in prompt:
        pos = 0
        be_trigger, pos = extrai_numero(prompt, "ao atingir", pos)
        be_step, _ = extrai_numero(prompt, "entrada", pos)

    print(f"Parsed Global Params:")
    print(f"  Risk: {risco}%")
    print(f"  Stop: {stop} pts")
    print(f"  Take: {take} pts")
    print(f"  Max Trades: {max_trades}")
    print(f"  Start Hour: {start_hour}h")
    print(f"  Breakeven: {be_trigger} / {be_step}")

    # Indicator parsing simulation
    p = prompt.replace(" e ", ".").replace(" e o ", ".").replace(" e a ", ".").replace("|", ".").replace("\n", ".")
    segments = p.split('.')

    print("\nParsed Segments & Intent:")
    current_intent = None
    for seg in segments:
        seg = seg.lower().strip()
        if not seg: continue

        if "compra" in seg: current_intent = "BUY"
        elif "vende" in seg: current_intent = "SELL"

        if current_intent:
            print(f"  [{current_intent}] {seg}")
            if "média" in seg:
                period, _ = extrai_numero(seg, "média de")
                op = "cruzar_cima" if "cruzar acima" in seg else "cruzar_baixo" if "cruzar abaixo" in seg else "none"
                print(f"    -> Rule: MA, Period: {period}, Op: {op}")
            if "rsi" in seg:
                period = 0
                match = re.search(r'rsi\s*\((\d+)\)', seg)
                if match:
                    period = int(match.group(1))
                else:
                    period, _ = extrai_numero(seg, "rsi")

                val = 0
                op = ""
                if "acima" in seg or "subir" in seg:
                    op = ">"
                    val, _ = extrai_numero(seg, "acima")
                    if val == 0: val, _ = extrai_numero(seg, "subir")
                elif "abaixo" in seg or "cair" in seg:
                    op = "<"
                    val, _ = extrai_numero(seg, "abaixo")
                    if val == 0: val, _ = extrai_numero(seg, "cair")
                print(f"    -> Rule: RSI, Period: {period}, Val: {val}, Op: {op}")

if __name__ == "__main__":
    test_parser()
