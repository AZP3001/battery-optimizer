// Reads an app's name and icon from the files inside its APK.
// JavaScript port of the script's manifest_label / resource_string (Android binary XML and resources.arsc),
// extended to find the launcher icon. No browser APIs here, so it also runs in Node for the self-check.

const u16 = (d, o) => d[o] | (d[o + 1] << 8);
const u32 = (d, o) => (d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)) >>> 0;
const utf8 = new TextDecoder("utf-8"), utf16 = new TextDecoder("utf-16le");

const ANDROID_LABEL = 0x01010001, ANDROID_ICON = 0x01010002, ANDROID_DRAWABLE = 0x01010199;

// Walk the (type, offset, size) chunks between start and end.
function* chunks(d, start, end) {
  while (start + 8 <= end) {
    const size = u32(d, start + 4);
    if (size < 8) return;
    yield [u16(d, start), start, size];
    start += size;
  }
}

// String number `index` from a string pool chunk (UTF-8 or UTF-16).
function poolString(d, pool, index) {
  const count = u32(d, pool + 8), flags = u32(d, pool + 16), strings = u32(d, pool + 20);
  if (index >= count) throw new RangeError("string index");
  let at = pool + strings + u32(d, pool + u16(d, pool + 2) + index * 4);
  if (flags & 0x100) {  // UTF-8: character count, then byte count
    at += d[at] & 0x80 ? 2 : 1;
    let len = d[at];
    if (len & 0x80) { len = ((len & 0x7f) << 8) | d[at + 1]; at += 1; }
    return utf8.decode(d.subarray(at + 1, at + 1 + len));
  }
  let len = u16(d, at);
  if (len & 0x8000) { len = ((len & 0x7fff) << 16) | u16(d, at + 2); at += 2; }
  return utf16.decode(d.subarray(at + 2, at + 2 + len * 2));
}

// Attributes of the first <element> in a binary XML file: {attrName: {type, value}}.
// type 3 = text (value is the string), 1 = resource reference, 0x1c-0x1f = color.
export function xmlAttrs(d, element, wanted) {
  let pool = null, ids = [];
  for (const [kind, at, size] of chunks(d, u16(d, 2), d.length)) {
    if (kind === 0x0001) pool = at;
    else if (kind === 0x0180) ids = Array.from({ length: (size - 8) / 4 }, (_, i) => u32(d, at + 8 + i * 4));
    else if (kind === 0x0102 && poolString(d, pool, u32(d, at + 20)) === element) {
      const out = {}, first = at + 16 + u16(d, at + 24);
      for (let i = 0; i < u16(d, at + 28); i++) {
        const attr = first + i * u16(d, at + 26), name = u32(d, attr + 4);
        // Shrunk APKs may strip the plain attribute name, so match by resource id first.
        const key = Object.keys(wanted).find((k) => (name < ids.length && ids[name] === wanted[k]) ||
          (name >= ids.length && poolString(d, pool, name) === k));
        if (!key) continue;
        const type = d[attr + 15];
        out[key] = { type, value: type === 3 ? poolString(d, pool, u32(d, attr + 8)) : u32(d, attr + 16) };
      }
      return out;
    }
  }
  return {};
}

// Where an entry sits inside a resource type chunk, or null if it is absent there.
function entryOffset(d, table, entry) {
  const flags = d[table + 9], count = u32(d, table + 12), index = table + u16(d, table + 2);
  if (flags & 1) {  // sparse: (entry, offset / 4) pairs
    for (let i = 0; i < count; i++) if (u16(d, index + i * 4) === entry) return u16(d, index + i * 4 + 2) * 4;
    return null;
  }
  if (entry >= count) return null;
  if (flags & 2) { const o = u16(d, index + entry * 2); return o === 0xffff ? null : o * 4; }
  const o = u32(d, index + entry * 4);
  return o === 0xffffffff ? null : o;
}

