declare module 'heic-decode' {
  interface DecodedImage { width: number; height: number; data: Uint8ClampedArray | Uint8Array }
  export default function decode(input: { buffer: ArrayBufferLike | Uint8Array }): Promise<DecodedImage>;
}
