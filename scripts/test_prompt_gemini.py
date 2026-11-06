import urllib.request, json, sys, time, os

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

api_key = os.environ.get('GEMINI_API_KEY') or (sys.argv[1] if len(sys.argv) > 1 else "")
if not api_key:
    print("Usage: python test_prompt_gemini.py <API_KEY>")
    sys.exit(1)

url = f'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key={api_key}'

prompt = """You are an autonomous Director of Photography.
Analyze the scene and select the best film preset from:
- Fuji: Classic Chrome, Fuji Pro 400H, Fuji Velvia 50, Classic Neg, Astia 100F, Neopan Acros
- Kodak: Kodak Portra 400, Kodak Gold 200, Kodak ColorPlus, Kodak Ektar 100, Kodak Tri-X 400, Kodak 500D
- CCD: CCD1, D-CCD, BlueSK, MangaCam, G-CCD, InstaLite
- Vintage: 1998, LOMO LC-A, 120LG, FXN 35, Toy K, CineStill 800T, 1998 Street, Cyanotype
- Vintage Phone: Nokia Symbian, Motorola V3, iPhone 3GS, Blackberry Q10, Keitai 88, Sony K800
- Ricoh: GR3 Positive, GR Negative, GR High-B&W, GR F, GR Street, Caplio R, Theta Doc
- Canon: PowerShot G, Canon IXUS, Canon EOS 5D, Canon SureShot, Canon F-1, Canon Pro1
- DV: MiniDV 4:3, Hi8, DCR-DVD, DVX100, VHS-C, HDV 1080i
- Instant: POLA 600, SX-70, MINI 7, WIDE 300, SQ10, Spectra
- Clean: Original Clean, Studio Natural, Teal & Orange, Sunset Glow, Tokyo Clean, HK Cinema 90s, Leica Monochrom, Noir High Contrast

Return ONLY JSON:
{"recommended_preset":"Classic Chrome","preset_explanation":"Lý do chọn tone này bằng tiếng Việt","color_recipe":{"exposure_ev":0.0,"contrast":1.04,"highlights":0.92,"shadows":0.04,"warmth":5500,"tint":0.0,"saturation":1.04,"vibrance":1.03,"sharpness":1.02,"vignette":0.02}}
"""

payload = json.dumps({
    'contents': [{'parts': [{'text': prompt}]}],
    'generationConfig': {'response_mime_type': 'application/json'}
}).encode('utf-8')

req = urllib.request.Request(url, data=payload, headers={'Content-Type': 'application/json'})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode('utf-8'))
        dt = time.time() - t0
        print(f'Done in {dt:.2f}s:')
        txt = data['candidates'][0]['content']['parts'][0]['text']
        print(txt)
        parsed = json.loads(txt)
        print('Matched preset:', parsed.get('recommended_preset'))
        print('Explanation:', parsed.get('preset_explanation'))
except Exception as e:
    print('Error:', e)
