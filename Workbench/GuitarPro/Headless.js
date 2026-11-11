// The exporter runs in JavaScriptCore without a browser or a Node runtime.
globalThis.process = { [Symbol.toStringTag]: 'process' };

if (typeof TextEncoder === 'undefined') {
    globalThis.TextEncoder = class {
        encode(text = '') {
            const bytes = unescape(encodeURIComponent(String(text)));
            return Uint8Array.from(bytes, character => character.charCodeAt(0));
        }
    };
}
if (typeof TextDecoder === 'undefined') {
    globalThis.TextDecoder = class {
        decode(bytes = []) {
            let escaped = '';
            for (const byte of bytes) escaped += '%' + byte.toString(16).padStart(2, '0');
            return decodeURIComponent(escaped);
        }
    };
}
