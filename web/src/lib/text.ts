import { MAX_PLEA_BYTES } from "./config";

const encoder = new TextEncoder();

export function pleaBytes(text: string): number {
  return encoder.encode(text).length;
}

/** Mirrors CabalGate._validateText so the problem is named before the wallet opens. */
export function validatePlea(text: string): { bytes: number; error?: string } {
  const bytes = pleaBytes(text);
  if (bytes === 0) return { bytes, error: "Write your plea first." };
  if (bytes > MAX_PLEA_BYTES) return { bytes, error: `Shorten the plea to ${MAX_PLEA_BYTES} bytes; it is ${bytes} bytes.` };
  for (const ch of text) {
    const cp = ch.codePointAt(0) ?? 0;
    if (cp < 0x20 || cp === 0x7f) return { bytes, error: "Remove line breaks, tabs and other control characters." };
    if ((cp >= 0x80 && cp <= 0x9f) || cp === 0xad || cp === 0x61c) return { bytes, error: "Remove hidden control characters (soft hyphens or marks)." };
    if ((cp >= 0x200b && cp <= 0x200f) || (cp >= 0x202a && cp <= 0x202e) || cp === 0x2028 || cp === 0x2029) {
      return { bytes, error: "Remove zero-width and bidi characters." };
    }
    if ((cp >= 0x2060 && cp <= 0x2064) || (cp >= 0x2066 && cp <= 0x2069) || cp === 0xfeff) {
      return { bytes, error: "Remove zero-width and bidi characters." };
    }
    if (cp >= 0xd800 && cp <= 0xdfff) return { bytes, error: "Remove the broken character (lone surrogate)." };
  }
  if (/\[\/?plea/i.test(text)) return { bytes, error: "Remove “[PLEA” and “[/PLEA”; those markers are reserved." };
  return { bytes };
}
