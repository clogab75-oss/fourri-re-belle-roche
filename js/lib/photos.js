/* Réduit les photos dans le navigateur avant l'envoi (max 1600 px, JPEG) : rapide et bien sous la limite de 5 Mo. */
export const MAX_PHOTOS = 12;
export async function compress(file, max = 1600, quality = 0.82) {
  if (!/^image\/(jpeg|png|webp|gif|bmp)$/i.test(file.type)) throw new Error(`« ${file.name} » n'est pas une image valide (JPEG, PNG ou WebP).`);
  const bmp = await createImageBitmap(file).catch(() => { throw new Error(`Impossible de lire « ${file.name} ».`); });
  const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
  const w = Math.max(1, Math.round(bmp.width * k)); const hgt = Math.max(1, Math.round(bmp.height * k));
  const c = document.createElement('canvas'); c.width = w; c.height = hgt;
  const ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, hgt); ctx.drawImage(bmp, 0, 0, w, hgt);
  if (bmp.close) bmp.close();
  const blob = await new Promise((res) => c.toBlob(res, 'image/jpeg', quality));
  if (!blob) throw new Error(`Impossible de traiter « ${file.name} ».`);
  return blob;
}
