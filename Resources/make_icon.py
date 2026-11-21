import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048                      # 描画は 2 倍で、最後に 1024 に縮小
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- 背景：macOS 風の角丸四角（824/1024 の枠） ---
inset, size = 200, 1648
radius = 370
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
grad = Image.new("RGBA", (size, size))
gd = ImageDraw.Draw(grad)
for y in range(size):
    t = y / size
    c = (int(38 + (12 - 38) * t), int(44 + (16 - 44) * t), int(58 + (24 - 58) * t), 255)
    gd.line([(0, y), (size, y)], fill=c)
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
bg.paste(grad, (inset, inset), mask)
img = Image.alpha_composite(img, bg)

# --- 楽器のシルエット（写真の形をもとに単純化。横向きで描いてから回転） ---
L, H = 1900, 400
sil = Image.new("L", (L, H), 0)
d = ImageDraw.Draw(sil)
cy = 170
# マウスピース（先が丸い）
d.rounded_rectangle([20, cy - 34, 240, cy + 34], radius=34, fill=255)
# 先端ブロック：上はわずかに右上がり、下は斜めに広がる
d.polygon([(230, cy - 62), (560, cy - 74), (560, cy + 120), (500, cy + 120), (230, cy + 58)], fill=255)
# 胴体（上辺にわずかな段差、右端は少し下がって角を落とす）
d.polygon([(552, cy - 76), (1500, cy - 88), (1560, cy - 70), (1860, cy - 60),
           (1880, cy - 40), (1880, cy + 112), (1840, cy + 128), (552, cy + 128)], fill=255)
# 下側のキー（指のボタン）
for x in [600, 690, 780, 870, 1020, 1110, 1200, 1290]:
    d.rounded_rectangle([x, cy + 120, x + 62, cy + 168], radius=10, fill=255)
# 後ろ側の親指ローラー部
d.polygon([(1560, cy + 120), (1700, cy + 120), (1680, cy + 210), (1600, cy + 210)], fill=255)
# 胴体の溝（シルエットの中の細い線）
groove = Image.new("L", (L, H), 0)
gdraw = ImageDraw.Draw(groove)
gdraw.line([(570, cy + 70), (1840, cy + 70)], fill=255, width=7)
gdraw.line([(570, cy - 70), (570, cy + 126)], fill=255, width=6)
sil = Image.composite(Image.new("L", (L, H), 0), sil, groove)

angle = 28
sil = sil.resize((int(L * 0.74), int(H * 0.74)), Image.LANCZOS)
sil_r = sil.rotate(angle, resample=Image.BICUBIC, expand=True)
color = Image.new("RGBA", sil_r.size, (240, 242, 246, 255))
# 影
shadow = Image.new("RGBA", sil_r.size, (0, 0, 0, 160))
shadow.putalpha(sil_r.filter(ImageFilter.GaussianBlur(18)).point(lambda v: int(v * 0.55)))
px = (S - sil_r.width) // 2
py = (S - sil_r.height) // 2 - 190
img.alpha_composite(shadow, (px + 14, py + 26))
color.putalpha(sil_r)
img.alpha_composite(color, (px, py))

# --- 文字（普通の書体。ロゴのデザインは使わない） ---
d = ImageDraw.Draw(img)
font = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-Bold.otf", 230)
sub = ImageFont.truetype("/usr/share/fonts/opentype/inter/Inter-SemiBold.otf", 104)
def center(text, f, y, fill):
    w = d.textlength(text, font=f)
    d.text(((S - w) / 2, y), text, font=f, fill=fill)
center("EWI5000", font, 1310, (240, 242, 246, 255))
center("BACKUP", sub, 1565, (110, 190, 255, 255))

out = img.resize((1024, 1024), Image.LANCZOS)
out.save("AppIcon_1024.png")
out.save("AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
out.resize((256, 256), Image.LANCZOS).save("AppIcon_256.png")