// Every value a resource has (one per configuration), best first by rank(table).
// References are followed, up to 4 levels deep.
function resolve(d, res, rank, depth = 0) {
  const found = [];
  let pool = null;
  const pkg = res >>> 24, type = (res >>> 16) & 0xff, entry = res & 0xffff;
  for (const [kind, at, size] of chunks(d, u16(d, 2), d.length)) {
    if (kind === 0x0001) pool = at;
    else if (kind === 0x0200 && u32(d, at + 8) === pkg) {
      for (const [sub, table] of chunks(d, at + u16(d, at + 2), at + size)) {
        if (sub !== 0x0201 || d[table + 8] !== type) continue;
        const off = entryOffset(d, table, entry);
        if (off === null) continue;
        const item = table + u32(d, table + 16) + off, flags = u16(d, item + 2);
        let value;
        if (flags & 8) value = [flags >> 8, u32(d, item + 4)];          // compact entry
        else if (flags & 1) continue;                                     // complex entries are not simple values
        else { const v = item + u16(d, item); value = [d[v + 3], u32(d, v + 4)]; }
        found.push({ type: value[0], raw: value[1], rank: rank(d, table) });
      }
    }
  }
  found.sort((a, b) => a.rank - b.rank);
  const out = [];
  for (const f of found) {
    if (f.type === 1 && depth < 4) out.push(...resolve(d, f.raw, rank, depth + 1));
    else if (f.type === 3) out.push({ type: 3, value: poolString(d, pool, f.raw) });
    else out.push({ type: f.type, value: f.raw });
  }
  return out;
}

// Rank configurations: the phone's language first, then the default.
const byLanguage = (lang) => (d, table) => {
  const l = d.subarray(table + 28, table + 30);
  return l[0] === lang[0] && l[1] === lang[1] ? 0 : l[0] === 0 && l[1] === 0 ? 1 : 2;
};
// Rank configurations: highest screen density first, "any density" (adaptive icon XML) last.
const byDensity = (d, table) => {
  const dens = u16(d, table + 34);
  return dens === 0xfffe ? 1e6 : dens === 0xffff ? 0 : -dens;
};

// Two-letter language code as the 2 bytes Android stores ("de" -> [0x64, 0x65]).
export const languageBytes = (code) => [code.charCodeAt(0) || 0, code.charCodeAt(1) || 0];

// The app name. manifest and arsc are Uint8Arrays; arsc may be null if the name is plain text.
export function appLabel(manifest, arsc, lang) {
  const a = xmlAttrs(manifest, "application", { label: ANDROID_LABEL }).label;
  if (!a) return "";
  if (a.type === 3) return a.value.trim();
  if (a.type !== 1 || !arsc) return "";
  const v = resolve(arsc, a.value, byLanguage(lang)).find((x) => x.type === 3);
  return v ? v.value.trim() : "";
}

// The icon's resource id from the manifest, or 0.
export function iconResource(manifest) {
  const a = xmlAttrs(manifest, "application", { icon: ANDROID_ICON }).icon;
  return a && a.type === 1 ? a.value : 0;
}

// Where to find the icon: a picture file (png/webp/jpg), or an adaptive icon XML. Best first.
export function iconFiles(arsc, res) {
  return resolve(arsc, res, byDensity).filter((v) => v.type === 3).map((v) => v.value);
}

// Layers of an adaptive icon XML: {foreground, background}, each {file} or {color: "#rrggbbaa"}.
export function adaptiveLayers(xml, arsc) {
  const layer = (name) => {
    const a = xmlAttrs(xml, name, { drawable: ANDROID_DRAWABLE }).drawable;
    if (!a) return null;
    if (a.type >= 0x1c && a.type <= 0x1f) return { color: argb(a.value) };
    if (a.type !== 1) return null;
    for (const v of resolve(arsc, a.value, byDensity)) {
      if (v.type === 3 && isPicture(v.value)) return { file: v.value };
      if (v.type >= 0x1c && v.type <= 0x1f) return { color: argb(v.value) };
    }
    return null;
  };
  return { foreground: layer("foreground"), background: layer("background") };
}

export const isPicture = (path) => /\.(png|webp|jpe?g)$/i.test(path);
const argb = (v) => "#" + [16, 8, 0, 24].map((s) => ((v >>> s) & 0xff).toString(16).padStart(2, "0")).join("");
